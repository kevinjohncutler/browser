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
        guard let provider = info.itemProviders(for: [.text]).first else { return false }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let uuid = UUID(uuidString: string) else { return }

            DispatchQueue.main.async {
                if let tab = folder.container.tabs.first(where: { $0.id == uuid }) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        tabManager.moveTab(tab, toFolder: folder)
                    }
                } else if let draggedFolder = folder.container.folders.first(where: { $0.id == uuid }) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        tabManager.moveFolder(draggedFolder, toParent: folder)
                    }
                }
            }
        }

        draggedItem = nil
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
        guard let id = draggedItem else { return false }
        if let folder = container.folders.first(where: { $0.id == id }) {
            tabManager.moveFolder(folder, toParent: nil)
        } else if let tab = container.tabs.first(where: { $0.id == id }) {
            tabManager.moveTab(tab, toFolder: nil)
        } else {
            return false
        }
        draggedItem = nil
        return true
    }
}
