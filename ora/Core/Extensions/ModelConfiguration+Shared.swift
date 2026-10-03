import Foundation
import SwiftData

extension ModelConfiguration {
    /// Shared model configuration for the main Ora database
    static func oraDatabase(isPrivate: Bool = false) -> ModelConfiguration {
        if isPrivate {
            return ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            return ModelConfiguration(
                "OraData",
                schema: Schema([TabContainer.self, Tab.self, Folder.self, History.self, Download.self]),
                url: URL.applicationSupportDirectory.appending(path:
                    Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "OraDev/OraData.sqlite" : "Ora/OraData.sqlite"
                )
            )
        }
    }

    /// Creates a ModelContainer using the standard Ora database configuration
    static func createOraContainer(isPrivate: Bool = false) throws -> ModelContainer {
        return try ModelContainer(
            for: TabContainer.self, Tab.self, Folder.self, History.self, Download.self,
            configurations: oraDatabase(isPrivate: isPrivate)
        )
    }
}
