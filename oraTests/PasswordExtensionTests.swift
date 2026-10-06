import AppKit
import Foundation
@testable import Ora
import Testing
@preconcurrency import WebKit

@MainActor
struct PasswordExtensionTests {
    @Test func nativeMessagesSurviveFragmentationAndMultipleFrames() throws {
        let first = try NativeMessageFramer.encode(["request": "credentials", "host": "example.com"])
        let second = try NativeMessageFramer.encode(["username": "synthetic", "password": "fixture-only"])
        var framer = NativeMessageFramer()
        #expect(try framer.receive(first.prefix(2)).isEmpty)
        #expect(try framer.receive(first.dropFirst(2).prefix(3)).isEmpty)
        let messages = try framer.receive(first.dropFirst(5) + second)
        #expect(messages.count == 2)
        #expect((messages[1] as? [String: String])?["password"] == "fixture-only")
        #expect(!framer.hasIncompleteMessage)
    }

    @Test func rejectsOversizedNativeMessages() throws {
        var framer = NativeMessageFramer()
        #expect(throws: (any Error).self) { try framer.receive(Data([255, 255, 255, 127])) }
    }

    @Test func deliversFinalNativeReplyBeforeDisconnect() async throws {
        guard let python = ProcessInfo.processInfo.environment["ORA_PYTHON_PATH"] else { return }
        let connection = NativePasswordMessaging(executable: URL(fileURLWithPath: python), arguments: [
            "-c",
            "import sys,struct; body=b'{\"ready\":true}';sys.stdout.buffer.write(struct.pack('<I',len(body))+body);sys.stdout.buffer.flush()"
        ])
        defer { connection.close() }
        var events: [String] = []
        connection.onMessage = { _ in events.append("message") }
        connection.onDisconnect = { _ in events.append("disconnect") }
        try connection.start()
        for _ in 0 ..< 120 {
            if events.contains("disconnect") {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(events == ["message", "disconnect"])
    }

    @Test func realExtensionFocusNativeProcessFillAndRefresh() async throws {
        try await verifyFocusAndRefresh(useChrome: false)
    }

    @Test func realWebKitFocusChromeBridgeFillAndRefresh() async throws {
        try await verifyFocusAndRefresh(useChrome: true)
    }

    private func verifyFocusAndRefresh(useChrome: Bool) async throws {
        guard #available(macOS 15.4, *), let fixture = ProcessInfo.processInfo.environment["ORA_WEB_FIXTURE_URL"],
              let python = ProcessInfo.processInfo.environment["ORA_PYTHON_PATH"] else { return }
        var key: String?
        if useChrome {
            guard let source = ProcessInfo.processInfo.environment["ORA_APPLE_EXTENSION_PATH"] else { return }
            let manifest = try #require(JSONSerialization
                .jsonObject(with: Data(contentsOf: URL(fileURLWithPath: source)
                        .appendingPathComponent("manifest.json"))) as? [String: Any])
            key = try #require(manifest["key"] as? String)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper.py")
        try """
        #!\(python)
        import json, struct, sys
        while True:
            header = sys.stdin.buffer.read(4)
            if not header: break
            size = struct.unpack('<I', header)[0]
            message = json.loads(sys.stdin.buffer.read(size))
            reply = json.dumps({'username': 'synthetic@example.test', 'password': 'fixture-only', 'host': message['host']}).encode()
            sys.stdout.buffer.write(struct.pack('<I', len(reply)) + reply)
            sys.stdout.buffer.flush()
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try """
        {"manifest_version":3,"name":"Password test","version":"1.0","permissions":["nativeMessaging"],"host_permissions":["http://127.0.0.1/*"],"background":{"service_worker":"background.js"},"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"]}]}
        """.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        const port = browser.runtime.connectNative('com.apple.passwordmanager');
        const replies = [];
        port.onMessage.addListener(message => replies.shift()?.(message));
        browser.runtime.onMessage.addListener((message, sender, reply) => {
          if (message.type !== 'focus') return false;
          replies.push(reply); port.postMessage(message); return true;
        });
        """.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try """
        document.addEventListener('focusin', async event => {
          if (event.target.type !== 'password') return;
          const result = await browser.runtime.sendMessage({type:'focus',host:location.hostname});
          if (result.host !== location.hostname) throw new Error('Origin mismatch');
          document.querySelector('[autocomplete=username]').value = result.username;
          event.target.value = result.password;
          event.target.dispatchEvent(new Event('input', {bubbles:true}));
        });
        document.documentElement.dataset.passwordExtension = 'loaded';
        """.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        var launches = 0
        var chromeLaunches = 0
        let runtime = PasswordExtensionRuntime(persistent: false) { () -> any PasswordMessageConnection in
            launches += 1
            if let key {
                let transport = ChromePasswordTransport(nativeHostForTesting: helper)
                transport.onProcessStarted = { chromeLaunches += 1 }
                return ChromeTestPasswordConnection(transport: transport, publicKey: key)
            }
            return NativePasswordMessaging(executable: URL(fileURLWithPath: python), arguments: ["-u", helper.path])
        }
        defer { runtime.shutdown() }
        try await runtime.load(from: directory, identifier: "ora-password-test")
        let profile = BrowserEngineProfile(identifier: UUID(), isPrivate: false)
        let page = BrowserPage(
            profile: profile,
            configuration: .oraDefault(userScripts: [], privacySettings: SpacePrivacySettings()),
            delegate: nil,
            passwordExtensions: runtime
        )
        defer { page.teardown() }
        page.contentView.frame = NSRect(x: 0, y: 0, width: 400, height: 220)
        for _ in 0 ..< 3 {
            try page.load(URLRequest(url: #require(URL(string: fixture + "/login"))))
            try await poll(page, "document.documentElement.dataset.passwordExtension === 'loaded'")
            _ = try await evaluate(page, "document.querySelector('[type=password]').focus()")
            try await poll(page, "document.querySelector('[type=password]').value === 'fixture-only'")
            #expect(try await evaluate(page, "document.querySelector('[autocomplete=username]').value") as? String ==
                "synthetic@example.test")
        }
        #expect(launches == 1)
        #expect(chromeLaunches == (useChrome ? 1 : 0))
        #expect(HeadlessTestHost.hasNoAppWindows)
        let privateConfiguration = WKWebViewConfiguration()
        runtime.configure(privateConfiguration, isPrivate: true)
        #expect(privateConfiguration.webExtensionController == nil)
    }

    @Test func installedAppleExtensionStartsItsRealBackground() async throws {
        guard #available(macOS 15.4, *),
              let source = ProcessInfo.processInfo.environment["ORA_APPLE_EXTENSION_PATH"] else { return }
        let runtime = PasswordExtensionRuntime(persistent: false) {
            NativePasswordMessaging(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        }
        defer { runtime.shutdown() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ApplePasswordExtensionInstaller.install(from: URL(fileURLWithPath: source), to: directory)
        try ApplePasswordExtensionInstaller.install(from: URL(fileURLWithPath: source), to: directory)
        try ApplePasswordCompatibility.prepare(directory: directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var scripts = try #require(manifest["content_scripts"] as? [[String: Any]])
        for index in scripts.indices {
            scripts[index]["js"] = ["diagnostics.js"] + (scripts[index]["js"] as? [String] ?? []) + ["sentinel.js"]
        }
        manifest["content_scripts"] = scripts
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try "window.addEventListener('error', event => {document.documentElement.dataset.oraVendorError = event.message;});"
            .write(
                to: directory.appendingPathComponent("diagnostics.js"),
                atomically: true,
                encoding: .utf8
            )
        try "document.documentElement.dataset.oraVendorLoaded='true';".write(
            to: directory.appendingPathComponent("sentinel.js"),
            atomically: true,
            encoding: .utf8
        )
        try await runtime.load(from: directory)
        #expect(runtime.context?.webExtension.displayName?.isEmpty == false)
        if let fixture = ProcessInfo.processInfo.environment["ORA_WEB_FIXTURE_URL"] {
            let page = BrowserPage(
                profile: BrowserEngineProfile(identifier: UUID(), isPrivate: false),
                configuration: .oraDefault(userScripts: [], privacySettings: SpacePrivacySettings()),
                delegate: nil,
                passwordExtensions: runtime
            )
            defer { page.teardown() }
            try page.load(URLRequest(url: #require(URL(string: fixture + "/login"))))
            try await poll(page, "document.documentElement.dataset.oraVendorLoaded === 'true'")
            _ = try await evaluate(page, "document.querySelector('[type=password]').focus()")
            try await Task.sleep(nanoseconds: 100_000_000)
            let error = try await evaluate(page, "document.documentElement.dataset.oraVendorError || ''") as? String
            #expect(error == "")
        }
        for _ in 0 ..< 100 {
            if runtime.status.contains("exited") {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(runtime.status.contains("exited"))
        #expect(HeadlessTestHost.hasNoAppWindows)
    }

    @Test func upgradesExistingCompatibilityAdapterWithoutDuplicatingScripts() throws {
        guard let source = ProcessInfo.processInfo.environment["ORA_APPLE_EXTENSION_PATH"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["background"] = ["service_worker": "ora_background.js"]
        var scripts = try #require(manifest["content_scripts"] as? [[String: Any]])
        for index in scripts.indices {
            scripts[index]["js"] = ["ora_navigation.js"] + (scripts[index]["js"] as? [String] ?? [])
        }
        manifest["content_scripts"] = scripts
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try "old adapter".write(
            to: directory.appendingPathComponent("ora_background.js"),
            atomically: true,
            encoding: .utf8
        )
        try ApplePasswordCompatibility.prepare(directory: directory)
        let first = try Data(contentsOf: manifestURL)
        try ApplePasswordCompatibility.prepare(directory: directory)
        #expect(try Data(contentsOf: manifestURL) == first)
        let upgraded = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        for entry in try #require(upgraded["content_scripts"] as? [[String: Any]]) {
            #expect((entry["js"] as? [String])?.filter { $0 == "ora_navigation.js" }.count == 1)
        }
        #expect(try String(contentsOf: directory.appendingPathComponent("ora_background.js"), encoding: .utf8)
            .contains("oraOpenPasswordPopup"))
    }

    @Test func applePopupStartsPairingOnceAtLaunchAndSurvivesRefreshes() async throws {
        try await verifyApplePopup(startAutomatically: true)
    }

    @Test func upgradesPairingPopupWithoutRewritingVendorOrSessionFiles() throws {
        guard let source = ProcessInfo.processInfo.environment["ORA_APPLE_EXTENSION_PATH"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ApplePasswordExtensionInstaller.install(from: URL(fileURLWithPath: source), to: directory)
        try "2".write(
            to: directory.appendingPathComponent("ora_compatibility_version"),
            atomically: true,
            encoding: .utf8
        )
        // Simulate an existing version 2 installation with unrelated saved state.
        let html = directory.appendingPathComponent("page_popup.html")
        try FileManager.default.removeItem(at: html)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: source).appendingPathComponent("page_popup.html"),
            to: html
        )
        let worker = try Data(contentsOf: directory.appendingPathComponent("ora_background.js"))
        let completion = try Data(contentsOf: directory.appendingPathComponent("completion_list.js"))
        let sentinel = directory.appendingPathComponent("synthetic-state.txt")
        try Data("fixture-only".utf8).write(to: sentinel)
        try ApplePasswordCompatibility.prepare(directory: directory)
        let adapted = try Data(contentsOf: html)
        try ApplePasswordCompatibility.prepare(directory: directory)
        #expect(try Data(contentsOf: html) == adapted)
        #expect(try Data(contentsOf: directory.appendingPathComponent("ora_background.js")) == worker)
        #expect(try Data(contentsOf: directory.appendingPathComponent("completion_list.js")) == completion)
        #expect(try Data(contentsOf: sentinel) == Data("fixture-only".utf8))
        #expect(try String(contentsOf: html, encoding: .utf8).components(separatedBy: "ora_popup.js").count == 2)
    }

    @Test func contentProcessFailureReportsRetryableNavigationError() throws {
        let delegate = TerminatedPageDelegate()
        let page = BrowserPage(
            profile: BrowserEngineProfile(identifier: UUID(), isPrivate: true),
            configuration: .oraDefault(userScripts: [], privacySettings: SpacePrivacySettings()),
            delegate: delegate
        )
        defer { page.teardown() }
        let view = try #require(page.contentView as? WKWebView)
        page.webViewWebContentProcessDidTerminate(view)
        #expect(delegate.error?.domain == WKError.errorDomain)
        #expect(delegate.error?.code == WKError.webContentProcessTerminated.rawValue)
    }

    @Test func embeddedAppleCompletionListOpensPopupWithoutCrashingPage() async throws {
        try await verifyApplePopup(startAutomatically: false)
    }

    private func verifyApplePopup(startAutomatically: Bool) async throws {
        guard #available(macOS 15.4, *),
              let source = ProcessInfo.processInfo.environment["ORA_APPLE_EXTENSION_PATH"],
              let fixture = ProcessInfo.processInfo.environment["ORA_WEB_FIXTURE_URL"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ApplePasswordExtensionInstaller.install(from: URL(fileURLWithPath: source), to: directory)
        if !startAutomatically {
            let file = directory.appendingPathComponent("completion_list.js")
            let original = try String(contentsOf: file, encoding: .utf8)
            try (original + """

            const clickTimer = setInterval(() => {
              const button = document.querySelector('#needToPairMessageBox');
              if (!button) return;
              clearInterval(clickTimer);
              button.dispatchEvent(new MouseEvent(effectiveClickEvent(), {bubbles:true,button:0}));
            }, 50);
            """).write(to: file, atomically: true, encoding: .utf8)
        }
        let helper = ApplePopupFixtureConnection()
        var popupView: WKWebView?
        var action: WKWebExtension.Action?
        var presentations = 0
        let runtime = PasswordExtensionRuntime(
            persistent: false, automaticallyUnlock: startAutomatically,
            popupPresenter: {
                action = $0
                popupView = $0.popupWebView
                popupView?.frame = NSRect(x: 0, y: 0, width: 380, height: 210)
                presentations += 1
            }, makeNativeConnection: { helper }
        )
        defer { action?.closePopup()
            runtime.shutdown()
        }
        try await runtime.load(from: directory)
        let page = BrowserPage(
            profile: BrowserEngineProfile(identifier: UUID(), isPrivate: false),
            configuration: .oraDefault(userScripts: [], privacySettings: SpacePrivacySettings()),
            delegate: nil, passwordExtensions: runtime
        )
        defer { page.teardown() }
        page.contentView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        page.activatePasswordExtensions()
        try page.load(URLRequest(url: #require(URL(string: fixture + "/login"))))
        try await poll(page, "!!document.querySelector('[type=password]')")
        if !startAutomatically {
            _ = try await evaluate(page, "document.querySelector('[type=password]').focus()")
        }
        for _ in 0 ..< 240 {
            if popupView != nil, helper.commands.contains(2) {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let view = try #require(popupView)
        #expect(action?.popupPopover?.behavior == .applicationDefined)
        #expect(helper.commands.contains(2))
        for _ in 0 ..< 120 {
            if await (try? view
                .evaluateJavaScript(
                    "document.querySelector('#divPIN')?.getBoundingClientRect().height > 0"
                )) as? Bool ==
                true
            {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(try await view
            .evaluateJavaScript("document.querySelector('#divPIN').getBoundingClientRect().height > 0") as? Bool ==
            true)
        #expect(try await view
            .evaluateJavaScript("document.querySelector('#divPINMessage').textContent.length > 0") as? Bool == true)
        try await verifyPopupFocus(view: view, page: page, helper: helper)
        // Offscreen WebKit pauses animation timelines. Finish the vendor's opacity fade before readback.
        _ = try await view.evaluateJavaScript("document.getAnimations().forEach(animation => animation.finish())")
        if let path = ProcessInfo.processInfo.environment["ORA_PREVIEW_DIRECTORY"] {
            let image = try await view.takeSnapshot(configuration: nil)
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(
                startAutomatically ? "apple-passwords-startup.png" : "apple-passwords-field-popup.png"
            ))
        }
        for _ in 0 ..< 3 {
            page.reload()
            try await poll(page, "!!document.querySelector('[type=password]')")
            page.activatePasswordExtensions()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(presentations == 1)
        #expect(helper.starts == 1)
        #expect(try await view.evaluateJavaScript("document.querySelector('#PIN0').value") as? String == "1")
        #expect(HeadlessTestHost.hasNoAppWindows)
    }

    @available(macOS 15.4, *)
    private func verifyPopupFocus(
        view: WKWebView,
        page: BrowserPage,
        helper: ApplePopupFixtureConnection
    ) async throws {
        let requestsBeforeFocus = helper.commands.filter { $0 == 2 }.count
        // Only synthetic digits in a disposable vendor popup; never use a real Apple challenge in tests.
        _ = try await view.evaluateJavaScript("document.querySelector('#PIN0').value='1';")
        _ = try await evaluate(page, "document.querySelector('[type=password]').focus()")
        _ = try await view.evaluateJavaScript("window.dispatchEvent(new FocusEvent('focus'))")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(try await view.evaluateJavaScript("document.querySelector('#PIN0').value") as? String == "1")
        #expect(helper.commands.filter { $0 == 2 }.count == requestsBeforeFocus)
        #expect(try await view.evaluateJavaScript("""
        Array.from(document.querySelectorAll('input.PIN')).every(input => {
            const r=input.getBoundingClientRect(); return r.width>0 && r.height>0 && r.bottom<=innerHeight;
        })
        """) as? Bool == true)
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

    private func poll(_ page: BrowserPage, _ condition: String) async throws {
        for _ in 0 ..< 240 {
            if await (try? evaluate(page, condition)) as? Bool == true {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        Issue.record("WebKit did not satisfy the password integration condition: \(condition)")
        throw CocoaError(.fileReadUnknown)
    }
}

/// Only synthetic capability replies. Pairing requests are recorded, never forwarded to Apple.
@MainActor
private final class ApplePopupFixtureConnection: PasswordMessageConnection {
    var onMessage: ((Any) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var commands: [Int] = []
    var starts = 0
    func start() throws {
        starts += 1
    }

    func send(_ message: Any) throws {
        guard let command = (message as? [String: Any])?["cmd"] as? Int else { return }
        commands.append(command)
        if command == 14 {
            Task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                onMessage?(["cmd": 14, "capabilities": [
                    "shouldUseBase64": true,
                    "operatingSystem": [
                        "name": "macos",
                        "majorVersion": 27,
                        "minorVersion": 0
                    ]
                ]])
            }
        }
    }

    func close() {}
}

private final class TerminatedPageDelegate: BrowserPageDelegate {
    var error: NSError?
    func browserPage(_ page: BrowserPage, didFailNavigationWith error: Error, failingURL: URL?) {
        self.error = error as NSError
    }
}
