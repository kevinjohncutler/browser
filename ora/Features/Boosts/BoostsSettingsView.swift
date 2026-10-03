import SwiftUI

struct BoostsSettingsView: View {
    @ObservedObject private var store: BoostStore
    @State private var editingID: String?
    @State private var name = ""
    @State private var pattern = ""
    @State private var css = ""
    @State private var enabled = true
    @State private var errorMessage: String?

    init(store: BoostStore = .shared) {
        self.store = store
    }

    var body: some View {
        SettingsSection {
            SettingsCard(header: "CSS Boosts") {
                Text(
                    "Save styles for a host, its subdomains (*.example.com), or every website (*). Changes apply immediately and survive restarts."
                )
                ForEach(store.rules) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(rule.name).font(.headline)
                            Text(rule.pattern).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(rule.enabled ? "Enabled" : "Disabled").foregroundStyle(.secondary)
                        Button("Edit") {
                            editingID = rule.id
                            name = rule.name
                            pattern = rule.pattern
                            css = rule.css
                            enabled = rule.enabled
                        }
                        Button("Delete", role: .destructive) {
                            do { try store.remove(id: rule.id) } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
            SettingsCard(header: editingID == nil ? "New Boost" : "Edit Boost") {
                TextField("Name", text: $name)
                TextField("example.com, *.example.com, or *", text: $pattern)
                Toggle("Enabled", isOn: $enabled)
                TextEditor(text: $css)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                HStack {
                    Button("Save CSS") {
                        do {
                            try store.save(CSSBoost(
                                id: editingID ?? UUID().uuidString,
                                name: name,
                                pattern: pattern,
                                css: css,
                                enabled: enabled
                            ))
                            reset()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(name.isEmpty || !BoostStore.validPattern(pattern))
                    Button("New Boost") { reset() }
                }
                if let message = errorMessage ?? store.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            SettingsCard(header: "Claude integration") {
                Text(
                    "The local ora-css integration can read the current regular tab and create or update these CSS rules. Private tab details are not shared."
                )
                Text("Ask Claude: Make the current Ora webpage darker using a CSS Boost.")
                    .textSelection(.enabled)
            }
        }
    }

    private func reset() {
        editingID = nil
        name = ""
        pattern = ""
        css = ""
        enabled = true
        errorMessage = nil
    }
}
