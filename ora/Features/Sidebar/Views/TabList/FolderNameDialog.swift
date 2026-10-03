import SwiftUI

/// Shared name-entry dialog used for both creating and renaming a folder.
struct FolderNameDialog: View {
    let title: String
    let initialName: String
    let dismiss: () -> Void
    let onSave: (String) -> Void

    @State private var name: String = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.foreground)

                TextField("Folder name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)

                HStack {
                    OraButton(label: "Cancel", variant: .secondary, keyboardShortcut: "esc", action: dismiss)
                    Spacer()
                    OraButton(label: "Save", isDisabled: name.isEmpty, keyboardShortcut: "return", action: save)
                }
            }
            .frame(width: 320)
            .padding(16)
            .background(theme.popoverMutedBackground)
            .cornerRadius(11)
            .overlay {
                ConditionallyConcentricRectangle(cornerRadius: 11)
                    .stroke(theme.border, lineWidth: 0.5)
            }
        }
        .padding(3)
        .background(theme.popoverBackground)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .onAppear { name = initialName }
    }

    private func save() {
        guard !name.isEmpty else { return }
        onSave(name)
        dismiss()
    }
}
