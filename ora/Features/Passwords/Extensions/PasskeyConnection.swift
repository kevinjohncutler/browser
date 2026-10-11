import Foundation
import Security

@MainActor
protocol PasskeyConnection: AnyObject {
    func perform(_ request: Data, origin: String) async throws -> Data
    func cancel()
}

/// Separate embedded service connection so passkey cancellation cannot reset password pairing.
@MainActor
final class LocalPasskeyConnection: PasskeyConnection {
    private var connection: NSXPCConnection?
    private var pending: CheckedContinuation<Data, Error>?
    private var identifier: String?
    private var timeout: Task<Void, Never>?

    func perform(_ request: Data, origin: String) async throws -> Data {
        guard pending == nil, request.count <= 131_072,
              let bundle = Bundle.main.bundleIdentifier,
              let team = PasswordBridgeIdentity.teamIdentifier else { throw CocoaError(.featureUnsupported) }
        let service = bundle + ".PasswordBridge"
        let connection = NSXPCConnection(serviceName: service)
        connection.remoteObjectInterface = NSXPCInterface(with: PasswordBridgeServiceProtocol.self)
        connection.setCodeSigningRequirement(
            "anchor apple generic and identifier \"\(service)\" and certificate leaf[subject.OU] = \"\(team)\""
        )
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard self?.connection === connection else { return }
                self?.finish(nil, error: "AbortError")
            }
        }
        connection.interruptionHandler = connection.invalidationHandler
        self.connection = connection
        let identifier = UUID().uuidString
        self.identifier = identifier
        connection.resume()
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 150_000_000_000) } catch { return }
                if self?.identifier == identifier {
                    self?.cancel()
                }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                Task { @MainActor in
                    if self?.identifier == identifier {
                        self?.finish(nil, error: "NotAllowedError")
                    }
                }
            } as? PasswordBridgeServiceProtocol
            guard let proxy else { finish(nil, error: "NotSupportedError")
                return
            }
            proxy.passkey(request, origin: origin, identifier: identifier) { [weak self] data, error in
                Task { @MainActor in
                    if self?.identifier == identifier {
                        self?.finish(data, error: error)
                    }
                }
            }
        }
    }

    func cancel() {
        if let identifier,
           let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? PasswordBridgeServiceProtocol
        {
            proxy.cancelPasskey(identifier)
        }
        finish(nil, error: "AbortError")
    }

    private func finish(_ data: Data?, error: String?) {
        guard let continuation = pending else { return }
        pending = nil
        timeout?.cancel()
        timeout = nil
        identifier = nil
        let connection = connection
        self.connection = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        if let data, data.count <= 131_072, error == nil {
            continuation.resume(returning: data)
        } else {
            continuation.resume(throwing: NSError(
                domain: "OraPasskeys",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error ?? "NotAllowedError"]
            ))
        }
    }
}
