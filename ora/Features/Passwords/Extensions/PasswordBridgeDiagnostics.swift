#if DEBUG
    import AppKit
    import Foundation

    /// Diagnostic mode cannot request pairing, credentials, or application windows.
    @MainActor
    final class CapabilityOnlyPasswordConnection: PasswordMessageConnection {
        private let connection = LocalPasswordMessaging()
        var onMessage: ((Any) -> Void)?
        var onDisconnect: ((Error?) -> Void)?
        func start() throws {
            connection.onMessage = { [weak self] message in self?.onMessage?(message) }
            connection.onDisconnect = { [weak self] error in self?.onDisconnect?(error) }
            try connection.start()
        }

        func send(_ message: Any) throws {
            guard (message as? [String: Any])?["cmd"] as? Int == 14 else { return }
            try connection.send(message)
        }

        func close() {
            connection.close()
        }
    }

    @MainActor
    enum PasswordBridgeDiagnostics {
        static func runIfRequested() -> Bool {
            let environment = ProcessInfo.processInfo.environment
            let vendor = environment["ORA_PASSWORD_EXTENSION_BRIDGE_PROBE"] == "1"
            guard vendor || environment["ORA_PASSWORD_BRIDGE_PROBE"] == "1" else { return false }
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let succeeded = vendor ? await probeVendor(application) : await probeTransport()
                fflush(stdout)
                exit(succeeded ? 0 : 1)
            }
            application.run()
            return true
        }

        private static func probeVendor(_ application: NSApplication) async -> Bool {
            guard #available(macOS 15.4, *) else { return false }
            let runtime = PasswordExtensionRuntime(persistent: false) { CapabilityOnlyPasswordConnection() }
            defer { runtime.shutdown() }
            do {
                try await runtime.load(from: PasswordExtensionRuntime.installationDirectory)
                for _ in 0 ..< 400 {
                    if runtime.status == "Connected to Apple's password helper." {
                        break
                    }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                // WebKit may create an invisible text-input helper, never a browser window.
                let headless = application.windows.allSatisfy {
                    !$0.isVisible && String(describing: type(of: $0)) == "TUINSWindow"
                }
                let succeeded = runtime.status == "Connected to Apple's password helper." && headless
                let message = "Apple's real extension and real helper connected through sandboxed Ora. "
                    + "No visible windows or credential requests."
                print(succeeded ? message : runtime.status)
                return succeeded
            } catch {
                print(error.localizedDescription)
                return false
            }
        }

        private static func probeTransport() async -> Bool {
            let connection = LocalPasswordMessaging()
            defer { connection.close() }
            var result: String?
            connection.onMessage = { message in
                if (message as? [String: Any])?["cmd"] as? Int == 14 {
                    result = "Apple's real helper answered through the signed, sandboxed Ora app and local bridge. "
                        + "No credential request was sent."
                }
            }
            connection.onDisconnect = { error in result = error?.localizedDescription ?? "Bridge closed." }
            do { try connection.start()
                try connection.send(["cmd": 14])
            } catch { result = error.localizedDescription }
            for _ in 0 ..< 600 {
                if result != nil {
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            print(result ?? "Local password bridge probe timed out.")
            return result?.hasPrefix("Apple's real helper answered") == true
        }
    }
#endif
