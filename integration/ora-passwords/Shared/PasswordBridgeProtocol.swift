import Foundation

@objc protocol PasswordBridgeServiceProtocol {
    func open(_ identifier: String, publicKey: String, withReply reply: @escaping (String?) -> Void)
    func send(_ message: Data, identifier: String)
    func close(_ identifier: String)
}

@objc protocol PasswordBridgeClientProtocol {
    func received(_ message: Data, identifier: String)
    func disconnected(_ error: String?, identifier: String)
}
