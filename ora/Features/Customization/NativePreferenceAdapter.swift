import AppKit
import Foundation

@MainActor
enum NativePreferenceAdapter {
    static func apply(_ changed: Set<String>, defaults: UserDefaults) {
        SettingsStore.shared.reloadPreferences(from: defaults)
        if changed.contains("appearance.mode") {
            if let raw = defaults.string(forKey: "ui.app.appearance"), let appearance = AppAppearance(rawValue: raw) {
                AppearanceManager.shared.appearance = appearance
            }
        }
        if changed.contains(where: { $0.hasPrefix("passwords.") }), #available(macOS 15.4, *),
           ProcessInfo.processInfo.environment["ORA_HEADLESS_TESTING"] != "1"
        {
            if SettingsStore.shared.passwordsEnabled, SettingsStore.shared.passwordAutofillEnabled,
               SettingsStore.shared.passwordManagerProvider == .applePasswords
            {
                PasswordExtensionRuntime.shared.startIfInstalled()
            } else {
                PasswordExtensionRuntime.shared.shutdown()
            }
        }
        if changed.contains("shortcuts.overrides") {
            CustomKeyboardShortcutManager.shared.reloadCustomShortcuts()
        }
        let ids = Set(changed.filter { $0.hasPrefix("space.") }
            .compactMap { UUID(uuidString: String($0.split(separator: ".")[1])) })
        for id in ids where changed.contains(where: { $0.hasPrefix("space.\(id.uuidString).privacy.") }) {
            SettingsStore.shared.notifySpacePrivacySettingsChanged(for: id)
            Task { await AdBlockService.shared.spaceSettingsDidChange(containerId: id) }
        }
    }
}
