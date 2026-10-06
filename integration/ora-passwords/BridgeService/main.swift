import Darwin
import Dispatch
import Foundation
import Security

final class PasswordBridgeService: NSObject, PasswordBridgeServiceProtocol {
    private let connection: NSXPCConnection
    private let persistent: Bool
    @MainActor private var session: RetainedPasswordSession?
    @MainActor private var identifier: String?
    @MainActor private var stopped = false
    @MainActor private var pairingReader: ApplePasswordPairingReader?
    init(connection: NSXPCConnection, persistent: Bool) {
        self.connection = connection
        self.persistent = persistent
    }

    func open(_ identifier: String, publicKey: String, withReply reply: @escaping (String?) -> Void) {
        guard UUID(uuidString: identifier) != nil, publicKey.utf8.count < 4096 else {
            reply("Invalid password connection.")
            return
        }
        Task { @MainActor [self] in
            guard !stopped else { reply("Password connection closed.")
                return
            }
            if session == nil {
                session = persistent ? .shared : RetainedPasswordSession(retainOnDetach: false)
            }
            guard let session else { reply("Password connection unavailable.")
                return
            }
            self.identifier = identifier
            do {
                try await session.attach(identifier, publicKey: publicKey, received: { [weak self] data in
                    self?.client()?.received(data, identifier: identifier)
                }, disconnected: { [weak self] error in
                    self?.client()?.disconnected(error, identifier: identifier)
                })
                if stopped {
                    session.detach(identifier)
                }
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    func send(_ message: Data, identifier: String) {
        Task { @MainActor in
            do { try await session?.send(message, identifier: identifier) }
            catch { client()?.disconnected(error.localizedDescription, identifier: identifier) }
        }
    }

    func close(_ identifier: String) {
        Task { @MainActor in session?.detach(identifier) }
    }

    func readPairingCode(_ identifier: String, withReply reply: @escaping (String?, String?) -> Void) {
        Task { @MainActor in
            guard let pid = session?.processForPairing(identifier) else {
                reply(nil, "The Apple Passwords connection is not ready.")
                return
            }
            if pairingReader == nil {
                pairingReader = ApplePasswordPairingReader()
            }
            do { try await reply(pairingReader?.read(parentPID: pid), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func sessionStatus(_ identifier: String, withReply reply: @escaping (Bool, Int32) -> Void) {
        Task { @MainActor in
            let status = session?.status(identifier) ?? (false, 0)
            reply(status.0, status.1)
        }
    }

    func endSession(_ identifier: String, withReply reply: @escaping () -> Void) {
        Task { @MainActor in
            pairingReader?.cancel()
            session?.end(identifier)
            reply()
        }
    }

    func stop() {
        Task { @MainActor in
            stopped = true
            if let identifier {
                session?.detach(identifier)
            }
            pairingReader?.cancel()
            pairingReader = nil
            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
        }
    }

    private func client() -> PasswordBridgeClientProtocol? {
        connection.remoteObjectProxyWithErrorHandler { _ in } as? PasswordBridgeClientProtocol
    }
}

final class BridgeListener: NSObject, NSXPCListenerDelegate {
    private let persistent: Bool
    init(persistent: Bool) {
        self.persistent = persistent
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier,
              identifier.hasSuffix(".PasswordBridge") else { return false }
        let parent = String(identifier.dropLast(".PasswordBridge".count))
        guard let team = PasswordBridgeIdentity.teamIdentifier else { return false }
        connection
            .setCodeSigningRequirement(
                "anchor apple generic and identifier \"\(parent)\" and certificate leaf[subject.OU] = \"\(team)\""
            )
        let service = PasswordBridgeService(connection: connection, persistent: persistent)
        connection.exportedInterface = NSXPCInterface(with: PasswordBridgeServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: PasswordBridgeClientProtocol.self)
        connection.exportedObject = service
        // Retain the service until it detaches the client. Exported objects can be released first.
        connection.invalidationHandler = { service.stop() }
        connection.interruptionHandler = { service.stop() }
        connection.resume()
        return true
    }
}

let persistent = CommandLine.arguments.contains("--session-agent")
let delegate = BridgeListener(persistent: persistent)
let serviceName = String((Bundle.main.bundleIdentifier ?? "").dropLast(".PasswordBridge".count)) + ".PasswordSession"
let listener = persistent ? NSXPCListener(machServiceName: serviceName) : NSXPCListener.service()
listener.delegate = delegate
listener.resume()
if persistent {
    // launchctl unload and logout must stop our private browser and discard its channel state.
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termination.setEventHandler {
        Task { @MainActor in RetainedPasswordSession.shared.reset()
            exit(0)
        }
    }
    termination.resume()
    RunLoop.main.run()
}
