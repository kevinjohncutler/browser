import AppKit
import Foundation
@testable import Ora
import SwiftData
import SwiftUI
import Testing

@MainActor
struct ImporterTests {
    static func fixture() throws -> Root {
        func item(
            _ id: String,
            _ parent: String?,
            title: String? = nil,
            children: [String] = [],
            url: String? = nil,
            system: Bool = false
        ) -> [String: Any] {
            var value: [String: Any] = ["id": id, "isUnread": false, "childrenIds": children]
            if let parent {
                value["parentID"] = parent
            }
            if let title {
                value["title"] = title
            }
            if let url {
                value["data"] = ["tab": ["savedURL": url, "savedTitle": title ?? id]]
            }
            if system {
                value["data"] = ["itemContainer": ["containerType": ["topApps": ["_0": ["default": true]]]]]
            }
            return value
        }
        let space: [String: Any] = [
            "id": "space",
            "title": "Test Space",
            "containerIDs": ["pinned"],
            "customInfo": ["iconType": ["emoji_v2": ""]]
        ]
        let items = [
            item("pinned", "space", children: ["parent", "loose"], system: true),
            item("parent", "pinned", title: "Projects", children: ["child", "direct", "empty"]),
            item("child", "parent", title: "Research", children: ["grandchild", "nested"]),
            item("grandchild", "child", title: "References", children: ["deep"]),
            item("empty", "parent", title: "Empty Folder"),
            item("direct", "parent", title: "Direct Tab", url: "https://example.com/direct"),
            item("nested", "child", title: "Nested Tab", url: "https://example.com/nested"),
            item("deep", "grandchild", title: "Deep Tab", url: "https://example.com/deep"),
            item("loose", "pinned", title: "Loose Tab", url: "https://example.com/loose"),
            item("favorite", "favorites", title: "Favorite Tab", url: "https://example.com/favorite"),
            item("favorites", nil, children: ["favorite"], system: true),
            item("cycle-a", "cycle-b", title: "Cycle A", children: ["cycle-b"]),
            item("cycle-b", "cycle-a", title: "Cycle B", children: ["cycle-a"])
        ]
        let json: [String: Any] = ["sidebar": ["containers": [
            ["spaces": [space], "items": items, "topAppsContainerIDs": ["favorites"]]
        ]]]
        return try JSONDecoder().decode(Root.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func makeManager(configuration: ModelConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)) throws
        -> TabManager
    {
        let container = try ModelContainer(
            for: TabContainer.self,
            Tab.self,
            Folder.self,
            History.self,
            Download.self,
            configurations: configuration
        )
        return TabManager(
            modelContainer: container,
            modelContext: ModelContext(container),
            mediaController: MediaController()
        )
    }

    static func runImport(_ root: Root, manager: TabManager) {
        importArcData(
            tabManager: manager,
            historyManager: HistoryManager(
                modelContainer: manager.modelContainer,
                modelContext: manager.modelContext
            ),
            downloadManager: DownloadManager(
                modelContainer: manager.modelContainer,
                modelContext: manager.modelContext
            ),
            isPrivate: false,
            root: root
        )
    }

    @Test func importsNestedAndEmptyFoldersWithoutLosingTabs() throws {
        let root = try Self.fixture()
        let manager = try Self.makeManager()
        Self.runImport(root, manager: manager)
        let space = try #require(manager.modelContext.fetch(FetchDescriptor<TabContainer>())
            .first { $0.name == "Test Space" })
        #expect(space.tabs.count == 5)
        #expect(space.folders.count == 4)
        let parent = try #require(space.folders.first { $0.name == "Projects" })
        let child = try #require(space.folders.first { $0.name == "Research" })
        let grandchild = try #require(space.folders.first { $0.name == "References" })
        let empty = try #require(space.folders.first { $0.name == "Empty Folder" })
        #expect(child.parentFolder?.id == parent.id)
        #expect(grandchild.parentFolder?.id == child.id)
        #expect(empty.parentFolder?.id == parent.id)
        #expect(empty.tabs.isEmpty)
        #expect(parent.tabs.map(\.title) == ["Direct Tab"])
        #expect(child.tabs.map(\.title) == ["Nested Tab"])
        #expect(grandchild.tabs.map(\.title) == ["Deep Tab"])
        #expect(parent.subfolders.count == 2)
        #expect(space.tabs.allSatisfy { !$0.isWebViewReady })
        for folder in space.folders {
            for tab in folder.tabs {
                #expect(tab.folder?.id == folder.id)
                #expect(tab.container.id == space.id)
                #expect(tab.type == .pinned)
            }
        }
        #expect(Folder.sidebarOutline(in: space.folders).map(\.depth) == [0, 1, 2, 1])
        parent.isOpened = false
        #expect(Folder.sidebarOutline(in: space.folders).map(\.id) == [parent.id])
    }

    @Test func displaysPinnedTabsInsideFolders() throws {
        let manager = try Self.makeManager()
        let space = try #require(manager.activeContainer)
        let folder = manager.createFolder(name: "Projects", in: space)
        let tab = try manager.addTab(
            title: "Pinned Tab",
            url: #require(URL(string: "about:blank")),
            container: space,
            isPrivate: false,
            activate: false
        )
        manager.togglePinTab(tab)
        manager.moveTab(tab, toFolder: folder)
        #expect(folder.sidebarTabs(in: space.tabs).map(\.id) == [tab.id])
        #expect(tab.type == .pinned)
        #expect(folder.tabs.map(\.id) == [tab.id])
    }

    @Test func rejectsCyclesAndPromotesContentsWhenDeleting() throws {
        let manager = try Self.makeManager()
        let space = try #require(manager.activeContainer)
        let parent = manager.createFolder(name: "Parent", in: space)
        let child = manager.createFolder(name: "Child", in: space, parent: parent)
        let grandchild = manager.createFolder(name: "Grandchild", in: space, parent: child)
        manager.moveFolder(parent, toParent: grandchild)
        #expect(parent.parentFolder == nil)
        manager.moveFolder(child, toParent: child)
        #expect(child.parentFolder?.id == parent.id)
        let tab = try manager.addTab(
            url: #require(URL(string: "about:blank")),
            container: space,
            isPrivate: false,
            activate: false
        )
        manager.moveTab(tab, toFolder: child)
        manager.deleteFolder(child)
        #expect(grandchild.parentFolder?.id == parent.id)
        #expect(tab.folder?.id == parent.id)
        manager.moveFolder(grandchild, toParent: nil)
        #expect(grandchild.parentFolder == nil)
        manager.moveTab(tab, toFolder: nil)
        #expect(tab.folder == nil)
        let other = manager.createContainer(name: "Other")
        let otherFolder = manager.createFolder(name: "Other Folder", in: other)
        manager.moveFolder(parent, toParent: otherFolder)
        #expect(parent.parentFolder == nil)
        manager.moveTab(tab, toFolder: parent)
        manager.moveTabToContainer(tab, toContainer: other)
        #expect(tab.folder == nil)
        #expect(tab.container.id == other.id)
    }

    @Test func persistsFolderHierarchyAcrossStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("hierarchy.sqlite")
        let configuration = ModelConfiguration(url: url)
        let manager = try Self.makeManager(configuration: configuration)
        try Self.runImport(Self.fixture(), manager: manager)
        try manager.modelContext.save()
        let reopened = try Self.makeManager(configuration: ModelConfiguration(url: url))
        let space = try #require(reopened.modelContext.fetch(FetchDescriptor<TabContainer>())
            .first { $0.name == "Test Space" })
        #expect(space.tabs.count == 5)
        #expect(space.folders.count == 4)
        let deep = try #require(space.tabs.first { $0.title == "Deep Tab" })
        #expect(deep.folder?.name == "References")
        #expect(deep.folder?.parentFolder?.name == "Research")
        #expect(deep.folder?.parentFolder?.parentFolder?.name == "Projects")
        #expect(Folder.sidebarOutline(in: space.folders).map(\.depth) == [0, 1, 2, 1])
    }

    @Test func rendersOptionalFolderSidebarPreview() throws {
        guard let path = ProcessInfo.processInfo.environment["ORA_PREVIEW_DIRECTORY"] else { return }
        let manager = try Self.makeManager()
        try Self.runImport(Self.fixture(), manager: manager)
        let space = try #require(manager.modelContext.fetch(FetchDescriptor<TabContainer>())
            .first { $0.name == "Test Space" })
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let sidebar = NormalTabsList(
                tabs: space.tabs.filter { $0.type == .normal }, folders: space.folders, container: space,
                draggedItem: .constant(nil), onDrag: { NSItemProvider(object: $0.uuidString as NSString) },
                onSelect: { _ in }, onPinToggle: { _ in }, onFavoriteToggle: { _ in }, onClose: { _ in },
                onDuplicate: { _ in }, onMoveToContainer: { _, _ in }, onAddNewTab: {}
            )
            .environmentObject(manager)
            .environmentObject(DialogManager())
            .environment(\.theme, Theme(colorScheme: scheme))
            .environment(\.colorScheme, scheme)
            .modelContainer(manager.modelContainer)
            .padding(16)
            .frame(width: 320, height: 560, alignment: .top)
            .background(scheme == .dark ? Color(white: 0.09) : Color(white: 0.98))
            let host = NSHostingView(rootView: sidebar)
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 560)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(data.count > 1000)
            try data
                .write(to: directory.appendingPathComponent(scheme == .dark ? "sidebar-dark.png" : "sidebar-light.png"))
        }
    }

    @Test func migratesOptionalOriginalSchemaStore() throws {
        guard let path = ProcessInfo.processInfo.environment["ORA_LEGACY_TEST_PATH"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("legacy.sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        let manager = try Self.makeManager(configuration: ModelConfiguration(url: copy))
        let space = try #require(manager.modelContext.fetch(FetchDescriptor<TabContainer>())
            .first { $0.name == "Legacy Space" })
        #expect(space.tabs.count == 1)
        #expect(space.folders.count == 1)
        let folder = try #require(space.folders.first)
        let tab = try #require(space.tabs.first)
        #expect(folder.name == "Legacy Folder")
        #expect(tab.title == "Legacy Tab")
        #expect(folder.parentFolder == nil)
        manager.moveTab(tab, toFolder: folder)
        let child = manager.createFolder(name: "Migrated Child", in: space, parent: folder)
        try manager.modelContext.save()
        let reopened = try Self.makeManager(configuration: ModelConfiguration(url: copy))
        let folders = try reopened.modelContext.fetch(FetchDescriptor<Folder>())
        #expect(folders.first { $0.id == child.id }?.parentFolder?.name == "Legacy Folder")
        #expect(folders.first { $0.id == folder.id }?.tabs.count == 1)
        print("Original-schema migration verified with folder nesting and tab membership")
    }

    @Test func importsOptionalLocalArcFixtureWithoutLosingHierarchy() throws {
        guard let path = ProcessInfo.processInfo.environment["ORA_ARC_TEST_PATH"] else { return }
        let root = try JSONDecoder().decode(Root.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let sourceURLs = Set(root.sidebar.containers.flatMap { $0.items ?? [] }.compactMap { entry -> String? in
            guard case let .object(item) = entry else { return nil }
            return item.data?.tab?.savedURL
        })
        let inspected = inspectItems(root)
        let manager = try Self.makeManager()
        Self.runImport(root, manager: manager)
        let spaces = try manager.modelContext.fetch(FetchDescriptor<TabContainer>()).filter { $0.name != "Default" }
        let favoriteCount = inspected.cleanTabs.filter { inspected.favs.contains($0.parentID) }.count
        let importedURLs = Set(spaces.flatMap(\.tabs).map(\.urlString))
        #expect(sourceURLs.isSubset(of: importedURLs), "Every source tab URL should survive import")
        #expect(spaces.count == inspected.cleanSpaces.count)
        #expect(spaces.reduce(0) { $0 + $1.tabs.count } == inspected.cleanSpaces
            .reduce(0) { $0 + $1.tabs.count } + favoriteCount * spaces.count)
        #expect(spaces.reduce(0) { $0 + $1.folders.count } == inspected.cleanSpaces.reduce(0) { $0 + $1.folders.count })
        let expectedNestedCount = inspected.cleanSpaces.reduce(0) { count, space in
            let ids = Set(space.folders.map(\.id))
            return count + space.folders.filter { ids.contains($0.parentID ?? "") }.count
        }
        #expect(spaces.flatMap(\.folders).filter { $0.parentFolder != nil }.count == expectedNestedCount)
        print(
            "Arc verification: \(spaces.count) spaces, \(spaces.flatMap(\.tabs).count) tabs, \(spaces.flatMap(\.folders).count) folders, \(expectedNestedCount) nested folders"
        )
    }
}
