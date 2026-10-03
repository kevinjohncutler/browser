import Foundation
@testable import Ora
import SwiftData
import Testing

@MainActor
struct ImporterTests {
    @Test func importsArcTabsAndFolders() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: TabContainer.self, Tab.self, Folder.self, History.self, Download.self,
            configurations: config
        )
        let context = ModelContext(container)
        let media = MediaController()
        let historyManager = HistoryManager(modelContainer: container, modelContext: context)
        let downloadManager = DownloadManager(modelContainer: container, modelContext: context)
        let tabManager = TabManager(modelContainer: container, modelContext: context, mediaController: media)

        importArcData(
            tabManager: tabManager,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: false
        )

        let containers = try context.fetch(FetchDescriptor<TabContainer>())
        // TabManager seeds one empty "Default" container before any import happens.
        let importedContainers = containers.filter { $0.name != "Default" }

        #expect(!importedContainers.isEmpty, "expected Arc spaces to be imported as containers")

        let totalTabs = importedContainers.reduce(0) { $0 + $1.tabs.count }
        #expect(totalTabs > 0, "expected imported tabs")

        let totalFolders = importedContainers.reduce(0) { $0 + $1.folders.count }
        #expect(totalFolders > 0, "expected imported folders")

        for space in importedContainers {
            for folder in space.folders {
                #expect(!folder.tabs.isEmpty, "folder '\(folder.name)' should contain at least one tab")
                for tab in folder.tabs {
                    #expect(tab.folder?.id == folder.id, "tab should point back to its folder")
                    #expect(tab.container.id == space.id, "foldered tab should share its space's container")
                }
            }
        }
    }
}
