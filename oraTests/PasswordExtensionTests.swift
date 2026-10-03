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
        guard #available(macOS 15.4, *), let fixture = ProcessInfo.processInfo.environment["ORA_WEB_FIXTURE_URL"],
              let python = ProcessInfo.processInfo.environment["ORA_PYTHON_PATH"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper.py")
        try """
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
        let runtime = PasswordExtensionRuntime(persistent: false) {
            launches += 1
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
