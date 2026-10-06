import CryptoKit
import Darwin
import Foundation
import Security

/// A private pipe to a headless, signed browser. No listening port or webpage access.
@MainActor
final class ChromePasswordTransport {
    static let extensionIdentifier = "pejdijmoenmkgeppbflobdenhhabjlaj"
    private var child: pid_t = 0
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var session: String?
    private var directory: URL?
    private var callbacks: [String: (Data) -> Void] = [:]
    private var disconnects: [String: (String?) -> Void] = [:]
    private var startup: Task<Void, Error>?
    private var nativeApplication = "com.apple.passwordmanager"
    #if DEBUG
        private var testNativeHost: URL?
        init(nativeHostForTesting: URL) {
            testNativeHost = nativeHostForTesting
            nativeApplication = "ora.testing.passwords"
        }
    #endif
    init() {}
    var onProcessStarted: (() -> Void)?

    func processForPairing(_ identifier: String) -> pid_t? {
        callbacks[identifier] != nil && child > 0 ? child : nil
    }

    func open(
        _ identifier: String,
        publicKey: String,
        received: @escaping (Data) -> Void,
        disconnected: @escaping (String?) -> Void
    ) async throws {
        guard callbacks[identifier] == nil else { throw failure("Duplicate password connection.") }
        try validate(publicKey)
        do {
            if let startup {
                try await startup.value
            } else if session == nil {
                let task = Task { try await self.start(publicKey: publicKey) }
                startup = task
                defer { startup = nil }
                try await task.value
            }
        } catch { stop()
            throw error
        }
        callbacks[identifier] = received
        disconnects[identifier] = disconnected
        do {
            try await evaluate("oraOpen(\(literal(identifier)), \(literal(nativeApplication)))")
        } catch {
            callbacks.removeValue(forKey: identifier)
            disconnects.removeValue(forKey: identifier)
            throw error
        }
    }

    func send(_ message: Data, identifier: String) async throws {
        guard callbacks[identifier] != nil, message.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: message) as? [String: Any]
        else {
            throw failure("Invalid password message.")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let json = String(data: data, encoding: .utf8) else { throw failure("Invalid password message.") }
        try await evaluate("oraSend(\(literal(identifier)), \(json))")
    }

    func close(_ identifier: String) async {
        callbacks.removeValue(forKey: identifier)
        disconnects.removeValue(forKey: identifier)
        if session != nil {
            try? await evaluate("oraClose(\(literal(identifier)))")
        }
        if callbacks.isEmpty {
            stop()
        }
    }

    func stop() {
        let pid = child
        child = 0
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        session = nil
        buffer.removeAll()
        startup?.cancel()
        startup = nil
        let requests = pending
        pending.removeAll()
        for task in timeouts.values {
            task.cancel()
        }
        timeouts.removeAll()
        for continuation in requests.values {
            continuation.resume(throwing: failure("Password bridge closed."))
        }
        let handlers = disconnects.values.map { $0 }
        callbacks.removeAll()
        disconnects.removeAll()
        for handler in handlers {
            handler("Apple Passwords connection closed.")
        }
        if pid > 0 {
            kill(pid, SIGTERM)
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    private func start(publicKey: String) async throws {
        // Only the genuine signed Chrome application is used, with an isolated disposable profile.
        let executable = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw failure("Install Google Chrome in Applications to enable the local Apple Passwords bridge.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expected = "anchor apple generic and identifier \"com.google.Chrome\" and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(expected as CFString, [], &requirement) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        else {
            throw failure("The local password bridge requires an authentic, signed Google Chrome installation.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OraPasswordBridge-" + UUID().uuidString)
        let relay = root.appendingPathComponent("relay")
        directory = root
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: relay,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Ora local password transport",
            "version": "1.0",
            "key": publicKey,
            "permissions": ["nativeMessaging"],
            "background": ["service_worker": "relay.js"]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: relay.appendingPathComponent("manifest.json"))
        try Self.worker.write(to: relay.appendingPathComponent("relay.js"), atomically: true, encoding: .utf8)
        #if DEBUG
            if let testNativeHost {
                let hosts = root.appendingPathComponent("profile/NativeMessagingHosts")
                try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
                let host: [String: Any] = [
                    "name": nativeApplication,
                    "description": "Synthetic password test",
                    "path": testNativeHost.path,
                    "type": "stdio",
                    "allowed_origins": ["chrome-extension://" + Self.extensionIdentifier + "/"]
                ]
                try JSONSerialization.data(withJSONObject: host)
                    .write(to: hosts.appendingPathComponent(nativeApplication + ".json"))
            }
        #endif
        try launch(executable.path, arguments: [
            "--headless=new",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-sync",
            "--disable-component-update",
            "--remote-debugging-pipe",
            "--enable-unsafe-extension-debugging",
            "--user-data-dir=" + root.appendingPathComponent("profile").path,
            "about:blank"
        ])
        do {
            _ = try await call("Extensions.loadUnpacked", ["path": relay.path])
            var target: String?
            for _ in 0 ..< 100 {
                let info = try await call("Target.getTargets")
                target = (info["targetInfos"] as? [[String: Any]])?.first {
                    $0["type"] as? String == "service_worker" && ($0["url"] as? String)?
                        .hasPrefix("chrome-extension://" + Self.extensionIdentifier + "/") == true
                }?["targetId"] as? String
                if target != nil {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let target else { throw failure("The local password transport did not start.") }
            let attachment = try await call("Target.attachToTarget", ["targetId": target, "flatten": true])
            guard let id = attachment["sessionId"] as? String
            else { throw failure("Cannot attach password transport.") }
            session = id
            _ = try await call("Runtime.enable", [:], session: id)
            _ = try await call("Runtime.addBinding", ["name": "oraReply"], session: id)
            try await evaluate("oraReady()")
        } catch { stop()
            throw error
        }
    }

    private func validate(_ key: String) throws {
        guard let data = Data(base64Encoded: key) else { throw failure("Invalid Apple extension key.") }
        let alphabet = Array("abcdefghijklmnop")
        let id = SHA256.hash(data: data).prefix(16).flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }
        guard String(id) == Self.extensionIdentifier else { throw failure("This is not Apple's extension identifier.") }
    }

    private func launch(_ executable: String, arguments: [String]) throws {
        var incoming: [Int32] = [0, 0], outgoing: [Int32] = [0, 0]
        guard pipe(&incoming) == 0 else { throw failure("Cannot create private password pipe.") }
        guard pipe(&outgoing) == 0 else { incoming.forEach { Darwin.close($0) }
            throw failure("Cannot create private password pipe.")
        }
        let readFD = fcntl(incoming[0], F_DUPFD_CLOEXEC, 10)
        let writeFD = fcntl(outgoing[1], F_DUPFD_CLOEXEC, 10)
        defer { incoming.forEach { Darwin.close($0) }
            outgoing.forEach { Darwin.close($0) }
            if readFD >= 0 {
                Darwin.close(readFD)
            }
            if writeFD >= 0 {
                Darwin.close(writeFD)
            }
        }
        guard readFD >= 0, writeFD >= 0 else { throw failure("Cannot duplicate password pipe.") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readFD, 3)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 4)
        for descriptor in 0 ... 2 {
            posix_spawn_file_actions_addopen(&actions, Int32(descriptor), "/dev/null", O_RDWR, 0)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return EINVAL }
            return posix_spawn(&pid, executable, &actions, &attributes, UnsafeMutablePointer(mutating: base), environ)
        }
        guard result == 0 else { throw failure("Cannot launch headless password transport (\(result)).") }
        child = pid
        input = FileHandle(fileDescriptor: dup(incoming[1]), closeOnDealloc: true)
        output = FileHandle(fileDescriptor: dup(outgoing[0]), closeOnDealloc: true)
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        onProcessStarted?()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            Task {
                @MainActor in if self?.child == pid {
                    self?.stop()
                }
            }
        }
    }

    private func call(
        _ method: String,
        _ params: [String: Any] = [:],
        session: String? = nil
    ) async throws -> [String: Any] {
        guard let input else { throw failure("Password transport is not running.") }
        sequence += 1
        let id = sequence
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session {
            message["sessionId"] = session
        }
        var bytes = try JSONSerialization.data(withJSONObject: message)
        bytes.append(0)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                self?.timeouts.removeValue(forKey: id)
                self?.pending.removeValue(forKey: id)?
                    .resume(throwing: self?.failure("Password transport timed out.") ?? CocoaError(.fileReadUnknown))
            }
            do { try input.write(contentsOf: bytes) } catch {
                timeouts.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    private func evaluate(_ expression: String) async throws {
        guard let session else { throw failure("Password transport has no worker.") }
        let result = try await call(
            "Runtime.evaluate",
            ["expression": expression, "returnByValue": true],
            session: session
        )
        guard result["exceptionDetails"] == nil else { throw failure("The password transport rejected a message.") }
    }

    private func receive(_ data: Data) {
        guard child > 0 else { return }
        guard !data.isEmpty else { stop()
            return
        }
        buffer.append(data)
        guard buffer.count <= 4_194_304 else { stop()
            return
        }
        while let end = buffer.firstIndex(of: 0) {
            let packet = Data(buffer[..<end])
            buffer = Data(buffer.dropFirst(end + 1))
            guard let message = try? JSONSerialization.jsonObject(with: packet) as? [String: Any] else { stop()
                return
            }
            if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                if message["error"] !=
                    nil
                {
                    continuation
                        .resume(
                            throwing: failure("The installed Chrome version cannot run the local password transport.")
                        )
                } else {
                    continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
                }
            } else if message["method"] as? String == "Runtime.bindingCalled",
                      message["sessionId"] as? String == session,
                      let params = message["params"] as? [String: Any], params["name"] as? String == "oraReply",
                      let payload = params["payload"] as? String, let bytes = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let identifier = event["identifier"] as? String
            {
                if event["kind"] as? String == "message", let body = event["message"],
                   let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 1_048_576
                {
                    callbacks[identifier]?(data)
                } else if event["kind"] as? String == "disconnect" {
                    callbacks.removeValue(forKey: identifier)
                    disconnects
                        .removeValue(forKey: identifier)?(event["error"] as? String ??
                            "Apple's password helper disconnected.")
                }
            }
        }
    }

    private func literal(_ value: String) -> String {
        // Identifiers and application names are validated strings, encoded as JSON literals.
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let result = String(data: data.dropFirst().dropLast(), encoding: .utf8) else { return "null" }
        return result
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "OraPasswordBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static let worker = #"""
    const oraPorts = new Map();
    function oraReady() { return true; }
    function oraOpen(identifier, application) {
      if (oraPorts.has(identifier)) throw Error('Duplicate port');
      const port = chrome.runtime.connectNative(application);
      oraPorts.set(identifier, port);
      port.onMessage.addListener(message => oraReply(JSON.stringify({kind:'message', identifier, message})));
      port.onDisconnect.addListener(() => {
        oraPorts.delete(identifier);
        oraReply(JSON.stringify({kind:'disconnect', identifier, error:chrome.runtime.lastError?.message}));
      });
    }
    function oraSend(identifier, message) {
      const port = oraPorts.get(identifier);
      if (!port) throw Error('Disconnected port');
      port.postMessage(message);
    }
    function oraClose(identifier) {
      const port = oraPorts.get(identifier);
      oraPorts.delete(identifier);
      port?.disconnect();
    }
    """#
}
