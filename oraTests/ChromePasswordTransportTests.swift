import Foundation
@testable import Ora
import Testing

@MainActor
struct ChromePasswordTransportTests {
    @Test func rejectsUnknownExtensionIdentityBeforeLaunching() async throws {
        let transport = ChromePasswordTransport()
        defer { transport.stop() }
        var launches = 0
        transport.onProcessStarted = { launches += 1 }
        await #expect(throws: (any Error).self) {
            try await transport.open(
                UUID().uuidString,
                publicKey: Data("not-apple".utf8).base64EncodedString(),
                received: { _ in },
                disconnected: { _ in }
            )
        }
        #expect(launches == 0)
    }

    @Test func headlessChromeRelaysMultipleRequestsThroughOneNativeSession() async throws {
        guard let source = ProcessInfo.processInfo.environment["ORA_APPLE_EXTENSION_PATH"],
              let python = ProcessInfo.processInfo.environment["ORA_PYTHON_PATH"] else { return }
        let manifest = try #require(JSONSerialization
            .jsonObject(with: Data(contentsOf: URL(fileURLWithPath: source)
                    .appendingPathComponent("manifest.json"))) as? [String: Any])
        let key = try #require(manifest["key"] as? String)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("synthetic-helper")
        try """
        #!\(python)
        import json,struct,sys
        for _ in range(100):
            header=sys.stdin.buffer.read(4)
            if not header: break
            body=json.loads(sys.stdin.buffer.read(struct.unpack('<I',header)[0]))
            reply=json.dumps({'number':body['number'],'username':'synthetic@example.test','password':'fixture-only'}).encode()
            sys.stdout.buffer.write(struct.pack('<I',len(reply))+reply)
            sys.stdout.buffer.flush()
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let transport = ChromePasswordTransport(nativeHostForTesting: helper)
        defer { transport.stop() }
        var launches = 0
        transport.onProcessStarted = { launches += 1 }
        var replies: [[String: Any]] = []
        var error: String?
        let id = UUID().uuidString
        try await transport.open(id, publicKey: key, received: { data in
            if let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                replies.append(reply)
            }
        }, disconnected: { error = $0 })
        for number in 0 ..< 3 {
            try await transport.send(JSONSerialization.data(withJSONObject: ["number": number]), identifier: id)
            for _ in 0 ..< 100 {
                if replies.count == number + 1 || error != nil {
                    break
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            #expect(error == nil)
            #expect(replies.count == number + 1)
        }
        #expect(replies.compactMap { $0["number"] as? Int } == [0, 1, 2])
        #expect(replies.last?["password"] as? String == "fixture-only")
        #expect(launches == 1)
        #expect(HeadlessTestHost.hasNoAppWindows)
        await transport.close(id)
    }
}

/// Connects the actual shipped Chrome transport to WebKit's real extension port in tests.
@MainActor
final class ChromeTestPasswordConnection: PasswordMessageConnection {
    private let transport: ChromePasswordTransport
    private let publicKey: String
    private let identifier = UUID().uuidString
    private var startup: Task<Void, Error>?
    private var closed = false
    var onMessage: ((Any) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    init(transport: ChromePasswordTransport, publicKey: String) {
        self.transport = transport
        self.publicKey = publicKey
    }

    func start() throws {
        startup = Task {
            try await transport.open(identifier, publicKey: publicKey, received: { [weak self] data in
                guard let self, !closed, let message = try? JSONSerialization.jsonObject(with: data) else { return }
                onMessage?(message)
            }, disconnected: { [weak self] message in
                guard let self, !closed else { return }
                onDisconnect?(NSError(
                    domain: "ChromeTestPasswordConnection",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message ?? "Disconnected"]
                ))
            })
        }
    }

    func send(_ message: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        Task {
            do {
                try await startup?.value
                guard !closed else { return }
                try await transport.send(data, identifier: identifier)
            } catch { onDisconnect?(error) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        startup?.cancel()
        transport.stop()
    }
}
