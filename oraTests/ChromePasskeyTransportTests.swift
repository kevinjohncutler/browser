import CryptoKit
import Foundation
@testable import Ora
import Testing

@MainActor
struct ChromePasskeyTransportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORA_PASSKEY_TRANSPORT_TEST"] == "1"))
    func nativeBrowserRejectsAnInvalidRelyingParty() async throws {
        let transport = ChromePasskeyTransport()
        transport.prepareForTesting = { transport, session in
            _ = try await transport.testCall("WebAuthn.enable", ["enableUI": false], session: session)
            _ = try await transport.testCall("WebAuthn.addVirtualAuthenticator", ["options": [
                "protocol": "ctap2", "transport": "internal", "hasResidentKey": true,
                "hasUserVerification": true, "isUserVerified": true, "automaticPresenceSimulation": true
            ]], session: session)
        }
        let request = try JSONSerialization.data(withJSONObject: ["operation": "get", "publicKey": [
            "rpId": "com", "challenge": Data("synthetic-origin-challenge".utf8).base64EncodedString()
        ]])
        do {
            _ = try await transport.perform(request, origin: "https://accounts.google.com")
            Issue.record("A public suffix was accepted as a credential relying party.")
        } catch { #expect(error.localizedDescription == "SecurityError") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORA_PASSKEY_TRANSPORT_TEST"] == "1"))
    func cancelStopsAnInFlightAuthenticatorRequest() async throws {
        let transport = ChromePasskeyTransport()
        var requested = false
        transport.onAssertionRequestedForTesting = { requested = true }
        transport.prepareForTesting = { transport, session in
            _ = try await transport.testCall("WebAuthn.enable", ["enableUI": false], session: session)
            _ = try await transport.testCall("WebAuthn.addVirtualAuthenticator", ["options": [
                "protocol": "ctap2", "transport": "internal", "hasResidentKey": true,
                "hasUserVerification": true, "isUserVerified": true, "automaticPresenceSimulation": false
            ]], session: session)
        }
        let request = try JSONSerialization.data(withJSONObject: ["operation": "get", "publicKey": [
            "rpId": "google.com", "challenge": Data("synthetic-cancel-challenge".utf8).base64EncodedString()
        ]])
        let task = Task { try await transport.perform(request, origin: "https://accounts.google.com") }
        for _ in 0 ..< 300 {
            if requested {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(requested)
        let profile = try #require(transport.profileForTesting)
        transport.stop()
        do {
            _ = try await task.value
            Issue.record("A canceled passkey request returned a credential.")
        } catch { #expect(error.localizedDescription == "AbortError") }
        #expect(!FileManager.default.fileExists(atPath: profile.path))
        #expect(HeadlessTestHost.hasNoAppWindows)
    }

    @Test func rejectsUntrustedOrigins() throws {
        for origin in [
            "http://example.com",
            "https://example.com/path",
            "https://user:password@example.com",
            "https://example.com?token=fixture",
            "https://example.com:8443",
            "file:///tmp/test"
        ] {
            #expect(throws: (any Error).self) { try ChromePasskeyTransport.validatedOrigin(origin) }
        }
        #expect(try ChromePasskeyTransport.validatedOrigin("https://accounts.google.com").host == "accounts.google.com")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORA_PASSKEY_TRANSPORT_TEST"] == "1"))
    func authenticChromeSignsSyntheticChallengeInIsolatedWorld() async throws {
        let transport = ChromePasskeyTransport()
        let key = P256.Signing.PrivateKey()
        let privateKey = key.derRepresentation
        let credentialID = Data("synthetic-passkey".utf8)
        transport.prepareForTesting = { transport, session in
            _ = try await transport.testCall("WebAuthn.enable", ["enableUI": false], session: session)
            let authenticator = try await transport.testCall("WebAuthn.addVirtualAuthenticator", [
                "options": [
                    "protocol": "ctap2",
                    "transport": "internal",
                    "hasResidentKey": true,
                    "hasUserVerification": true,
                    "isUserVerified": true,
                    "automaticPresenceSimulation": true
                ]
            ], session: session)
            let id = try #require(authenticator["authenticatorId"] as? String)
            _ = try await transport.testCall("WebAuthn.addCredential", [
                "authenticatorId": id,
                "credential": [
                    "credentialId": credentialID
                        .base64EncodedString(),
                    "isResidentCredential": true,
                    "rpId": "google.com",
                    "privateKey": privateKey
                        .base64EncodedString(),
                    "userHandle": Data("synthetic-user".utf8)
                        .base64EncodedString(),
                    "signCount": 0
                ]
            ], session: session)
        }
        let challenge = Data("synthetic-ora-challenge".utf8)
        let request: [String: Any] = ["operation": "get", "publicKey": [
            "rpId": "google.com",
            "challenge": challenge.base64EncodedString(),
            "allowCredentials": [[
                "type": "public-key",
                "id": credentialID.base64EncodedString()
            ]]
        ]]
        let result = try await transport.perform(
            JSONSerialization.data(withJSONObject: request),
            origin: "https://accounts.google.com"
        )
        let reply = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let response = try #require(reply["response"] as? [String: String])
        let client = try #require(response["clientDataJSON"].flatMap { Data(base64Encoded: $0) })
        let clientJSON = try #require(JSONSerialization.jsonObject(with: client) as? [String: Any])
        #expect(clientJSON["origin"] as? String == "https://accounts.google.com")
        #expect(clientJSON["type"] as? String == "webauthn.get")
        #expect(clientJSON["challenge"] as? String == challenge.base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_"))
        let auth = try #require(response["authenticatorData"].flatMap { Data(base64Encoded: $0) })
        #expect(auth.prefix(32) == Data(SHA256.hash(data: Data("google.com".utf8))))
        #expect(auth[32] & 0x05 == 0x05)
        var signed = auth
        signed.append(contentsOf: SHA256.hash(data: client))
        let signatureBytes = try #require(response["signature"].flatMap { Data(base64Encoded: $0) })
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureBytes)
        #expect(key.publicKey.isValidSignature(signature, for: signed))
        #expect(reply["rawId"] as? String == credentialID.base64EncodedString())
        #expect(HeadlessTestHost.hasNoAppWindows)
    }
}
