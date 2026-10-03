import Foundation
import SwiftData

// MARK: - Folder

@Model
class Folder: ObservableObject, Identifiable {
    var id: UUID
    var name: String
    var isOpened: Bool
    var createdAt: Date = Date()

    @Relationship(inverse: \TabContainer.folders) var container: TabContainer
    @Relationship(deleteRule: .nullify) var tabs: [Tab] = []
    @Relationship(inverse: \Folder.subfolders) var parentFolder: Folder?
    @Relationship(deleteRule: .nullify) var subfolders: [Folder] = []

    init(
        id: UUID = UUID(),
        name: String,
        isOpened: Bool = true,
        createdAt: Date = Date(),
        container: TabContainer
    ) {
        self.id = id
        self.name = name
        self.isOpened = isOpened
        self.createdAt = createdAt
        self.container = container
    }
}

struct FolderOutlineEntry: Identifiable {
    let folder: Folder
    let depth: Int
    var id: UUID {
        folder.id
    }
}

extension Folder {
    /// The same outline drives rendering and regression tests. Closed folders hide descendants.
    static func sidebarOutline(in folders: [Folder]) -> [FolderOutlineEntry] {
        let ids = Set(folders.map(\.id))
        let children = Dictionary(grouping: folders) { $0.parentFolder?.id }
        var entries: [FolderOutlineEntry] = []
        var visited: Set<UUID> = []

        func append(_ folder: Folder, depth: Int) {
            guard visited.insert(folder.id).inserted else { return }
            entries.append(FolderOutlineEntry(folder: folder, depth: depth))
            if folder.isOpened {
                for child in (children[folder.id] ?? []).sorted(by: ordered) {
                    append(child, depth: depth + 1)
                }
            }
        }

        for folder in folders.filter({ folder in
            guard let parent = folder.parentFolder else { return true }
            return !ids.contains(parent.id)
        })
        .sorted(by: ordered) {
            append(folder, depth: 0)
        }
        return entries
    }

    private static func ordered(_ lhs: Folder, _ rhs: Folder) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    func sidebarTabs(in tabs: [Tab]) -> [Tab] {
        tabs.filter { $0.folder?.id == id }.sorted { $0.order > $1.order }
    }
}
