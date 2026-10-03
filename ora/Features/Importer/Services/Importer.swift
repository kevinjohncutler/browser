import os.log
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

func getRoot() -> Root? {
    let url = URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Arc/StorableSidebar.json")
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

struct CleanTab {
    var title: String
    var urlString: String
    var id: String
    var parentID: String
}

/// A user-created Arc folder (a titled, non-tab item with children). Arc allows folders to
/// nest inside folders; Ora's folder model is flat, so nested folders are flattened to a
/// single level under their owning space rather than dropping tabs or folder names.
struct CleanFolder {
    var title: String
    var tabs: [CleanTab] = []
}

struct CleanSpace {
    var emoji: String?
    var title: String?
    var containerIDs: Set<String> = []
    var container: TabContainer?
    var folders: [CleanFolder] = []
}

struct Result {
    var cleanSpaces: [CleanSpace]
    var cleanTabs: [CleanTab]
    var favs: Set<String> = []
}

/// An item is a user folder if it has a title and children but is neither a tab, an easel,
/// nor one of Arc's own system containers (pinned/unpinned/topApps lists), which are never titled.
private func isUserFolder(_ item: ItemObject) -> Bool {
    item.title != nil
        && !item.childrenIds.isEmpty
        && item.data?.tab == nil
        && item.data?.easel == nil
        && item.data?.itemContainer == nil
}

func inspectItems(_ root: Root) -> Result {
    var cleanSpaces: [CleanSpace] = []
    var cleanTabs: [CleanTab] = []
    var topIds: [String] = []
    var itemsByID: [String: ItemObject] = [:]

    for container in root.sidebar.containers {
        if let spaces = container.spaces {
            for item in spaces {
                switch item {
                case let .custom(customInfo):
                    var cleanSpace = CleanSpace(
                        emoji: customInfo.customInfo.iconType.emoji_v2,
                        title: customInfo.title,
                        containerIDs: []
                    )
                    for cid in customInfo.containerIDs {
                        cleanSpace.containerIDs
                            .insert(cid)
                    }
                    cleanSpace.containerIDs
                        .insert(customInfo.id)

                    cleanSpaces.append(cleanSpace)
                case let .id(id):
                    logger.debug("Space ID: \(id)")
                }
            }
        } else {
            logger.debug("No spaces")
        }

        // Inspect items with detailed output
        if let items = container.items {
            var idCount = 0
            var objectCount = 0
            for (itemIndex, item) in items.enumerated() {
                logger.debug("Item \(itemIndex + 1):")
                switch item {
                case let .id(id):
                    idCount += 1
                    logger.debug("ID: \(id)")
                case let .object(itemObject):
                    objectCount += 1
                    itemsByID[itemObject.id] = itemObject

                    if let data = itemObject.data {
                        if let tab = data.tab {
                            if let parentID = itemObject.parentID, let urlString = tab.savedURL {
                                cleanTabs.append(
                                    CleanTab(
                                        title: tab.savedTitle ?? "New Tab",
                                        urlString: urlString,
                                        id: itemObject.id,
                                        parentID: parentID
                                    )
                                )
                            }
                        }
                    }
                }
            }
            logger.debug("    Total: \(idCount) IDs, \(objectCount) objects")
        }

        // Inspect topAppsContainerIDs
        if let topApps = container.topAppsContainerIDs {
            for topApp in topApps {
                switch topApp {
                case let .id(id):
                    topIds.append(id)
                case let .object(obj):
                    logger.debug("TopApp Object: id=\(obj.id ?? "n/a")")
                }
            }
        }
    }

    /// Walks parentID links up from `id` until it reaches one of the space's own
    /// top-level container ids, identifying which space (possibly nested folders
    /// deep) an item ultimately belongs to.
    func owningSpaceIndex(startingAt id: String) -> Int? {
        var currentID: String? = id
        var hops = 0
        while let cid = currentID, hops < 50 {
            if let index = cleanSpaces.firstIndex(where: { $0.containerIDs.contains(cid) }) {
                return index
            }
            currentID = itemsByID[cid]?.parentID
            hops += 1
        }
        return nil
    }

    let cleanTabsByID = Dictionary(uniqueKeysWithValues: cleanTabs.map { ($0.id, $0) })

    for item in itemsByID.values where isUserFolder(item) {
        guard let spaceIndex = owningSpaceIndex(startingAt: item.id) else { continue }
        let childTabs = item.childrenIds.compactMap { cleanTabsByID[$0] }
        cleanSpaces[spaceIndex].folders.append(CleanFolder(title: item.title ?? "Folder", tabs: childTabs))
    }

    var result = Result(
        cleanSpaces: cleanSpaces,
        cleanTabs: cleanTabs
    )
    for tid in topIds {
        result.favs.insert(tid)
    }

    return result
}

/// Imports Arc's spaces, tabs, and folders into Ora. Runs on the main actor since it drives
/// TabManager, which is main-actor isolated.
@MainActor
func importArcData(
    tabManager: TabManager,
    historyManager: HistoryManager,
    downloadManager: DownloadManager,
    isPrivate: Bool
) {
    guard let root = getRoot() else {
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
            isPrivate: isPrivate
        )
    }

    var newContainers: [TabContainer] = []

    for space in result.cleanSpaces {
        let container = tabManager.createContainer(name: space.title ?? "Unknown", emoji: space.emoji ?? "💀")
        newContainers.append(container)

        let folderedTabIDs = Set(space.folders.flatMap { $0.tabs.map(\.id) })
        for tab in result.cleanTabs
            where space.containerIDs.contains(tab.parentID) && !folderedTabIDs.contains(tab.id)
        {
            if let newTab = addTab(tab, to: container) {
                tabManager.togglePinTab(newTab)
            }
        }

        for folder in space.folders {
            let newFolder = tabManager.createFolder(name: folder.title, in: container)
            for tab in folder.tabs {
                if let newTab = addTab(tab, to: container) {
                    tabManager.moveTab(newTab, toFolder: newFolder)
                }
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
}
