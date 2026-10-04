import AppKit
import SwiftUI

@available(macOS 15.4, *)
struct ApplePasswordsExtensionSettings: View {
    @ObservedObject private var runtime = PasswordExtensionRuntime.shared
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(runtime.status).font(.caption).foregroundStyle(.secondary)
            Text(
                "Apple Passwords stays connected as you browse. Google Chrome must be installed as a hidden local helper."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Install Apple Passwords extension") { install() }
                Button("Unlock Apple Passwords") { runtime.showAction() }
                    .disabled(runtime.context == nil)
                Button("Manage passwords") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Passwords.app"))
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .task { runtime.startIfInstalled() }
    }

    private func install() {
        let panel = NSOpenPanel()
        panel.title = "Choose the installed Apple Passwords extension folder"
        panel.message = "Choose the folder containing Apple's manifest.json. Ora copies the extension code, without importing passwords."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try ApplePasswordExtensionInstaller.install(
                from: source,
                to: PasswordExtensionRuntime.installationDirectory
            )
            Task {
                do { try await runtime.load(from: PasswordExtensionRuntime.installationDirectory) }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
