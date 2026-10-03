import AppKit
import SwiftUI

/// Moves a tab or folder into another folder.
struct FolderDropDelegate: DropDelegate {
    let folder: Folder
    @Binding var draggedItem: UUID?
    let tabManager: TabManager

    func validateDrop(info: DropInfo) -> Bool {
        draggedItem != nil && draggedItem != folder.id
    }

    func dropEntered(info: DropInfo) {
        performHapticFeedback(pattern: .alignment)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        completeDrop()
    }

    /// Internal drags carry their identity in the shared binding. This also supports offscreen tests.
    func completeDrop() -> Bool {
        guard let id = draggedItem else { return false }
        defer { draggedItem = nil }
        if let tab = folder.container.tabs.first(where: { $0.id == id }) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                tabManager.moveTab(tab, toFolder: folder)
            }
        } else if let source = folder.container.folders.first(where: { $0.id == id }) {
            tabManager.moveFolder(source, toParent: folder)
            return source.parentFolder?.id == folder.id
        } else {
            return false
        }
        return true
    }
}

/// A dedicated target keeps un-nesting separate from hovering over existing folder rows.
struct FolderRootDropDelegate: DropDelegate {
    let container: TabContainer
    @Binding var draggedItem: UUID?
    let tabManager: TabManager

    func validateDrop(info: DropInfo) -> Bool {
        draggedItem != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        completeDrop()
    }

    func completeDrop() -> Bool {
        guard let id = draggedItem else { return false }
        defer { draggedItem = nil }
        if let folder = container.folders.first(where: { $0.id == id }) {
            tabManager.moveFolder(folder, toParent: nil)
        } else if let tab = container.tabs.first(where: { $0.id == id }) {
            tabManager.moveTab(tab, toFolder: nil)
        } else {
            return false
        }
        return true
    }
}
