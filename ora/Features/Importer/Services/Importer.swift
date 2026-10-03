import Darwin
import os.log
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.orabrowser.ora", category: "Importer")

struct Root: Decodable {
    let sidebar: Sidebar
}

struct Sidebar: Decodable {
    let containers: [Container]
}

struct Container: Decodable {
    let global: Global?
    let spaces: [SpaceItem]?
    let items: [Item]?
    let topAppsContainerIDs: [TopAppsContainerID]?

    enum CodingKeys: String, CodingKey {
        case global
        case spaces
        case items
        case topAppsContainerIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        global = try container.decodeIfPresent(Global.self, forKey: .global)
        spaces = try container.decodeIfPresent([SpaceItem].self, forKey: .spaces)
        items = try container.decodeIfPresent([Item].self, forKey: .items)
        topAppsContainerIDs = try container.decodeIfPresent([TopAppsContainerID].self, forKey: .topAppsContainerIDs)
    }
}

struct Global: Decodable {}

enum SpaceItem: Decodable {
    case id(String)
    case custom(CustomInfo)

    struct CustomInfo: Decodable {
        let customInfo: IconWrapper
        let title: String?
        let id: String
        let containerIDs: [String]
    }

    struct IconWrapper: Decodable {
        let iconType: IconType
    }

    struct IconType: Decodable {
        // swiftlint:disable:next identifier_name
        let emoji_v2: String?
        let emoji: Int?
        let icon: String?

        var displayEmoji: String? {
            if let value = emoji_v2, !value.isEmpty {
                return value
            }
            if let emoji, let scalar = UnicodeScalar(emoji) {
                return String(scalar)
            }
            return ["star": "⭐️", "flash": "⚡️", "planet": "🪐"][icon ?? ""]
        }
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let id = try? singleValue.decode(String.self)
        {
            self = .id(id)
        } else {
            self = try .custom(CustomInfo(from: decoder))
        }
    }
}

enum Item: Decodable {
    case id(String)
    case object(ItemObject)

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let id = try? singleValue.decode(String.self)
        {
            self = .id(id)
        } else {
            self = try .object(ItemObject(from: decoder))
        }
    }
}

struct ItemObject: Decodable {
    let id: String
    let originatingDevice: String?
    let createdAt: Double?
    let title: String?
    let data: ItemData?
    let parentID: String?
    let isUnread: Bool
    let childrenIds: [String]
}

struct ItemData: Decodable {
    let tab: TabData?
    let easel: EaselData?
    let itemContainer: ItemContainerData?
}

struct TabData: Decodable {
    let savedURL: String?
    let savedTitle: String?
    let savedMuteStatus: String?
    let activeTabBeforeCreationID: String?
    let timeLastActiveAt: Double?
}

struct EaselData: Decodable {
    let creatorID: String?
    let easelID: String?
    let shareStatus: String?
    let title: String?
    let timeLastActiveAt: Double?
}

struct ItemContainerData: Decodable {
    let containerType: ContainerType?

    struct ContainerType: Decodable {
        let spaceItems: [String: String]?
        let topApps: [String: TopApp]?

        struct TopApp: Decodable {
            /// Arc puts heterogeneous JSON here (bool in some exports, object in others);
            /// decode permissively since we never read this value.
            let `default`: AnyCodable?
        }
    }
}

/// Decodes any JSON value without failing. Used for fields we don't consume but whose
/// shape varies across Arc versions/exports (e.g. a bool where an object might be expected).
enum AnyCodable: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyCodable])
    case array([AnyCodable])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AnyCodable].self) {
            self = .dictionary(value)
        } else if let value = try? container.decode([AnyCodable].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}

enum TopAppsContainerID: Decodable {
    case id(String)
    case object(TopAppsObject)

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let id = try? singleValue.decode(String.self)
        {
            self = .id(id)
        } else {
            self = try .object(TopAppsObject(from: decoder))
        }
    }
}

struct TopAppsObject: Decodable {
    let id: String?
    // Add more fields as needed based on actual JSON structure
}

func getRoot(from sourceURL: URL? = nil) -> Root? {
    let url = sourceURL ??
        URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Arc/StorableSidebar.json")
            .expandingTildeInPath
        )

    do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Root.self, from: data)
    } catch {
        logger.error("Decoding failed: \(error.localizedDescription)")
        return nil
    }
}

/// The system picker grants the sandbox access to the selected Arc export.
func arcImportDirectory() -> URL {
    // FileManager's home URL points into the app container when sandboxed.
    let home = getpwuid(getuid()).flatMap { entry in
        entry.pointee.pw_dir.map { String(cString: $0) }
    } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Arc")
}

@MainActor
func requestArcImport(
    tabManager: TabManager,
    historyManager: HistoryManager,
    downloadManager: DownloadManager,
    isPrivate: Bool,
    iconsOnly: Bool = false
) {
    let panel = NSOpenPanel()
    panel.title = "Import Arc Tabs and Folders"
    panel.message = "Select Arc's StorableSidebar.json file."
    panel.prompt = iconsOnly ? "Update Icons" : "Import"
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = arcImportDirectory()
    panel.begin { response in
        guard response == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let root = getRoot(from: url) else {
            let alert = NSAlert()
            alert.messageText = "Unable to Import Arc Data"
            alert.informativeText = "Choose a valid StorableSidebar.json file from Arc."
            alert.runModal()
            return
        }
        if iconsOnly {
            updateImportedSpaceIcons(from: root, tabManager: tabManager)
            return
        }
        importArcData(
            tabManager: tabManager,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: isPrivate,
            root: root,
            activateFirstTab: true
        )
    }
}

@MainActor
func updateImportedSpaceIcons(from root: Root, tabManager: TabManager) {
    let spaces = inspectItems(root).cleanSpaces
    let containers = (try? tabManager.modelContext.fetch(FetchDescriptor<TabContainer>())) ?? []
    for container in containers where container.emoji == "💀" {
        if let source = spaces.first(where: { $0.title == container.name }), let emoji = source.emoji {
            container.emoji = emoji
        }
    }
    try? tabManager.modelContext.save()
}

struct CleanTab {
    var title: String
    var urlString: String
    var id: String
    var parentID: String
}

/// A folder retains its source identity so parent links can be reconstructed after insertion.
struct CleanFolder {
    var id: String
    var parentID: String?
    var title: String
}

struct CleanSpace {
    var emoji: String?
    var title: String?
    var containerIDs: Set<String> = []
    var folders: [CleanFolder] = []
    var tabs: [CleanTab] = []
}

struct Result {
    var cleanSpaces: [CleanSpace]
    var cleanTabs: [CleanTab]
    var favs: Set<String> = []
}

private func isUserFolder(_ item: ItemObject) -> Bool {
    item.title != nil
        && item.data?.tab == nil
        && item.data?.easel == nil
        && item.data?.itemContainer == nil
}

func inspectItems(_ root: Root) -> Result {
    var spaces: [CleanSpace] = []
    var items: [ItemObject] = []
    var itemsByID: [String: ItemObject] = [:]
    var favorites: Set<String> = []
    for container in root.sidebar.containers {
        for entry in container.spaces ?? [] {
            if case let .custom(space) = entry {
                spaces.append(CleanSpace(
                    emoji: space.customInfo.iconType.displayEmoji,
                    title: space.title,
                    containerIDs: Set(space.containerIDs + [space.id])
                ))
            }
        }
        for entry in container.items ?? [] {
            if case let .object(item) = entry {
                if itemsByID[item.id] == nil {
                    items.append(item)
                }
                itemsByID[item.id] = item
            }
        }
        for entry in container.topAppsContainerIDs ?? [] {
            switch entry {
            case let .id(id): favorites.insert(id)
            case let .object(object):
                if let id = object.id {
                    favorites.insert(id)
                }
            }
        }
    }

    /// Traverse parent links with a visited set, so malformed cycles cannot hang an import.
    func owningSpace(startingAt id: String) -> Int? {
        var cursor: String? = id
        var visited: Set<String> = []
        while let current = cursor, visited.insert(current).inserted {
            if let index = spaces.firstIndex(where: { $0.containerIDs.contains(current) }) {
                return index
            }
            cursor = itemsByID[current]?.parentID
        }
        return nil
    }

    let tabs = items.compactMap { item -> CleanTab? in
        guard let tab = item.data?.tab, let url = tab.savedURL, let parent = item.parentID else { return nil }
        return CleanTab(
            title: tab.savedTitle ?? item.title ?? "New Tab",
            urlString: url,
            id: item.id,
            parentID: parent
        )
    }
    for item in items where isUserFolder(item) {
        guard let index = owningSpace(startingAt: item.id) else { continue }
        spaces[index].folders.append(CleanFolder(
            id: item.id,
            parentID: item.parentID,
            title: item.title ?? "Folder"
        ))
    }
    for tab in tabs {
        guard let index = owningSpace(startingAt: tab.parentID) else { continue }
        spaces[index].tabs.append(tab)
    }
    // Arc's childrenIds preserve folder order, including empty folders.
    for index in spaces.indices {
        let foldersByID = Dictionary(uniqueKeysWithValues: spaces[index].folders.map { ($0.id, $0) })
        var ordered: [CleanFolder] = []
        var visited: Set<String> = []
        func append(_ id: String) {
            guard let folder = foldersByID[id], visited.insert(id).inserted else { return }
            ordered.append(folder)
            for child in itemsByID[id]?.childrenIds ?? [] {
                append(child)
            }
        }
        for id in spaces[index].containerIDs.sorted() {
            for child in itemsByID[id]?.childrenIds ?? [] {
                append(child)
            }
        }
        for folder in spaces[index].folders {
            append(folder.id)
        }
        spaces[index].folders = ordered
    }
    return Result(cleanSpaces: spaces, cleanTabs: tabs, favs: favorites)
}

/// Imports Arc's spaces, tabs, and folders into Ora. Runs on the main actor since it drives
/// TabManager, which is main-actor isolated.
@MainActor
func importArcData(
    tabManager: TabManager,
    historyManager: HistoryManager,
    downloadManager: DownloadManager,
    isPrivate: Bool,
    root sourceRoot: Root? = nil,
    activateFirstTab: Bool = false
) {
    guard let root = sourceRoot ?? getRoot() else {
        logger.error("Arc import: no root found (StorableSidebar.json missing or undecodable)")
        return
    }
    let result = inspectItems(root)

    func addTab(_ tab: CleanTab, to container: TabContainer) -> Tab? {
        guard let url = URL(string: tab.urlString) else { return nil }
        return tabManager.addTab(
            title: tab.title,
            url: url,
            container: container,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: isPrivate,
            activate: false
        )
    }

    var newContainers: [TabContainer] = []

    for space in result.cleanSpaces {
        let container = tabManager.createContainer(name: space.title ?? "Unknown", emoji: space.emoji ?? "◦")
        newContainers.append(container)

        var foldersByID: [String: Folder] = [:]
        for sourceFolder in space.folders {
            let folder = tabManager.createFolder(name: sourceFolder.title, in: container)
            foldersByID[sourceFolder.id] = folder
        }
        for sourceFolder in space.folders {
            if let folder = foldersByID[sourceFolder.id],
               let parentID = sourceFolder.parentID, let parent = foldersByID[parentID]
            {
                tabManager.moveFolder(folder, toParent: parent)
            }
        }
        for sourceTab in space.tabs {
            guard let tab = addTab(sourceTab, to: container) else { continue }
            // Arc folders are persistent, just like pinned tabs, even when their pages close.
            tabManager.togglePinTab(tab)
            if let folder = foldersByID[sourceTab.parentID] {
                tabManager.moveTab(tab, toFolder: folder)
            }
        }
    }

    var seenContainers: Set<UUID> = []
    for container in newContainers {
        if seenContainers.contains(container.id) {
            continue
        }
        seenContainers.insert(container.id)
        for tab in result.cleanTabs where result.favs.contains(tab.parentID) {
            if let newTab = addTab(tab, to: container) {
                tabManager.toggleFavTab(newTab)
            }
        }
    }
    if activateFirstTab,
       let tab = newContainers.first(where: { !$0.tabs.isEmpty })?.tabs.sorted(by: { $0.order > $1.order }).first
    {
        tabManager.activateTab(tab)
    }
}
