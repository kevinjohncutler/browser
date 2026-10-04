import Foundation
import Security

final class PasswordBridgeService: NSObject, PasswordBridgeServiceProtocol {
    private let connection: NSXPCConnection
    @MainActor private var transport: ChromePasswordTransport?
    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func open(_ identifier: String, publicKey: String, withReply reply: @escaping (String?) -> Void) {
        guard UUID(uuidString: identifier) != nil, publicKey.utf8.count < 4096 else {
            reply("Invalid password connection.")
            return
        }
        Task { @MainActor [self] in
            if transport == nil {
                transport = ChromePasswordTransport()
            }
            do {
                try await transport?.open(identifier, publicKey: publicKey, received: { [weak self] data in
                    self?.client()?.received(data, identifier: identifier)
                }, disconnected: { [weak self] error in
                    self?.client()?.disconnected(error, identifier: identifier)
                })
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    func send(_ message: Data, identifier: String) {
        Task { @MainActor in
            do { try await transport?.send(message, identifier: identifier) }
            catch { client()?.disconnected(error.localizedDescription, identifier: identifier) }
        }
    }

    func close(_ identifier: String) {
        Task { @MainActor in await transport?.close(identifier) }
    }

    func stop() {
        Task { @MainActor in transport?.stop()
            transport = nil
        }
    }

    private func client() -> PasswordBridgeClientProtocol? {
        connection.remoteObjectProxyWithErrorHandler { _ in } as? PasswordBridgeClientProtocol
    }
}

final class BridgeListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier,
              identifier.hasSuffix(".PasswordBridge") else { return false }
        let parent = String(identifier.dropLast(".PasswordBridge".count))
        guard let team = PasswordBridgeIdentity.teamIdentifier else { return false }
        connection
            .setCodeSigningRequirement(
                "anchor apple generic and identifier \"\(parent)\" and certificate leaf[subject.OU] = \"\(team)\""
            )
        let service = PasswordBridgeService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: PasswordBridgeServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: PasswordBridgeClientProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [weak service] in service?.stop() }
        connection.interruptionHandler = { [weak service] in service?.stop() }
        connection.resume()
        return true
    }
}

let delegate = BridgeListener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
