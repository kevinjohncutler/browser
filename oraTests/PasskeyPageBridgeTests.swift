import AppKit
import Foundation
@testable import Ora
import Testing
import WebKit

@MainActor
struct PasskeyPageBridgeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORA_PASSKEY_TRANSPORT_TEST"] == "1"))
    func actualWebKitBridgePreservesCredentialShapeAndCancellation() async throws {
        let connection = SyntheticPasskeyConnection()
        let page = BrowserPage(
            profile: BrowserEngineProfile(identifier: UUID(), isPrivate: true),
            configuration: .oraDefault(userScripts: [], privacySettings: .init()),
            delegate: nil,
            passkeys: connection
        )
        defer { page.teardown() }
        let view = try #require(page.contentView as? WKWebView)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        try page.load(URLRequest(url: #require(URL(string: "https://accounts.google.com/"))))
        for _ in 0 ..< 600 {
            if await (try? view
                .evaluateJavaScript(
                    "location.origin === 'https://accounts.google.com' && document.readyState === 'complete'"
                )) as? Bool ==
                true
            {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await view.callAsyncJavaScript("""
        const available = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
        const conditional = await PublicKeyCredential.isConditionalMediationAvailable();
        const bytes = new Uint8Array([99, 1, 2, 3, 99]);
        const credential = await navigator.credentials.get({publicKey:{
          challenge:bytes.subarray(1,4), rpId:'google.com',
          allowCredentials:[{type:'public-key',id:bytes.subarray(1,3)}]}});
        return {available, conditional, instance:credential instanceof PublicKeyCredential,
          responseInstance:credential.response instanceof AuthenticatorAssertionResponse,
          raw:[...new Uint8Array(credential.rawId)],
          signed:[...new Uint8Array(credential.response.signature)],
          extensions:credential.getClientExtensionResults(), json:credential.toJSON()};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        #expect(result?["available"] as? Bool == true)
        #expect(result?["conditional"] as? Bool == false)
        #expect(result?["instance"] as? Bool == true)
        #expect(result?["responseInstance"] as? Bool == true)
        #expect(result?["raw"] as? [Int] == [1, 2])
        #expect(result?["signed"] as? [Int] == [3, 4])
        #expect(connection.origins.allSatisfy { $0 == "https://accounts.google.com" })
        let request = try #require(connection.requests.last?["publicKey"] as? [String: Any])
        #expect(request["challenge"] as? String == "AQID")
        #expect((request["allowCredentials"] as? [[String: Any]])?.first?["id"] as? String == "AQI=")

        // Even a same-origin frame cannot call the privileged message handler.
        let before = connection.requests.count
        let frameError = try await view.callAsyncJavaScript("""
        const frame = document.createElement('iframe');
        const loaded = new Promise(r => frame.onload=r); document.body.append(frame); await loaded;
        const reply = await frame.contentWindow.webkit.messageHandlers.oraPasskey.postMessage({
          operation:'get',identifier:crypto.randomUUID(),publicKey:{challenge:'AQID'}});
        frame.remove(); return reply.error;
        """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(frameError == "SecurityError")
        #expect(connection.requests.count == before)

        connection.hold = true
        _ = try await view.evaluateJavaScript("""
        window.passkeyAbort = new AbortController(); window.passkeyCanceled = false;
        navigator.credentials.get({publicKey:{challenge:new Uint8Array([1,2,3]),rpId:'google.com'},
          signal:passkeyAbort.signal}).catch(e => { window.passkeyCanceled = e.name === 'AbortError'; });
        true;
        """)
        for _ in 0 ..< 100 {
            if connection.pending != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(connection.pending != nil)
        _ = try await view.evaluateJavaScript("passkeyAbort.abort(); true")
        for _ in 0 ..< 100 {
            if await (try? view.evaluateJavaScript("window.passkeyCanceled")) as? Bool == true {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(try await view.evaluateJavaScript("window.passkeyCanceled") as? Bool == true)
        #expect(connection.pending == nil)
        #expect(HeadlessTestHost.hasNoAppWindows)
    }
}

@MainActor
final class SyntheticPasskeyConnection: PasskeyConnection {
    var requests: [[String: Any]] = []
    var origins: [String] = []
    var hold = false
    var pending: CheckedContinuation<Data, Error>?

    func perform(_ request: Data, origin: String) async throws -> Data {
        let body = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        requests.append(body)
        origins.append(origin)
        if body["operation"] as? String == "available" {
            return try JSONSerialization.data(withJSONObject: ["available": true])
        }
        if hold {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return try JSONSerialization.data(withJSONObject: [
            "id": "AQI",
            "type": "public-key",
            "rawId": "AQI=",
            "authenticatorAttachment": "platform",
            "extensions": [:],
            "response": [
                "clientDataJSON": "e30=",
                "authenticatorData": "AQI=",
                "signature": "AwQ=",
                "userHandle": NSNull()
            ]
        ])
    }

    func cancel() {
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: NSError(
            domain: "OraPasskeys",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "AbortError"]
        ))
    }
}
