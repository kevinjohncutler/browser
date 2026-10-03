import AppKit
import Foundation
@testable import Ora
import SwiftData
import SwiftUI
import Testing

@MainActor
struct FaviconTests {
    static func coloredIcon() throws -> (NSImage, Data) {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pixels = try #require(bitmap.bitmapData)
        for row in 0 ..< 16 {
            for column in 0 ..< 16 {
                let index = row * bitmap.bytesPerRow + column * 4
                pixels[index] = 242
                pixels[index + 1] = 51
                pixels[index + 2] = 13
                pixels[index + 3] = 255
            }
        }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        return try (#require(NSImage(data: data)), data)
    }

    @Test func coalescesIconDownloadsAndPersistsOriginalImageData() async throws {
        let (image, data) = try Self.coloredIcon()
        var requests = 0
        let source = try #require(URL(string: "https://example.com/favicon.png"))
        let service = FaviconService(fetcher: { _ in
            requests += 1
            try? await Task.sleep(nanoseconds: 10_000_000)
            return (image, data, source)
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")
        let results: [Bool] = await withCheckedContinuation { continuation in
            var finished: [Bool] = []
            func complete(_ url: URL?, _ success: Bool) {
                #expect(url == source)
                finished.append(success)
                if finished.count == 2 {
                    continuation.resume(returning: finished)
                }
            }
            service.downloadAndSaveFavicon(for: "www.example.com", faviconURL: source, to: first, completion: complete)
            service.downloadAndSaveFavicon(for: "example.com", faviconURL: source, to: second, completion: complete)
        }
        #expect(results == [true, true])
        #expect(requests == 1)
        #expect(try Data(contentsOf: first) == data)
        #expect(try Data(contentsOf: second) == data)
    }

    @Test func initializesExistingUnloadedTabIconAndPersistsIt() async throws {
        let (image, data) = try Self.coloredIcon()
        var requests = 0
        let source = try #require(URL(string: "https://example.com/favicon.png"))
        let service = FaviconService(fetcher: { _ in
            requests += 1
            return (image, data, source)
        })
        let manager = try ImporterTests.makeManager()
        let space = try #require(manager.activeContainer)
        let tab = manager.addTab(url: source, container: space, isPrivate: false, activate: false)
        tab.ensureFavicon(using: service)
        for _ in 0 ..< 100 where tab.isFetchingFavicon {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let file = try #require(tab.faviconLocalFile)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == data)
        #expect(!tab.isWebViewReady)
        #expect(tab.favicon == source)
        tab.ensureFavicon(using: service)
        #expect(requests == 1)
        let freshContext = ModelContext(manager.modelContainer)
        #expect(try freshContext.fetch(FetchDescriptor<Ora.Tab>()).first { $0.id == tab.id }?.faviconLocalFile == file)
    }

    @Test func failedIconRequestsAreThrottled() async throws {
        var requests = 0
        let service = FaviconService(fetcher: { _ in requests += 1
            return nil
        })
        let source = try #require(URL(string: "https://example.com"))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for _ in 0 ..< 2 {
            let success: Bool = await withCheckedContinuation { continuation in
                service.downloadAndSaveFavicon(for: "example.com", faviconURL: source, to: destination) { _, success in
                    continuation.resume(returning: success)
                }
            }
            #expect(!success)
        }
        #expect(requests == 1)
    }

    @Test func rendersColoredIconForUnloadedTab() throws {
        let (_, data) = try Self.coloredIcon()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let view = FavIcon(isWebViewReady: false, favicon: nil, faviconLocalFile: file, textColor: .gray)
            .padding(12).frame(width: 48, height: 48).background(Color(white: 0.1))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 48, height: 48)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
            .usingColorSpace(.deviceRGB))
        #expect(center.redComponent > center.greenComponent + 0.4)
        #expect(NSApplication.shared.windows.isEmpty)
        if let path = ProcessInfo.processInfo.environment["ORA_PREVIEW_DIRECTORY"] {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("unloaded-tab-icon.png"))
        }
    }

    @Test func importsNamedSpaceIconsAndRepairsPlaceholdersWithoutDuplicatingTabs() throws {
        for (name, expected) in [("star", "⭐️"), ("flash", "⚡️"), ("planet", "🪐")] {
            let data = Data("{\"icon\":\"\(name)\"}".utf8)
            let icon = try JSONDecoder().decode(SpaceItem.IconType.self, from: data)
            #expect(icon.displayEmoji == expected)
        }
        let explicit = try JSONDecoder().decode(
            SpaceItem.IconType.self,
            from: Data("{\"emoji_v2\":\"🌱\",\"icon\":\"star\"}".utf8)
        )
        #expect(explicit.displayEmoji == "🌱")
        let root = try ImporterTests.fixture()
        let manager = try ImporterTests.makeManager()
        ImporterTests.runImport(root, manager: manager)
        let space = try #require(manager.modelContext.fetch(FetchDescriptor<TabContainer>())
            .first { $0.name == "Test Space" })
        let count = space.tabs.count
        space.emoji = "💀"
        let json = "{\"sidebar\":{\"containers\":[{\"spaces\":[{\"id\":\"space\",\"title\":\"Test Space\",\"containerIDs\":[],\"customInfo\":{\"iconType\":{\"icon\":\"star\"}}}]}]}}"
        let namedRoot = try JSONDecoder().decode(Root.self, from: Data(json.utf8))
        updateImportedSpaceIcons(from: namedRoot, tabManager: manager)
        #expect(space.emoji == "⭐️")
        #expect(space.tabs.count == count)
        space.emoji = "🌱"
        updateImportedSpaceIcons(from: namedRoot, tabManager: manager)
        #expect(space.emoji == "🌱")
    }
}
