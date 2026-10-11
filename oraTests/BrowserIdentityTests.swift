import AppKit
import Foundation
@testable import Ora
import Testing
import WebKit

@MainActor
struct BrowserIdentityTests {
    @Test func browserIdentityMatchesNetworkAndJavaScriptAcrossRefreshes() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["ORA_WEB_FIXTURE_URL"])
        let configuration = BrowserPageConfiguration.oraDefault(userScripts: [], privacySettings: .init())
        let expected = try #require(configuration.userAgent)
        for isPrivate in [false, true] {
            let page = makePage(configuration, isPrivate: isPrivate)
            defer { page.teardown() }
            try page.load(URLRequest(url: #require(URL(string: fixture + "/user-agent"))))
            for stage in 0 ..< 3 {
                if stage > 0 {
                    page.reload()
                }
                try await waitFor(page, condition: "document.querySelector('#agent') !== null")
                let network = try await evaluate(page, "document.querySelector('#agent').textContent") as? String
                let script = try await evaluate(page, "navigator.userAgent") as? String
                #expect(network == expected)
                #expect(script == expected)
                #expect(network?.components(separatedBy: "Mozilla/5.0").count == 2)
                #expect((page.contentView as? WKWebView)?.customUserAgent == expected)
            }
        }
        #expect(HeadlessTestHost.hasNoAppWindows)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORA_GOOGLE_SIGNIN_PROBE"] == "1"))
    func opensGoogleYouTubeSignInWithoutAccountSubmission() async throws {
        let configuration = BrowserPageConfiguration.oraDefault(userScripts: [], privacySettings: .init())
        let page = makePage(configuration, isPrivate: true)
        defer { page.teardown() }
        let url = try #require(URL(string:
            "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin"))
        try page.load(URLRequest(url: url))
        for stage in 0 ..< 2 {
            if stage > 0 {
                page.reload()
            }
            // Google may keep loading background resources after its form is ready.
            for _ in 0 ..< 600 {
                if await (try? evaluate(
                    page,
                    "!!document.querySelector('#identifierId') || document.body.innerText.includes('may not be secure')"
                )) as? Bool == true {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            // A snapshot records visible state. No account identifier, password, or cookie is read.
            if let output = ProcessInfo.processInfo.environment["ORA_PREVIEW_DIRECTORY"] {
                let view = try #require(page.contentView as? WKWebView)
                // Offscreen WebKit can pause Google's entry animation and web-font painting.
                _ = try await view.callAsyncJavaScript(
                    "await document.fonts.ready; document.getAnimations().forEach(a => {try {a.finish()} catch {}}); return true;",
                    arguments: [:], in: nil, contentWorld: .page
                )
                try await Task.sleep(nanoseconds: 400_000_000)
                let image = try await view.takeSnapshot(configuration: nil)
                let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    directory.appendingPathComponent("google-signin-\(stage).png"))
            }
            #expect(try await evaluate(
                page,
                "document.body.innerText.includes('may not be secure')"
            ) as? Bool == false)
            #expect(try await evaluate(
                page,
                "document.querySelector('#identifierId')?.getBoundingClientRect().height > 0"
            ) as? Bool == true)
        }
        #expect(HeadlessTestHost.hasNoAppWindows)
    }

    private func makePage(_ configuration: BrowserPageConfiguration, isPrivate: Bool) -> BrowserPage {
        let page = BrowserPage(
            profile: BrowserEngineProfile(identifier: UUID(), isPrivate: isPrivate),
            configuration: configuration,
            delegate: nil
        )
        page.contentView.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
        return page
    }

    private func evaluate(_ page: BrowserPage, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            page.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private func waitFor(_ page: BrowserPage, condition: String, attempts: Int = 200) async throws {
        for _ in 0 ..< attempts {
            if !page.isLoading,
               await (try? evaluate(page, "document.readyState === 'complete' && (\(condition))")) as? Bool == true
            {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CocoaError(.fileReadUnknown)
    }
}
