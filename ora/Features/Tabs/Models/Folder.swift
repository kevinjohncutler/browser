import Foundation
import SwiftData

// MARK: - Folder

@Model
class Folder: ObservableObject, Identifiable {
    var id: UUID
    var name: String
    var isOpened: Bool
    var createdAt: Date

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
