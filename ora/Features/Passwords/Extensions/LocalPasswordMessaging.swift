import Foundation
import Security

@MainActor
protocol PasswordMessageConnection: AnyObject {
    var onMessage: ((Any) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }
    func start() throws
    func send(_ message: Any) throws
    func close()
}

extension NativePasswordMessaging: PasswordMessageConnection {}

/// The signed embedded service owns a hidden Chrome process and its private pipes.
/// Apple's encrypted native protocol remains between its extension and its helper.
@MainActor
final class LocalPasswordMessaging: NSObject, PasswordMessageConnection, PasswordBridgeClientProtocol {
    private let identifier = UUID().uuidString
    private var connection: NSXPCConnection?
    private var ready = false
    private var closed = false
    private var queued: [Data] = []
    private var queueBytes = 0
    private var startupTimeout: Task<Void, Never>?
    private let publicKey: String?
    var onMessage: ((Any) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    init(publicKey: String? = nil) {
        self.publicKey = publicKey
    }

    func start() throws {
        guard connection == nil, !closed else { throw CocoaError(.fileReadUnknown) }
        let key: String
        if let publicKey {
            key = publicKey
        } else {
            let directory = URL.applicationSupportDirectory.appendingPathComponent("OraDev/Extensions/ApplePasswords")
            let manifest = try JSONSerialization
                .jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any]
            guard let value = manifest?["key"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            key = value
        }
        guard let bundle = Bundle.main.bundleIdentifier else { throw CocoaError(.fileReadUnknown) }
        let service = bundle + ".PasswordBridge"
        let connection = NSXPCConnection(serviceName: service)
        connection.remoteObjectInterface = NSXPCInterface(with: PasswordBridgeServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: PasswordBridgeClientProtocol.self)
        connection.exportedObject = self
        guard let team = PasswordBridgeIdentity.teamIdentifier else {
            throw NSError(
                domain: "OraPasswordBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Ora must be signed to connect to Apple Passwords."]
            )
        }
        connection
            .setCodeSigningRequirement(
                "anchor apple generic and identifier \"\(service)\" and certificate leaf[subject.OU] = \"\(team)\""
            )
        connection
            .invalidationHandler = { [weak self] in Task { @MainActor in
                self?.fail("Local Apple Passwords bridge stopped.")
            } }
        connection
            .interruptionHandler = { [weak self] in Task { @MainActor in
                self?.fail("Local Apple Passwords bridge interrupted.")
            } }
        self.connection = connection
        connection.resume()
        startupTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            self?.fail("The local Apple Passwords connection timed out.")
        }
        remote()?.open(identifier, publicKey: key) { [weak self] error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let error {
                    self.fail(error)
                    return
                }
                self.startupTimeout?.cancel()
                self.startupTimeout = nil
                self.ready = true
                let messages = self.queued
                self.queued.removeAll()
                self.queueBytes = 0
                for message in messages {
                    self.remote()?.send(message, identifier: self.identifier)
                }
            }
        }
    }

    func send(_ message: Any) throws {
        guard !closed, connection != nil else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONSerialization.data(withJSONObject: message)
        guard data.count <= NativeMessageFramer.maximumMessageSize else { throw CocoaError(.fileWriteUnknown) }
        if ready {
            remote()?.send(data, identifier: identifier)
        } else {
            guard queued.count < 64, queueBytes + data.count <= 2_097_152 else { throw CocoaError(.fileWriteUnknown) }
            queued.append(data)
            queueBytes += data.count
        }
    }

    func close() {
        guard !closed else { return }
        remote()?.close(identifier)
        finish(nil)
    }

    nonisolated func received(_ message: Data, identifier: String) {
        Task { @MainActor in
            guard !closed, identifier == self.identifier,
                  message.count <= NativeMessageFramer.maximumMessageSize,
                  let object = try? JSONSerialization.jsonObject(with: message) else { return }
            onMessage?(object)
        }
    }

    nonisolated func disconnected(_ error: String?, identifier: String) {
        Task { @MainActor in
            guard identifier == self.identifier else { return }
            fail(error ?? "Apple's password helper disconnected.")
        }
    }

    private func remote() -> PasswordBridgeServiceProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.fail("Cannot connect to the local Apple Passwords bridge.") }
        } as? PasswordBridgeServiceProtocol
    }

    private func fail(_ message: String) {
        finish(NSError(domain: "OraPasswordBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        startupTimeout?.cancel()
        startupTimeout = nil
        queued.removeAll()
        queueBytes = 0
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        onDisconnect?(error)
        onMessage = nil
        onDisconnect = nil
    }
}
