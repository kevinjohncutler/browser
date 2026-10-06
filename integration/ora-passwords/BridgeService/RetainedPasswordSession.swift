import CoreFoundation
import Foundation

/// Owns the native port and authenticated channel state for one macOS login session.
/// App connections attach and detach; neither pairing keys nor credentials are written to disk.
@MainActor
final class RetainedPasswordSession {
    static let shared = RetainedPasswordSession()
    private let transport: ChromePasswordTransport
    private let retainOnDetach: Bool
    private let nativeIdentifier = UUID().uuidString
    private var activeIdentifier: String?
    private var receiver: ((Data) -> Void)?
    private var disconnected: ((String?) -> Void)?
    private var opened = false
    private var opening = false
    private var publicKey: String?
    private var capabilities: Data?
    private var retainedState: Data?

    init(transport: ChromePasswordTransport? = nil, retainOnDetach: Bool = true) {
        self.transport = transport ?? ChromePasswordTransport()
        self.retainOnDetach = retainOnDetach
    }

    func attach(
        _ identifier: String,
        publicKey key: String,
        received: @escaping (Data) -> Void,
        disconnected: @escaping (String?) -> Void
    ) async throws {
        guard !opening, activeIdentifier == nil, publicKey == nil || publicKey == key else {
            throw failure("Another Ora password connection is still active.")
        }
        opening = true
        defer { opening = false }
        activeIdentifier = identifier
        receiver = received
        self.disconnected = disconnected
        do {
            if !opened {
                try await transport.open(nativeIdentifier, publicKey: key, received: { [weak self] data in
                    self?.receive(data)
                }, disconnected: { [weak self] error in
                    self?.clear()
                    self?.disconnected?(error)
                    self?.opened = false
                })
                publicKey = key
                opened = true
            }
        } catch {
            detach(identifier)
            throw error
        }
    }

    func send(_ data: Data, identifier: String) async throws {
        guard activeIdentifier == identifier, opened, data.count <= 1_048_576,
              let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw failure("Invalid Apple Passwords session message.")
        }
        if let state = message["oraSessionStore"] as? [String: Any] {
            guard retainOnDetach, Self.valid(state) else { return }
            retainedState = try JSONSerialization.data(withJSONObject: state)
            return
        }
        if message["oraSessionClear"] as? Bool == true {
            retainedState = nil
            return
        }
        if message["oraDetach"] as? Bool == true {
            return
        }
        if message["cmd"] as? Int == 14, let capabilities, let retainedState,
           var reply = try JSONSerialization.jsonObject(with: capabilities) as? [String: Any]
        {
            reply["oraRetainedSession"] = try JSONSerialization.jsonObject(with: retainedState)
            try receiver?(JSONSerialization.data(withJSONObject: reply))
            return
        }
        if message["cmd"] as? Int == 2 {
            retainedState = nil
        }
        try await transport.send(data, identifier: nativeIdentifier)
    }

    func detach(_ identifier: String) {
        guard activeIdentifier == identifier else { return }
        activeIdentifier = nil
        receiver = nil
        disconnected = nil
        if !retainOnDetach {
            reset()
        }
    }

    func reset() {
        clear()
        opened = false
        publicKey = nil
        activeIdentifier = nil
        receiver = nil
        disconnected = nil
        transport.stop()
    }

    func end(_ identifier: String) {
        if activeIdentifier == identifier {
            reset()
        }
    }

    func processForPairing(_ identifier: String) -> pid_t? {
        guard activeIdentifier == identifier else { return nil }
        return transport.processForPairing(nativeIdentifier)
    }

    func status(_ identifier: String) -> (Bool, Int32) {
        guard activeIdentifier == identifier else { return (false, 0) }
        return (retainedState != nil, processForPairing(identifier) ?? 0)
    }

    private func receive(_ data: Data) {
        if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch message["cmd"] as? Int {
            case 14: capabilities = data
            case 9, 10: retainedState = nil
            default: break
            }
        }
        // In-flight replies are discarded when the app exits. Credentials are never retained here.
        receiver?(data)
    }

    private func clear() {
        retainedState = nil
        capabilities = nil
    }

    static func valid(_ state: [String: Any]) -> Bool {
        guard Set(state.keys) == ["version", "session"], state["version"] as? Int == 1,
              let session = state["session"] as? [String: Any],
              Set(session.keys) == ["I", "encKey", "shouldUseBase64", "protocolVersion"],
              session["shouldUseBase64"] is Bool,
              let transaction = session["I"] as? String,
              transaction.range(of: "^0x[0-9a-fA-F]{1,32}$", options: .regularExpression) != nil,
              let version = session["protocolVersion"] as? Int, (0 ... 1).contains(version) else { return false }
        return ["encKey"].allSatisfy { name in
            guard let words = session[name] as? [NSNumber], words.count == 4 else { return false }
            return words.allSatisfy { word in
                let value = word.doubleValue
                return CFGetTypeID(word) != CFBooleanGetTypeID() && value.isFinite && value.rounded() == value &&
                    value >= -2_147_483_648 && value <= 4_294_967_295
            }
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "OraPasswordSession", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
