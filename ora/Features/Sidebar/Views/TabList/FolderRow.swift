import SwiftData
import SwiftUI

struct FolderRow: View {
    let folder: Folder
    let tabs: [Tab]
    @Binding var draggedItem: UUID?
    let onDrag: (UUID) -> NSItemProvider
    let onSelect: (Tab) -> Void
    let onPinToggle: (Tab) -> Void
    let onFavoriteToggle: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onDuplicate: (Tab) -> Void
    let onMoveToContainer: (Tab, TabContainer) -> Void
    let containers: [TabContainer]

    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var dialogManager: DialogManager
    @Environment(\.theme) var theme

    @State private var isHoveringHeader = false

    var body: some View {
        VStack(spacing: 4) {
            header
            if folder.isOpened {
                ForEach(tabs) { tab in
                    TabItem(
                        tab: tab,
                        isSelected: tabManager.isActive(tab),
                        isDragging: draggedItem == tab.id,
                        onTap: { onSelect(tab) },
                        onPinToggle: { onPinToggle(tab) },
                        onFavoriteToggle: { onFavoriteToggle(tab) },
                        onClose: { onClose(tab) },
                        onDuplicate: { onDuplicate(tab) },
                        onMoveToContainer: { onMoveToContainer(tab, $0) },
                        availableContainers: containers
                    )
                    .padding(.leading, 16)
                    .onDrag { onDrag(tab.id) }
                    .onDrop(
                        of: [.text],
                        delegate: TabDropDelegate(
                            item: tab,
                            draggedItem: $draggedItem,
                            targetSection: tab.type == .pinned ? .pinned : tab.type == .fav ? .fav : .normal,
                            targetFolder: folder
                        )
                    )
                }
            }
        }
        .onDrop(
            of: [.text],
            delegate: FolderDropDelegate(folder: folder, draggedItem: $draggedItem, tabManager: tabManager)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.mutedForeground)
                .rotationEffect(.degrees(folder.isOpened ? 90 : 0))
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.mutedForeground)
            Text(folder.name)
                .font(theme.textFont)
                .foregroundColor(theme.foreground)
                .lineLimit(1)
            Spacer()
            if !tabs.isEmpty {
                Text("\(tabs.count)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedForeground)
            }
        }
        .padding(theme.spacing)
        .background(
            isHoveringHeader ? theme.activeTabBackground.opacity(0.1) : .clear,
            in: .rect(cornerRadius: theme.cornerRadius)
        )
        .contentShape(Rectangle())
        .onHover { isHoveringHeader = $0 }
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                tabManager.toggleFolderOpen(folder)
            }
        }
        .onDrag { onDrag(folder.id) }
        .contextMenu {
            Button(action: showCreateSubfolderDialog) {
                Label("New Subfolder", systemImage: "folder.badge.plus")
            }
            Button(action: showRenameDialog) {
                Label("Rename Folder", systemImage: "pencil")
            }
            if folder.parentFolder != nil {
                Button(action: { tabManager.moveFolder(folder, toParent: nil) }) {
                    Label("Move to Top Level", systemImage: "arrow.up.left")
                }
            }
            Button(role: .destructive, action: { tabManager.deleteFolder(folder) }) {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    private func showCreateSubfolderDialog() {
        dialogManager.show { id in
            FolderNameDialog(
                title: "New Subfolder",
                initialName: "",
                dismiss: { dialogManager.dismiss(id: id) },
                onSave: { name in
                    tabManager.createFolder(name: name, in: folder.container, parent: folder)
                    folder.isOpened = true
                }
            )
        }
    }

    private func showRenameDialog() {
        dialogManager.show { id in
            FolderNameDialog(
                title: "Rename Folder",
                initialName: folder.name,
                dismiss: { dialogManager.dismiss(id: id) },
                onSave: { name in tabManager.renameFolder(folder, name: name) }
            )
        }
    }
}
