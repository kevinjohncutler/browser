import AppKit
import Foundation
@testable import Ora
import SwiftUI
import Testing

@MainActor
struct CustomizationTests {
    private func makeStore(watch: Bool = false) throws -> CustomizationStore {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OraPreferences-\(id)/Customization")
        let defaults = try #require(UserDefaults(suiteName: "Ora.PreferencesTest.\(id)"))
        return CustomizationStore(directory: directory, defaults: defaults, watch: watch, integrateApp: false)
    }

    @Test func validatesEveryDefaultAndPreservesInvalidBatches() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        #expect(store.catalog.settings.count == 59)
        for entry in store.catalog.settings {
            try store.catalog
                .validate([entry.id.replacingOccurrences(of: "{spaceId}", with: UUID().uuidString): entry.defaultValue])
        }
        let original = try Data(contentsOf: store.fileURL)
        #expect(throws: PreferenceError.self) {
            try store.update(["theme.rowHeight": .number(100), "toolbar.hidden": .bool(true)])
        }
        #expect(try Data(contentsOf: store.fileURL) == original)
        #expect(throws: PreferenceError.self) { try store.update(["theme.rowHeight": .bool(true)]) }
        #expect(throws: PreferenceError.self) { try store.update(["unknown": .string("no")]) }
        #expect(throws: PreferenceError.self) { try store.update(["shortcuts.overrides": .object(["tabs.new": .object([
            "characterString": .string("ab"),
            "modifiers": .number(16)
        ])])]) }
    }

    @Test func persistsNativeChangesAndUndoAcrossRestarts() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        try store.update(["theme.rowHeight": .number(48), "tabs.maxRecent": .number(8)])
        let settings = SettingsStore(defaults: store.defaults)
        #expect(!settings.confirmBeforeQuit)
        #expect(settings.maxRecentTabs == 8)
        settings.maxRecentTabs = 3
        // An immediate editor change must preserve the native edit before the poll fires.
        try store.update(["theme.fontSize": .number(16)])
        #expect(store.values["tabs.maxRecent"] == .number(3))
        let reopened = CustomizationStore(
            directory: store.directory,
            defaults: store.defaults,
            watch: false,
            integrateApp: false
        )
        try reopened.undo()
        #expect(reopened.values["theme.fontSize"] == .number(13))
        try reopened.undo()
        #expect(reopened.values["tabs.maxRecent"] == .number(8))
        settings.reloadPreferences(from: store.defaults)
        #expect(settings.maxRecentTabs == 8)
        let revision = reopened.revision
        reopened.synchronize()
        reopened.synchronize()
        #expect(reopened.revision == revision)
    }

    @Test func quitConfirmationDefaultsOffAndCanChangeLive() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let settings = SettingsStore(defaults: store.defaults)
        #expect(!settings.confirmBeforeQuit)
        #expect(store.values["browser.confirmBeforeQuit"] == .bool(false))
        try store.update(["browser.confirmBeforeQuit": .bool(true)])
        settings.reloadPreferences(from: store.defaults)
        #expect(settings.confirmBeforeQuit)
        try store.undo()
        settings.reloadPreferences(from: store.defaults)
        #expect(!settings.confirmBeforeQuit)
    }

    @Test func preservesMalformedStoresAndInvalidNativePreferences() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let original = try Data(contentsOf: store.fileURL)
        store.defaults.set(100, forKey: "customization.theme.rowHeight")
        store.synchronize()
        #expect(store.errorMessage != nil)
        #expect(throws: PreferenceError.self) { try store.update(["theme.fontSize": .number(16)]) }
        #expect(store.defaults.integer(forKey: "customization.theme.rowHeight") == 100)
        #expect(try Data(contentsOf: store.fileURL) == original)
        store.defaults.set(34, forKey: "customization.theme.rowHeight")
        store.synchronize()
        #expect(store.errorMessage == nil)
        try Data("broken".utf8).write(to: store.fileURL)
        store.synchronize()
        #expect(store.errorMessage != nil)
        #expect(throws: (any Error).self) { try store.update(["theme.fontSize": .number(16)]) }
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "broken")
    }

    @Test func appliesStructuredNativeSettingsWithoutDecoderLoss() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let engine = CustomSearchEngine(
            id: "custom-search",
            name: "Example search",
            searchURL: "https://example.com/search?q={query}",
            aliases: ["ex"]
        )
        let engines = try JSONDecoder().decode(PreferenceValue.self, from: JSONEncoder().encode([engine]))
        try store.update([
            "search.customEngines": engines,
            "search.defaultEngine": .string(engine.id),
            "shortcuts.overrides": .object(["tabs.new": .object([
                "characterString": .string("n"),
                "modifiers": .number(18)
            ])]),
            "privacy.sitePermissions": .object(["example.com": .object([
                "host": .string("example.com"),
                "camera": .bool(true),
                "microphone": .bool(false),
                "location": .bool(false),
                "notifications": .bool(false)
            ])]),
            "passwords.enabled": .bool(false)
        ])
        let settings = SettingsStore(defaults: store.defaults)
        #expect(settings.customSearchEngines == [engine])
        #expect(settings.globalDefaultSearchEngine == engine.id)
        #expect(settings.customKeyboardShortcuts["tabs.new"]?.keyEquivalent.character == "n")
        #expect(settings.sitePermissions["example.com"]?.camera == true)
        #expect(!settings.passwordsEnabled)
    }

    @Test func previewsResetsAndImportsProfilesAtomically() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let before = try Data(contentsOf: store.fileURL)
        try store.update(["theme.rowHeight": .number(52)], preview: true)
        #expect(try Data(contentsOf: store.fileURL) == before)
        let initialRevision = store.revision
        try store.update(["theme.rowHeight": .number(52), "toolbar.hidden": .bool(true)])
        #expect(throws: PreferenceError.self) { try store.update(
            ["theme.fontSize": .number(18)],
            expectedRevision: initialRevision
        ) }
        let profile = try store.exportProfile(name: "Roomy", keys: ["theme.rowHeight", "toolbar.hidden"])
        try store.reset(["theme.rowHeight", "toolbar.hidden"])
        #expect(store.values["theme.rowHeight"] == .number(34))
        try store.importProfile(profile)
        #expect(store.values["theme.rowHeight"] == .number(52))
        try store.undo()
        #expect(store.values["toolbar.hidden"] == .bool(false))
    }

    @Test func preservesLegacyPrivacyAndUpdatesSpaceMetadata() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        store.defaults.set(true, forKey: "settings.tracking.blockThirdParty")
        var space = PreferenceSpace(id: UUID().uuidString, name: "Reading", emoji: "📚")
        store.registerSpaces(read: { [space] }, write: { _, name, emoji in space.name = name
            space.emoji = emoji
        })
        let id = space.id
        #expect(store.values["space.\(id).privacy.blockTrackers"] == .bool(true))
        try store.update([
            "space.\(id.lowercased()).name": .string("Research"),
            "space.\(id).privacy.cookies": .string("Block third-party")
        ])
        #expect(space.name == "Research")
        let settings = SettingsStore(defaults: store.defaults)
        #expect(try settings.privacySettings(for: #require(UUID(uuidString: id))).cookiesPolicy == .blockThirdParty)
        let revision = store.revision
        store.synchronize()
        #expect(store.revision == revision)
        try store.undo()
        #expect(space.name == "Reading")
    }

    @Test func preservesBuiltInFiltersWhenResettingCustomLists() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let record = FilterListRecord(
            id: "custom-example",
            name: "Example",
            summary: "Test filter",
            sourceKind: .custom,
            sourceURL: "https://example.com/filter.txt",
            isRecommended: false,
            enabledByDefault: false
        )
        let value = try JSONDecoder().decode(PreferenceValue.self, from: JSONEncoder().encode([record]))
        try store.update(["privacy.filterLists": value])
        let settings = SettingsStore(defaults: store.defaults)
        #expect(settings.adBlockFilterLists.contains { $0.id == record.id })
        #expect(settings.adBlockFilterLists.filter { $0.sourceKind == .builtin }.count == 5)
        try store.reset(["privacy.filterLists"])
        settings.reloadPreferences(from: store.defaults)
        #expect(settings.adBlockFilterLists.filter { $0.sourceKind == .builtin }.count == 5)
        #expect(!settings.adBlockFilterLists.contains { $0.id == record.id })
        let revision = store.revision
        store.synchronize()
        #expect(store.revision == revision)
    }

    @Test func appliesActualMCPWritesToNativePreferencesAndUndo() async throws {
        let server = try #require(ProcessInfo.processInfo.environment["ORA_CSS_SERVER_PATH"])
        let interpreter = try #require(ProcessInfo.processInfo.environment["ORA_PYTHON_PATH"])
        let store = try makeStore(watch: true)
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": "update_settings", "arguments": ["settings": [
                "theme.dark.sidebar": "#333333",
                "theme.rowHeight": 50,
                "tabs.maxRecent": 7
            ]]
        ]]
        let requestFile = store.directory.appendingPathComponent("request.json")
        try (JSONSerialization.data(withJSONObject: request) + Data([10])).write(to: requestFile)
        let input = try FileHandle(forReadingFrom: requestFile)
        defer { try? input.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [
            server,
            "--directory",
            store.directory.deletingLastPathComponent().appendingPathComponent("Boosts").path
        ]
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        for _ in 0 ..< 200 where process.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw PreferenceError("MCP process timed out.")
        }
        #expect(process.terminationStatus == 0)
        let reply = try #require(JSONSerialization
            .jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        #expect((reply["result"] as? [String: Any])?["isError"] as? Bool == false)
        for _ in 0 ..< 20 where store.revision == 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(store.revision == 1)
        #expect(Theme(colorScheme: .dark, preferences: store.values).rowHeight == 50)
        #expect(SettingsStore(defaults: store.defaults).maxRecentTabs == 7)
        try store.undo()
        #expect(store.values["theme.dark.sidebar"] == .string("#262626"))
        #expect(HeadlessTestHost.hasNoAppWindows)
    }

    @Test func rendersCustomizedNativeTabRowsAndSettingsHeadlessly() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let manager = try ImporterTests.makeManager()
        let space = try #require(manager.activeContainer)
        let tab = try manager.addTab(
            url: #require(URL(string: "about:blank")),
            container: space,
            isPrivate: false,
            activate: false
        )
        tab.title = "A customized Ora tab"
        let history = HistoryManager(modelContainer: manager.modelContainer, modelContext: manager.modelContext)
        let downloads = DownloadManager(modelContainer: manager.modelContainer, modelContext: manager.modelContext)
        for scheme in [ColorScheme.light, .dark] {
            for customized in [false, true] {
                try store.reset(store.definitions.filter { $0.id.hasPrefix("theme.") }.map(\.id))
                if customized {
                    try store.update([
                        "theme.rowHeight": .number(54),
                        "theme.fontSize": .number(17),
                        "theme.spacing": .number(12),
                        "theme.cornerRadius": .number(4),
                        "theme.dark.selectedTab": .string("#555555"),
                        "theme.light.selectedTab": .string("#bbbbbb")
                    ])
                }
                let theme = Theme(colorScheme: scheme, preferences: store.values)
                let view = VStack(alignment: .leading, spacing: theme.spacing) {
                    Text(customized ? "Roomy personalization" : "Default personalization").font(theme.textFont)
                    TabItem(
                        tab: tab,
                        isSelected: true,
                        isDragging: false,
                        onTap: {},
                        onPinToggle: {},
                        onFavoriteToggle: {},
                        onClose: {},
                        onDuplicate: {},
                        onMoveToContainer: { _ in },
                        availableContainers: [space]
                    )
                    TabItem(
                        tab: tab,
                        isSelected: false,
                        isDragging: false,
                        onTap: {},
                        onPinToggle: {},
                        onFavoriteToggle: {},
                        onClose: {},
                        onDuplicate: {},
                        onMoveToContainer: { _ in },
                        availableContainers: [space]
                    )
                    Spacer()
                }.padding(16).frame(width: 340, height: 240)
                    .foregroundStyle(theme.foreground).background(theme.solidWindowBackgroundColor)
                    .environment(\.theme, theme).environment(\.colorScheme, scheme)
                    .environmentObject(manager).environmentObject(history).environmentObject(downloads)
                    .environmentObject(PrivacyMode(isPrivate: false))
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 340, height: 240)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let expected = try #require(NSColor(theme.activeTabBackground).usingColorSpace(.sRGB)).redComponent
                let scale = CGFloat(bitmap.pixelsHigh) / 240
                let selectedPixels = (0 ..< bitmap.pixelsHigh).filter { row in
                    guard let color = bitmap.colorAt(x: Int(300 * scale), y: row)?.usingColorSpace(.sRGB)
                    else { return false }
                    return abs(color.redComponent - expected) < 0.015 && abs(color.greenComponent - expected) < 0.015
                }
                #expect(CGFloat(selectedPixels.count) / scale >= theme.rowHeight - 8)
                try save(
                    bitmap,
                    name: "customization-\(scheme == .dark ? "dark" : "light")-\(customized ? "roomy" : "default").png"
                )
            }
        }
        let settings = NSHostingView(rootView: CustomizationSettingsView(store: store)
            .environment(\.theme, Theme(colorScheme: .dark, preferences: store.values)).environment(
                \.colorScheme,
                .dark
            )
            .frame(width: 820, height: 760).background(Color(white: 0.09)))
        settings.frame = NSRect(x: 0, y: 0, width: 820, height: 760)
        settings.appearance = NSAppearance(named: .darkAqua)
        settings.layoutSubtreeIfNeeded()
        let bitmap = try #require(settings.bitmapImageRepForCachingDisplay(in: settings.bounds))
        settings.cacheDisplay(in: settings.bounds, to: bitmap)
        try save(bitmap, name: "customization-settings.png")
        #expect(HeadlessTestHost.hasNoAppWindows)
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["ORA_PREVIEW_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name))
    }
}
