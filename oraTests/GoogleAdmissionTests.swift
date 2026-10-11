import AppKit
import Foundation
@testable import Ora
import Testing
import WebKit

/// Opt-in admission check. It submits an account identifier and never supplies a password.
@MainActor
struct GoogleAdmissionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORA_GOOGLE_ACCOUNT_FILE"] != nil))
    func checksAccountSubmissionWithProductionPrivacy() async throws {
        let file = try #require(ProcessInfo.processInfo.environment["ORA_GOOGLE_ACCOUNT_FILE"])
        let account = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let path = try #require(ProcessInfo.processInfo.environment["ORA_GOOGLE_ADMISSION_OUTPUT"])
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var evidence: [[String: String]] = []
        for arm in ["configured"] {
            let privacy = SpacePrivacySettings()
            let config = BrowserPageConfiguration.oraDefault(
                userScripts: OraBrowserScripts.userScripts() + BrowserPrivacyService.privacyScripts(for: privacy),
                privacySettings: privacy
            )
            let passkeys = ProcessInfo.processInfo.environment["ORA_GOOGLE_PASSKEY_PROBE"] == "1" ?
                SyntheticPasskeyConnection() : nil
            passkeys?.hold = true
            let page = BrowserPage(
                profile: BrowserEngineProfile(identifier: UUID(), isPrivate: true),
                configuration: config,
                delegate: nil,
                passkeys: passkeys
            )
            defer { page.teardown() }
            let view = try #require(page.contentView as? WKWebView)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
            let url = try #require(URL(string:
                "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin"))
            page.load(URLRequest(url: url))
            try await wait(
                view,
                script: "document.readyState === 'complete' && !!document.querySelector('#identifierId')"
            )
            #expect(await (try? view.evaluateJavaScript("""
            location.origin === 'https://accounts.google.com' &&
              window.__oraFingerprintingProtectionInstalled !== true
            """)) as? Bool == true)
            _ = try await view.callAsyncJavaScript("""
            await Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 1500))]);
            document.getAnimations().forEach(a => {try {a.finish()} catch {}});
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
            try await Task.sleep(nanoseconds: 500_000_000)
            // The identifier is passed as a WebKit argument, never placed in source text or argv.
            _ = try await view.callAsyncJavaScript("""
            const field = document.querySelector('#identifierId');
            field.focus();
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(field, account);
            field.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertText', data:account}));
            field.dispatchEvent(new Event('change', {bubbles:true}));
            const next = document.querySelector('#identifierNext, #next, input[type=submit], button[type=submit]');
            if (!next) throw new Error('Google identifier submit control is unavailable.');
            next.click();
            return true;
            """, arguments: ["account": account], in: nil, contentWorld: .page)
            var verdict = "timeout"
            for _ in 0 ..< 600 {
                if passkeys?.requests.contains(where: { $0["operation"] as? String == "get" }) == true {
                    verdict = "passkey-request"
                    break
                }
                if let current = try? await view.evaluateJavaScript("""
                (() => {
                  document.getAnimations().forEach(a => {if (Number.isFinite(a.effect?.getComputedTiming().endTime)) {try {a.finish()} catch {}}});
                  const text = document.body?.innerText || '';
                  if (text.includes('may not be secure')) return 'rejected';
                  if (document.querySelector('input[type=password]')?.getBoundingClientRect().height > 0) return 'password';
                  if (location.pathname === '/v3/signin/challenge/pk/presend') return 'passkey-pending';
                  if (location.pathname.includes('/challenge/') && !document.querySelector('#identifierId') && text.trim().length > 50) return 'challenge';
                  if (document.body?.innerText.includes("Couldn't find your Google Account")) return 'account-lookup';
                  if (document.body?.innerText.includes('Enter a valid email or phone number')) return 'invalid-input';
                  return 'pending';
                })()
                """) as? String, current != "pending" {
                    verdict = current
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let navigationPath = await (try? view.evaluateJavaScript("location.pathname")) as? String ?? "unavailable"
            evidence.append(["arm": arm, "verdict": verdict, "navigationPath": navigationPath])
            if let passkeys {
                // Capture only the request boundary. Never forward Google's request to a real authenticator.
                let request = passkeys.requests.first { $0["operation"] as? String == "get" }
                let key = request?["publicKey"] as? [String: Any]
                if verdict == "passkey-request" {
                    #expect(key?["rpId"] as? String == "google.com")
                    #expect(key?["challenge"] is String)
                }
                evidence[evidence.count - 1]["oraPasskeyRequest"] = request != nil ? "received" : "missing"
            }
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
            #expect(verdict == "password" || verdict == "challenge" || verdict == "passkey-pending" || verdict ==
                "passkey-request")
            // A passkey request can wait indefinitely for a window and user authentication.
            // Its old form is not a rendered challenge, so do not present a snapshot as proof.
            if verdict != "passkey-pending", verdict != "passkey-request" {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try await capture(view, account: account, to: output.appendingPathComponent("\(arm).png"))
            }
        }
        #expect(HeadlessTestHost.hasNoAppWindows)
    }

    private func capture(_ view: WKWebView, account: String, to destination: URL) async throws {
        // Hide account text only for the local snapshot. Never read password values or cookies.
        _ = try await view.callAsyncJavaScript("""
        const nodes = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        while (node = nodes.nextNode()) {
          if (node.textContent.includes(account)) node.textContent = node.textContent.replaceAll(account, '[account redacted]');
        }
        document.querySelectorAll('input:not([type=password])').forEach(field => {
          if (field.value.includes(account)) field.value = '[account redacted]';
        });
        await Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 1500))]);
        document.getAnimations().forEach(a => {try {a.finish()} catch {}});
        return true;
        """, arguments: ["account": account], in: nil, contentWorld: .page)
        try await Task.sleep(nanoseconds: 300_000_000)
        let image = try await view.takeSnapshot(configuration: nil)
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to:
            destination)
    }

    private func wait(_ view: WKWebView, script: String) async throws {
        for _ in 0 ..< 400 {
            if await (try? view.evaluateJavaScript(script)) as? Bool == true {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CocoaError(.fileReadUnknown)
    }
}
