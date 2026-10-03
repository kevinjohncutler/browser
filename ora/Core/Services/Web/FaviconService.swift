import AppKit
import CoreImage
import FaviconFinder
import SwiftUI

final class FaviconService: ObservableObject {
    typealias Payload = (image: NSImage, data: Data, sourceURL: URL)
    static let shared = FaviconService()
    private let fetcher: ((String) async -> Payload?)?
    private var dataCache: [String: Data] = [:]
    private var retryAfter: [String: Date] = [:]

    init(fetcher: ((String) async -> Payload?)? = nil) {
        self.fetcher = fetcher
    }

    private var cache: [String: NSImage] = [:]
    private var colorCache: [String: Color] = [:]
    private var sourceURLCache: [String: URL] = [:]
    private var isFetching: Set<String> = []
    private var pendingCompletions: [String: [(NSImage?) -> Void]] = [:]

    func getFavicon(for searchURL: String) -> NSImage? {
        guard let domain = extractDomain(from: searchURL) else { return nil }

        if let cachedFavicon = cache[domain] {
            return cachedFavicon
        }

        fetchAndCacheFavicon(for: domain)
        return nil
    }

    func getFaviconColor(for searchURL: String) -> Color? {
        guard let domain = extractDomain(from: searchURL) else { return nil }

        if let cachedColor = colorCache[domain] {
            return cachedColor
        }

        // If favicon exists but color doesn't, compute it
        if let favicon = cache[domain] {
            let color = Color(favicon.averageColor())
            colorCache[domain] = color
            return color
        }

        fetchAndCacheFavicon(for: domain)
        return nil
    }

    func faviconURL(for domain: String) -> URL? {
        let normalizedDomain = normalizeDomain(domain)
        return sourceURLCache[normalizedDomain] ?? canonicalURL(for: normalizedDomain)
    }

    func faviconURL(forSearchURL searchURL: String) -> URL? {
        guard let domain = extractDomain(from: searchURL) else { return nil }
        return canonicalURL(for: domain)
    }

    private func extractDomain(from searchURL: String) -> String? {
        let trimmed = searchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sanitized = trimmed.replacingOccurrences(of: "{query}", with: "")

        if let host = URL(string: sanitized)?.host {
            return normalizeDomain(host)
        }

        if let host = URL(string: "https://\(sanitized)")?.host {
            return normalizeDomain(host)
        }

        return nil
    }

    private func normalizeDomain(_ domain: String) -> String {
        let lowercased = domain.lowercased()
        return lowercased.hasPrefix("www.") ? String(lowercased.dropFirst(4)) : lowercased
    }

    private func canonicalURL(for domain: String) -> URL? {
        guard !domain.isEmpty else { return nil }
        return URL(string: "https://\(domain)")
    }

    func fetchFaviconSync(for searchURL: String, completion: @escaping (NSImage?) -> Void) {
        guard let domain = extractDomain(from: searchURL) else {
            completion(nil)
            return
        }
        if let cachedFavicon = cache[domain] {
            completion(cachedFavicon)
            return
        }
        fetchAndCacheFavicon(for: domain, completion: completion)
    }

    private func fetchAndCacheFavicon(for domain: String, completion: ((NSImage?) -> Void)? = nil) {
        if let cachedFavicon = cache[domain] {
            completion?(cachedFavicon)
            return
        }

        if let retry = retryAfter[domain], retry > Date() {
            completion?(nil)
            return
        }

        if let completion {
            pendingCompletions[domain, default: []].append(completion)
        }

        guard !isFetching.contains(domain) else { return }
        isFetching.insert(domain)

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let payload = await self.fetchFaviconPayload(for: domain)
            await MainActor.run {
                self.completeFetch(
                    for: domain,
                    favicon: payload?.image,
                    sourceURL: payload?.sourceURL,
                    data: payload?.data
                )
            }
        }
    }

    @MainActor
    private func completeFetch(for domain: String, favicon: NSImage?, sourceURL: URL?, data: Data?) {
        if let favicon {
            retryAfter[domain] = nil
            dataCache[domain] = data
            cache[domain] = favicon
            colorCache[domain] = Color(favicon.averageColor())
            if let sourceURL {
                sourceURLCache[domain] = sourceURL
            }
            objectWillChange.send()
        } else {
            retryAfter[domain] = Date().addingTimeInterval(300)
        }

        isFetching.remove(domain)
        let completions = pendingCompletions.removeValue(forKey: domain) ?? []
        for completion in completions {
            completion(favicon)
        }
    }

    private func fetchFaviconPayload(for domain: String) async -> (image: NSImage, data: Data, sourceURL: URL)? {
        if let fetcher {
            return await fetcher(domain)
        }
        guard let siteURL = canonicalURL(for: domain) else { return nil }

        do {
            let favicon = try await FaviconFinder(url: siteURL)
                .fetchFaviconURLs()
                .download()
                .largest()
            guard let faviconImage = favicon.image else { return nil }
            return (faviconImage.image, faviconImage.data, favicon.url.source)
        } catch {
            return nil
        }
    }

    static func pngData(for image: NSImage) -> Data? {
        guard let representation = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: representation) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func downloadAndSaveFavicon(
        for domain: String,
        faviconURL _: URL,
        to saveURL: URL,
        completion: @escaping (URL?, Bool) -> Void
    ) {
        let normalizedDomain = normalizeDomain(domain)
        fetchAndCacheFavicon(for: normalizedDomain) { [weak self] image in
            guard let self, let image,
                  let data = Self.pngData(for: image)
            else {
                completion(nil, false)
                return
            }
            do {
                try data.write(to: saveURL, options: .atomic)
                completion(self.faviconURL(for: normalizedDomain), true)
            } catch {
                completion(nil, false)
            }
        }
    }
}

extension NSImage {
    func averageColor() -> NSColor {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return NSColor.gray
        }

        let inputImage = CIImage(cgImage: cgImage)
        let extentVector = CIVector(
            x: inputImage.extent.origin.x,
            y: inputImage.extent.origin.y,
            z: inputImage.extent.size.width,
            w: inputImage.extent.size.height
        )

        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]
        ) else {
            return NSColor.gray
        }

        guard let outputImage = filter.outputImage else {
            return NSColor.gray
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return NSColor(
            red: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: CGFloat(bitmap[3]) / 255
        )
    }
}
