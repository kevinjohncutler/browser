import AppKit
import SwiftUI

/// Handles dropping a dragged tab onto a folder header to move it into that folder.
struct FolderDropDelegate: DropDelegate {
    let folder: Folder
    @Binding var draggedItem: UUID?
    let tabManager: TabManager

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
