import SwiftUI

struct NewFolderButton: View {
    let container: TabContainer

    @State private var isHovering = false
    @Environment(\.theme) private var theme
    @EnvironmentObject var dialogManager: DialogManager
    @EnvironmentObject var tabManager: TabManager

    var body: some View {
        Button(action: showCreateDialog) {
            Image(systemName: "folder.badge.plus")
                .frame(width: 12, height: 12)
                .foregroundColor(.secondary)
                .padding(8)
                .background(isHovering ? theme.activeTabBackground.opacity(0.1) : .clear, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("New Folder")
        .onHover { isHovering = $0 }
    }

    private func showCreateDialog() {
        dialogManager.show { id in
            FolderNameDialog(
                title: "New Folder",
                initialName: "",
                dismiss: { dialogManager.dismiss(id: id) },
                onSave: { name in tabManager.createFolder(name: name, in: container) }
            )
        }
    }
}
