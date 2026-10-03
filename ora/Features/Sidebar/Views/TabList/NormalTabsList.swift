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

    private var sortedFolders: [Folder] {
        folders.sorted { $0.createdAt < $1.createdAt }
    }

    private var ungroupedTabs: [Tab] {
        tabs.filter { $0.folder == nil }
    }

    private func tabs(in folder: Folder) -> [Tab] {
        tabs.filter { $0.folder?.id == folder.id }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                NewTabButton(addNewTab: onAddNewTab)
                NewFolderButton(container: container)
            }
            ForEach(sortedFolders) { folder in
                FolderRow(
                    folder: folder,
                    tabs: tabs(in: folder),
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
        }
        .onDrop(
            of: [.text],
            delegate: SectionDropDelegate(
                items: ungroupedTabs,
                draggedItem: $draggedItem,
                targetSection: .normal,
                tabManager: tabManager
            )
        )
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
