import Foundation
import Security

/// WebKit performs the complete passkey ceremony in Ora's window. No credential shim is installed.
enum NativePasskeySupport {
    static let browserEntitlement = "com.apple.developer.web-browser.public-key-credential"

    static var hasBrowserAuthorization: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSSigningInformation),
                  &information
              ) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements[browserEntitlement] as? Bool == true
    }

    static var status: String {
        hasBrowserAuthorization ? "Apple passkeys use macOS authentication in Ora." :
            "Apple passkeys are unavailable in this build. Native access requires an authorized signed build."
    }
}
