import Foundation

@objc protocol PasswordBridgeServiceProtocol {
    func open(_ identifier: String, publicKey: String, withReply reply: @escaping (String?) -> Void)
    func send(_ message: Data, identifier: String)
    func close(_ identifier: String)
    func readPairingCode(_ identifier: String, withReply reply: @escaping (String?, String?) -> Void)
    func sessionStatus(_ identifier: String, withReply reply: @escaping (Bool, Int32) -> Void)
    func endSession(_ identifier: String, withReply reply: @escaping () -> Void)
    func passkey(
        _ request: Data,
        origin: String,
        identifier: String,
        withReply reply: @escaping (Data?, String?) -> Void
    )
    func cancelPasskey(_ identifier: String)
}

@objc protocol PasswordBridgeClientProtocol {
    func received(_ message: Data, identifier: String)
    func disconnected(_ error: String?, identifier: String)
}
