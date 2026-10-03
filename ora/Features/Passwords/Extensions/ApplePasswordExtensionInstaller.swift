import CryptoKit
import Foundation

enum ApplePasswordExtensionInstaller {
    static func install(from source: URL, to destination: URL) throws {
        let manifest = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        guard let json = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              json["manifest_version"] as? Int == 3,
              let key = json["key"] as? String,
              let publicKey = Data(base64Encoded: key)
        else { throw CocoaError(.fileReadCorruptFile) }
        // Chrome's extension ID binds the manifest public key to Apple's known extension.
        let digest = SHA256.hash(data: publicKey)
        let alphabet = Array("abcdefghijklmnop")
        let identifier = digest.prefix(16).flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }
        guard String(identifier) == NativePasswordMessaging.extensionIdentifier
        else { throw CocoaError(.fileReadNoPermission) }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: source, to: staged)
        // Never follow extension-folder symlinks to unrelated user data.
        guard let files = manager.enumerator(at: staged, includingPropertiesForKeys: [.isSymbolicLinkKey])
        else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey])
                .isSymbolicLink == true
            {
                throw CocoaError(.fileReadNoPermission)
            }
        }
        try ApplePasswordCompatibility.prepare(directory: staged)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }
}
