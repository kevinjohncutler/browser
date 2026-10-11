import Darwin
import Foundation
import Security

/// Same-origin passkey assertions through an authentic signed browser, over private pipes.
/// Every request has a disposable profile. No credential keys or assertions are logged.
@MainActor
final class ChromePasskeyTransport {
    private var child: pid_t = 0
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingMethods: [Int: String] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var directory: URL?
    private var reaper: Task<Void, Never>?
    #if DEBUG
        var prepareForTesting: ((ChromePasskeyTransport, String) async throws -> Void)?
        var onAssertionRequestedForTesting: (() -> Void)?
        var profileForTesting: URL? {
            directory
        }

        func testCall(_ method: String, _ params: [String: Any], session: String) async throws -> [String: Any] {
            try await call(method, params, session: session)
        }
    #endif

    static func validatedOrigin(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, !host.isEmpty, url.port == nil || url.port == 443,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil
        else {
            throw failure("SecurityError")
        }
        return url
    }

    func perform(_ request: Data, origin: String) async throws -> Data {
        guard child == 0, reaper == nil else { throw Self.failure("NotAllowedError") }
        do {
            let result = try await performRequest(request, origin: origin)
            stop()
            await reaper?.value
            reaper = nil
            return result
        } catch {
            stop()
            await reaper?.value
            reaper = nil
            throw error
        }
    }

    private func performRequest(_ request: Data, origin: String) async throws -> Data {
        let url = try Self.validatedOrigin(origin)
        guard request.count <= 131_072,
              let options = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let operation = options["operation"] as? String,
              operation == "available" || operation == "get" else { throw Self.failure("NotSupportedError") }
        try Task.checkCancellation()
        try start()
        let target = try await call("Target.createTarget", ["url": "about:blank"])
        guard let targetID = target["targetId"] as? String else { throw Self.failure("NotAllowedError") }
        let attachment = try await call("Target.attachToTarget", ["targetId": targetID, "flatten": true])
        guard let session = attachment["sessionId"] as? String else { throw Self.failure("NotAllowedError") }
        _ = try await call("Page.enable", session: session)
        _ = try await call("Runtime.enable", session: session)
        let navigation = try await call("Page.navigate", ["url": url.absoluteString], session: session)
        guard navigation["errorText"] == nil else { throw Self.failure("NotAllowedError") }
        var frame: String?
        for _ in 0 ..< 200 {
            try Task.checkCancellation()
            let result = try await call("Runtime.evaluate", [
                "expression": "({origin: location.origin, ready: document.readyState === 'complete'})",
                "returnByValue": true
            ], session: session)
            let state = (result["result"] as? [String: Any])?["value"] as? [String: Any]
            if state?["ready"] as? Bool == true, state?["origin"] as? String == origin {
                let tree = try await call("Page.getFrameTree", session: session)
                frame = ((tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let frame else { throw Self.failure("SecurityError") }
        // Isolate authentication from the destination site's own scripts and credentials hooks.
        let world = try await call("Page.createIsolatedWorld", [
            "frameId": frame, "worldName": "ora-passkeys", "grantUniveralAccess": false
        ], session: session)
        guard let context = world["executionContextId"] as? Int else { throw Self.failure("SecurityError") }
        #if DEBUG
            try await prepareForTesting?(self, session)
            if operation == "get" {
                onAssertionRequestedForTesting?()
            }
        #endif
        let result = try await call("Runtime.callFunctionOn", [
            "functionDeclaration": Self.assertion,
            "executionContextId": context,
            "arguments": [["value": options], ["value": origin]],
            "awaitPromise": true, "returnByValue": true, "userGesture": operation == "get"
        ], session: session)
        guard result["exceptionDetails"] == nil,
              let value = (result["result"] as? [String: Any])?["value"] as? [String: Any]
        else {
            throw Self.failure("NotAllowedError")
        }
        if let error = value["error"] as? String {
            throw Self.failure(error)
        }
        return try JSONSerialization.data(withJSONObject: value)
    }

    func stop() {
        let pid = child
        child = 0
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        buffer.removeAll()
        let requests = pending
        pending.removeAll()
        pendingMethods.removeAll()
        for task in timeouts.values {
            task.cancel()
        }
        timeouts.removeAll()
        for continuation in requests.values {
            continuation.resume(throwing: Self.failure("AbortError"))
        }
        if pid > 0 {
            kill(pid, SIGTERM)
        }
        // The child can still have open profile files. Its waiter cleans up after exit.
        directory = nil
    }

    private func start() throws {
        let executable = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expected = "anchor apple generic and identifier \"com.google.Chrome\" and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(expected as CFString, [], &requirement) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        else {
            throw Self.failure("NotSupportedError")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OraPasskeys-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        directory = root
        do {
            try launch(executable.path, arguments: [
                "--headless=new", "--no-first-run", "--no-default-browser-check",
                "--disable-background-networking", "--disable-sync", "--disable-component-update",
                "--remote-debugging-pipe", "--user-data-dir=" + root.path, "about:blank"
            ])
        } catch {
            try? FileManager.default.removeItem(at: root)
            directory = nil
            throw error
        }
    }

    private static func failure(_ name: String) -> NSError {
        NSError(domain: "OraPasskeys", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
    }

    private func failure(_ name: String) -> NSError {
        Self.failure(name)
    }

    private static let assertion = #"""
    async function(request, origin) {
      try {
        if (location.origin !== origin || !isSecureContext || window !== window.top)
          return {error: 'SecurityError'};
        if (request.operation === 'available')
          return {available: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()};
        const decode = value => Uint8Array.from(atob(value), c => c.charCodeAt(0));
        const encode = buffer => buffer == null ? null : btoa(String.fromCharCode(...new Uint8Array(buffer)));
        const key = {...request.publicKey, challenge: decode(request.publicKey.challenge)};
        if (key.allowCredentials) key.allowCredentials = key.allowCredentials.map(c => ({...c, id: decode(c.id), transports:['internal']}));
        key.hints = ['client-device'];
        key.userVerification = 'required';
        key.timeout = Math.min(key.timeout || 120000, 120000);
        const credential = await navigator.credentials.get({publicKey: key});
        if (location.origin !== origin) return {error: 'SecurityError'};
        const response = credential.response;
        return {id: credential.id, type: credential.type, rawId: encode(credential.rawId),
          authenticatorAttachment: credential.authenticatorAttachment,
          response: {clientDataJSON: encode(response.clientDataJSON),
            authenticatorData: encode(response.authenticatorData), signature: encode(response.signature),
            userHandle: encode(response.userHandle)}, extensions: credential.getClientExtensionResults()};
      } catch (error) { return {error: error.name || 'NotAllowedError'}; }
    }
    """#
    private func launch(_ executable: String, arguments: [String]) throws {
        var incoming: [Int32] = [0, 0], outgoing: [Int32] = [0, 0]
        guard pipe(&incoming) == 0 else { throw failure("Cannot create private passkey pipe.") }
        guard pipe(&outgoing) == 0 else { incoming.forEach { Darwin.close($0) }
            throw failure("Cannot create private passkey pipe.")
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
        guard readFD >= 0, writeFD >= 0 else { throw failure("Cannot duplicate passkey pipe.") }
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
        guard result == 0 else { throw failure("Cannot launch headless passkey transport (\(result)).") }
        child = pid
        input = FileHandle(fileDescriptor: dup(incoming[1]), closeOnDealloc: true)
        output = FileHandle(fileDescriptor: dup(outgoing[0]), closeOnDealloc: true)
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                if self?.child == pid {
                    self?.receive(data)
                }
            }
        }
        let profile = directory
        reaper = Task { [weak self] in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                    if let profile {
                        try? FileManager.default.removeItem(at: profile)
                    }
                    Task { @MainActor in
                        if self?.child == pid {
                            self?.stop()
                        }
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func call(
        _ method: String,
        _ params: [String: Any] = [:],
        session: String? = nil
    ) async throws -> [String: Any] {
        guard let input else { throw failure("Passkey transport is not running.") }
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
            pendingMethods[id] = method
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 130_000_000_000) } catch { return }
                self?.timeouts.removeValue(forKey: id)
                self?.pendingMethods.removeValue(forKey: id)
                self?.pending.removeValue(forKey: id)?
                    .resume(throwing: self?.failure("Passkey transport timed out.") ?? CocoaError(.fileReadUnknown))
            }
            do { try input.write(contentsOf: bytes) } catch {
                timeouts.removeValue(forKey: id)?.cancel()
                pendingMethods.removeValue(forKey: id)
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
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
                let method = pendingMethods.removeValue(forKey: id) ?? "unknown"
                if message["error"] !=
                    nil
                {
                    continuation
                        .resume(
                            throwing: failure("Passkey transport rejected " + method)
                        )
                } else {
                    continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
                }
            }
        }
    }
}
