import Foundation
import Testing

@MainActor
struct RetainedPasswordSessionTests {
    static let syntheticState: [String: Any] = ["version": 1, "session": [
        "I": "0x123456789abcdef", "encKey": [1, 2, 3, 4], "shouldUseBase64": true, "protocolVersion": 1
    ]]

    @Test func retainsNativePortAcrossBrowserConnectionsAndHonorsAppleExpiration() async throws {
        guard let source = ProcessInfo.processInfo.environment["ORA_APPLE_EXTENSION_PATH"],
              let python = ProcessInfo.processInfo.environment["ORA_PYTHON_PATH"] else { return }
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: source).appendingPathComponent("manifest.json"))) as? [String: Any])
        let key = try #require(manifest["key"] as? String)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("synthetic-helper")
        try """
        #!\(python)
        import json,struct,sys
        count=0
        while True:
            header=sys.stdin.buffer.read(4)
            if not header: break
            message=json.loads(sys.stdin.buffer.read(struct.unpack('<I',header)[0]))
            count+=1
            reply=json.dumps({'cmd':message['cmd'],'capabilities':{'synthetic':True},'count':count}).encode()
            sys.stdout.buffer.write(struct.pack('<I',len(reply))+reply)
            sys.stdout.buffer.flush()
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let transport = ChromePasswordTransport(nativeHostForTesting: helper)
        var launches = 0
        transport.onProcessStarted = { launches += 1 }
        let session = RetainedPasswordSession(transport: transport)
        defer { session.reset() }
        var replies: [[String: Any]] = []
        var error: String?
        let receive: (Data) -> Void = { data in
            if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                replies.append(value)
            }
        }
        let first = UUID().uuidString
        try await session.attach(first, publicKey: key, received: receive, disconnected: { error = $0 })
        try await session.send(JSONSerialization.data(withJSONObject: ["cmd": 14]), identifier: first)
        try await wait { replies.count == 1 }
        try await session.send(
            JSONSerialization.data(withJSONObject: ["oraSessionStore": Self.syntheticState]),
            identifier: first
        )
        session.detach(first)
        let second = UUID().uuidString
        try await session.attach(second, publicKey: key, received: receive, disconnected: { error = $0 })
        try await session.send(JSONSerialization.data(withJSONObject: ["cmd": 14]), identifier: second)
        try await wait { replies.count == 2 }
        #expect(replies[1]["oraRetainedSession"] != nil)
        #expect(replies[1]["count"] as? Int == 1)
        #expect(launches == 1)
        // A server expiration must invalidate the retained pairing, even while the app is closed.
        try await session.send(JSONSerialization.data(withJSONObject: ["cmd": 10]), identifier: second)
        try await wait { replies.count == 3 }
        session.detach(second)
        let third = UUID().uuidString
        try await session.attach(third, publicKey: key, received: receive, disconnected: { error = $0 })
        try await session.send(JSONSerialization.data(withJSONObject: ["cmd": 14]), identifier: third)
        try await wait { replies.count == 4 }
        #expect(replies[3]["oraRetainedSession"] == nil)
        #expect(replies[3]["count"] as? Int == 3)
        #expect(error == nil)
        #expect(launches == 1)
        session.end(third)
        #expect(session.status(third).0 == false)
        #expect(session.status(third).1 == 0)
        let fourth = UUID().uuidString
        try await session.attach(fourth, publicKey: key, received: receive, disconnected: { error = $0 })
        try await session.send(JSONSerialization.data(withJSONObject: ["cmd": 14]), identifier: fourth)
        try await wait { replies.count == 5 }
        #expect(replies[4]["oraRetainedSession"] == nil)
        #expect(replies[4]["count"] as? Int == 1)
        #expect(launches == 2)
    }

    @Test func retainedStateCannotIncludeAPasswordOrPairingCode() throws {
        #expect(RetainedPasswordSession.valid(Self.syntheticState))
        var state = Self.syntheticState
        state["password"] = "fixture-only"
        #expect(!RetainedPasswordSession.valid(state))
        state = Self.syntheticState
        var channel = try #require(state["session"] as? [String: Any])
        channel["PIN"] = "482913"
        state["session"] = channel
        #expect(!RetainedPasswordSession.valid(state))
        channel.removeValue(forKey: "PIN")
        channel["encKey"] = [true, true, true, true]
        state["session"] = channel
        #expect(!RetainedPasswordSession.valid(state))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 120 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw CocoaError(.fileReadUnknown)
    }
}
