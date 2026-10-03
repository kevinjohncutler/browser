import SwiftData
import SwiftUI

struct NormalTabsList: View {
    let tabs: [Tab]
    let folders: [Folder]
    let container: TabContainer
    @Binding var draggedItem: UUID?
    let onDrag: (UUID) -> NSItemProvider
    let onSelect: (Tab) -> Void
    let onPinToggle: (Tab) -> Void
    let onFavoriteToggle: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onDuplicate: (Tab) -> Void
    let onMoveToContainer:
        (
            Tab,
            TabContainer
        ) -> Void
    let onAddNewTab: () -> Void
    @Query var containers: [TabContainer]
    @EnvironmentObject var tabManager: TabManager
    @State private var previousTabIds: [UUID] = []

    private var ungroupedTabs: [Tab] {
        tabs.filter { $0.folder == nil }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                NewTabButton(addNewTab: onAddNewTab)
                NewFolderButton(container: container)
            }
            ForEach(Folder.sidebarOutline(in: folders)) { entry in
                FolderRow(
                    folder: entry.folder,
                    tabs: entry.folder.sidebarTabs(in: container.tabs),
                    draggedItem: $draggedItem,
                    onDrag: onDrag,
                    onSelect: onSelect,
                    onPinToggle: onPinToggle,
                    onFavoriteToggle: onFavoriteToggle,
                    onClose: onClose,
                    onDuplicate: onDuplicate,
                    onMoveToContainer: onMoveToContainer,
                    containers: containers
                )
                .padding(.leading, CGFloat(entry.depth) * 16)
            }
            ForEach(ungroupedTabs) { tab in
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
                .onDrag { onDrag(tab.id) }
                .onDrop(
                    of: [.text],
                    delegate: TabDropDelegate(
                        item: tab,
                        draggedItem: $draggedItem,
                        targetSection: .normal
                    )
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: shouldAnimate(tab))
            }
            Text("Drop here to move out of a folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
                .onDrop(of: [.text], delegate: FolderRootDropDelegate(
                    container: container, draggedItem: $draggedItem, tabManager: tabManager
                ))
        }
        .onAppear {
            previousTabIds = ungroupedTabs.map(\.id)
        }
        .onChange(of: ungroupedTabs.map(\.id)) { _, newTabIds in
            previousTabIds = newTabIds
        }
    }

    private func shouldAnimate(_ tab: Tab) -> Bool {
        // Only animate if the tab's position has actually changed
        guard let currentIndex = ungroupedTabs.firstIndex(where: { $0.id == tab.id }),
              let previousIndex = previousTabIds.firstIndex(where: { $0 == tab.id })
        else {
            return true // Animate new tabs or tabs that were just created
        }
        return currentIndex != previousIndex
    }
}
