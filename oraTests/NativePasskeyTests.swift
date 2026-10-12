import AppKit
import Foundation
@testable import Ora
import Testing
import WebKit

@MainActor
struct NativePasskeyTests {
    @Test func productionPagesPreserveWebKitAuthenticationAndRefreshes() async throws {
        let page = BrowserPage(
            profile: BrowserEngineProfile(identifier: UUID(), isPrivate: true),
            configuration: .oraDefault(userScripts: OraBrowserScripts.userScripts(), privacySettings: .init()),
            delegate: nil
        )
        defer { page.teardown() }
        let view = try #require(page.contentView as? WKWebView)
        let url = try #require(URL(string: "https://accounts.google.com"))
        for _ in 0 ..< 3 {
            var started = false
            let observer = view.observe(\.isLoading, options: [.new]) { _, change in
                if change.newValue == true {
                    started = true
                }
            }
            page.load(URLRequest(url: url))
            for _ in 0 ..< 400 {
                if started, !view.isLoading, await (try? view.evaluateJavaScript(
                    "location.origin === 'https://accounts.google.com' && document.readyState === 'complete'"
                )) as? Bool == true {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            observer.invalidate()
            #expect(started)
            #expect(!view.isLoading)
            let state = try await view.callAsyncJavaScript("""
            return {
              nativeGet:navigator.credentials.get.toString().includes('[native code]'),
              nativeCreate:navigator.credentials.create.toString().includes('[native code]'),
              nativeAvailability:PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable.toString().includes('[native code]'),
              nativeConditional:PublicKeyCredential.isConditionalMediationAvailable.toString().includes('[native code]'),
              hasBroker:!!window.webkit?.messageHandlers?.oraPasskey
            };
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Bool]
            #expect(state?["nativeGet"] == true)
            #expect(state?["nativeCreate"] == true)
            #expect(state?["nativeAvailability"] == true)
            #expect(state?["nativeConditional"] == true)
            #expect(state?["hasBroker"] == false)
        }
        // A pre-aborted request cannot initiate native credential retrieval or authentication UI.
        let failure = try await view.callAsyncJavaScript("""
        const abort = new AbortController(); abort.abort();
        try {
          await navigator.credentials.get({publicKey:{
            challenge:new Uint8Array([1,2,3]),rpId:'google.com'},signal:abort.signal});
          return 'unexpected-success';
        } catch (error) { return error.name; }
        """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(failure == "AbortError", "Native cancellation returned \(failure ?? "missing").")
        #expect(HeadlessTestHost.hasNoAppWindows)
    }
}
