import Combine
import Darwin
import Foundation

struct PreferenceHistory: Codable {
    var label: String
    var before: [String: PreferenceValue]
}

struct PreferenceDocument: Codable {
    var version = 1
    var revision = 0
    var values: [String: PreferenceValue] = [:]
    var history: [PreferenceHistory] = []
}

struct PreferenceSpace: Codable, Equatable {
    var id: String
    var name: String
    var emoji: String
}

extension Notification.Name {
    static let oraPreferencesChanged = Notification.Name("ora.preferences.changed")
}

/// The native editor and external MCP process share this locked, versioned store.
@MainActor
final class CustomizationStore: ObservableObject {
    static let shared: CustomizationStore = {
        let headless = ProcessInfo.processInfo.environment["ORA_HEADLESS_TESTING"] == "1"
        return CustomizationStore(
            defaults: headless ?
                UserDefaults(suiteName: "Ora.HeadlessCustomization.\(ProcessInfo.processInfo.processIdentifier)")! :
                .standard,
            integrateApp: !headless
        )
    }()

    @Published private(set) var values: [String: PreferenceValue] = [:]
    @Published private(set) var revision = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var spaces: [PreferenceSpace] = []
    let catalog: PreferenceCatalog
    let directory: URL
    let defaults: UserDefaults
    private let integrateApp: Bool
    private var baseline: [String: PreferenceValue] = [:]
    private var timer: Timer?
    private var spaceReader: (() -> [PreferenceSpace])?
    private var spaceWriter: ((String, String, String) throws -> Void)?

    init(directory: URL? = nil, defaults: UserDefaults = .standard, watch: Bool = true, integrateApp: Bool = true) {
        self.defaults = defaults
        self.integrateApp = integrateApp
        let headless = ProcessInfo.processInfo.environment["ORA_HEADLESS_TESTING"] == "1"
        self.directory = directory ?? (headless ? FileManager.default.temporaryDirectory
            .appendingPathComponent("OraHeadlessCustomization-\(ProcessInfo.processInfo.processIdentifier)") :
            URL.applicationSupportDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
                ? "OraDev/Customization" : "Ora/Customization"))
        catalog = (try? .bundled()) ?? PreferenceCatalog(version: 1, settings: [])
        synchronize()
        if watch {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.synchronize() }
            }
        }
    }

    deinit { timer?.invalidate() }
    var fileURL: URL {
        directory.appendingPathComponent("preferences.json")
    }

    func registerSpaces(
        read: @escaping () -> [PreferenceSpace],
        write: @escaping (String, String, String) throws -> Void
    ) {
        spaceReader = read
        spaceWriter = write
        synchronize()
    }

    var definitions: [PreferenceDefinition] {
        catalog.settings.filter { $0.scope == "global" } + spaces.flatMap { space in
            catalog.settings.filter { $0.scope == "space" }.map { $0.instantiated(spaceID: space.id) }
        }
    }

    private func allDefinitions(_ document: PreferenceDocument) -> [PreferenceDefinition] {
        var ids = Set(spaces.map(\.id))
        for key in document.values.keys where key.hasPrefix("space.") {
            let parts = key.split(separator: ".")
            if parts.count > 2 {
                ids.insert(String(parts[1]))
            }
        }
        return catalog.settings.filter { $0.scope == "global" } + ids.sorted().flatMap { id in
            catalog.settings.filter { $0.scope == "space" }.map { $0.instantiated(spaceID: id) }
        }
    }

    private func effective(_ document: PreferenceDocument) -> [String: PreferenceValue] {
        var result = Dictionary(uniqueKeysWithValues: allDefinitions(document).map { ($0.id, $0.defaultValue) })
        result.merge(document.values) { _, saved in saved }
        return result
    }

    func synchronize() {
        guard !catalog.settings.isEmpty else { errorMessage = "Settings catalog is unavailable."
            return
        }
        let discovered = spaceReader?() ?? spaces
        if discovered != spaces {
            spaces = discovered
        }
        do {
            let document = try locked {
                var document = try read()
                let native = try nativeSnapshot(allDefinitions(document))
                let delta = native.filter { baseline[$0.key] != nil && baseline[$0.key] != $0.value }
                if !delta.isEmpty {
                    record(delta, in: &document, label: "Native settings")
                }
                var seeded = false
                for (key, value) in native where document.values[key] == nil {
                    document.values[key] = value
                    seeded = true
                }
                if seeded || !delta.isEmpty || !FileManager.default
                    .fileExists(atPath: fileURL.path)
                {
                    try write(document)
                }
                return document
            }
            try apply(document)
            baseline = try nativeSnapshot(allDefinitions(document))
            try JSONEncoder().encode(spaces).write(
                to: directory.appendingPathComponent("spaces.json"),
                options: .atomic
            )
            let status: [String: PreferenceValue] = [
                "appliedRevision": .number(Double(revision)),
                "updatedAt": .string(ISO8601DateFormatter().string(from: Date())),
                "running": .bool(true)
            ]
            try JSONEncoder().encode(status).write(
                to: directory.appendingPathComponent("app-status.json"),
                options: .atomic
            )
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func update(
        _ patch: [String: PreferenceValue],
        expectedRevision: Int? = nil,
        preview: Bool = false
    ) throws -> [String: PreferenceValue] {
        let patch = try catalog.canonicalPatch(patch)
        if !preview {
            synchronize()
            if let errorMessage {
                throw PreferenceError(errorMessage)
            }
        }
        let document = try locked {
            var document = try read()
            if let expectedRevision,
               expectedRevision != document
               .revision
            {
                throw PreferenceError("Settings changed. Read them again and retry.")
            }
            if !preview {
                record(patch, in: &document, label: "Settings editor")
                try write(document)
            }
            return document
        }
        if !preview {
            try apply(document)
            baseline = try nativeSnapshot(allDefinitions(document))
        }
        return patch
    }

    func reset(_ keys: [String]) throws {
        try update(Dictionary(
            keys.map { try ($0, catalog.definition($0).defaultValue) },
            uniquingKeysWith: { _, value in value }
        ))
    }

    func undo() throws {
        synchronize()
        if let errorMessage {
            throw PreferenceError(errorMessage)
        }
        let document = try locked {
            var document = try read()
            guard let entry = document.history.popLast() else { throw PreferenceError("No settings changes to undo.") }
            try catalog.validate(entry.before)
            document.values.merge(entry.before) { _, previous in previous }
            document.revision += 1
            try write(document)
            return document
        }
        try apply(document)
        baseline = try nativeSnapshot(allDefinitions(document))
    }

    func exportProfile(name: String, keys: [String]? = nil) throws -> Data {
        let current = values.filter { keys?.contains($0.key) ?? true }
        return try JSONEncoder().encode(PreferenceValue.object([
            "version": .number(1),
            "name": .string(name),
            "values": .object(current)
        ]))
    }

    func importProfile(_ data: Data) throws {
        let profile = try JSONDecoder().decode(PreferenceValue.self, from: data).dictionary
        guard profile?["version"] == .number(1),
              let patch = profile?["values"]?.dictionary else { throw PreferenceError("Invalid settings profile.") }
        try update(patch)
    }

    private func record(_ patch: [String: PreferenceValue], in document: inout PreferenceDocument, label: String) {
        let current = effective(document)
        let changed = patch.filter { current[$0.key] != $0.value }
        guard !changed.isEmpty else { return }
        document.history.append(PreferenceHistory(label: label, before: changed.mapValues { _ in .null }))
        document.history[document.history.count - 1].before = Dictionary(uniqueKeysWithValues: changed.keys.map { (
            $0,
            current[$0] ?? .null
        ) })
        document.history = Array(document.history.suffix(50))
        document.values.merge(changed) { _, new in new }
        document.revision += 1
    }

    private func read() throws -> PreferenceDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return PreferenceDocument() }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 4_000_000 else { throw PreferenceError("Settings file is too large.") }
        var document = try JSONDecoder().decode(PreferenceDocument.self, from: data)
        guard document.version == 1, document.revision >= 0,
              document.history.count <= 50 else { throw PreferenceError("Unsupported settings document.") }
        document.values = try catalog.canonicalPatch(document.values)
        for index in document.history
            .indices
        {
            document.history[index].before = try catalog.canonicalPatch(document.history[index].before)
        }
        return document
    }

    private func write(_ document: PreferenceDocument) throws {
        let data = try JSONEncoder().encode(document)
        guard data.count <= 4_000_000 else { throw PreferenceError("Settings and undo history exceed the size limit.") }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(
            directory.appendingPathComponent("preferences.lock").path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return try body()
    }

    private func nativeSnapshot(_ definitions: [PreferenceDefinition]) throws -> [String: PreferenceValue] {
        try Dictionary(uniqueKeysWithValues: definitions.compactMap { entry -> (String, PreferenceValue)? in
            if entry.source == "model" {
                let id = String(entry.id.split(separator: ".")[1])
                guard let space = spaces.first(where: { $0.id == id }) else { return nil }
                return (entry.id, .string(entry.id.hasSuffix(".name") ? space.name : space.emoji))
            }
            var value: PreferenceValue?
            if let key = entry.defaultsKey, let stored = defaults.object(forKey: key) {
                value = (stored as? Data).flatMap { try? JSONDecoder().decode(PreferenceValue.self, from: $0) }
                    ?? (try? PreferenceValue.from(stored))
            }
            if entry.id == "privacy.filterLists", let items = value?.items {
                value = .array(items.filter { $0.dictionary?["sourceKind"] == .string("custom") })
            }
            for path in entry.path ?? [] {
                value = value?.dictionary?[path]
            }
            if value == nil, entry.id.hasPrefix("space."), entry.id.contains(".privacy.") {
                let legacy = [
                    "blockTrackers": "settings.tracking.blockThirdParty",
                    "blockFingerprinting": "settings.tracking.blockFingerprinting",
                    "adBlocking": "settings.tracking.adBlocking",
                    "cookies": "settings.cookies.policy"
                ]
                if let key = legacy[String(entry.id.split(separator: ".").last!)],
                   let stored = defaults.object(forKey: key)
                {
                    value = try? PreferenceValue.from(stored)
                }
            }
            let candidate = value ?? entry.defaultValue
            try PreferenceCatalog.validate(candidate, schema: entry.schema, label: entry.id)
            return (entry.id, candidate)
        })
    }

    private func apply(_ document: PreferenceDocument) throws {
        let next = effective(document)
        let changed = Set(next.keys.filter { next[$0] != values[$0] })
        var grouped: [String: PreferenceValue] = [:]
        for entry in allDefinitions(document) where entry.source != "model" {
            guard let key = entry.defaultsKey, var value = next[entry.id] else { continue }
            if entry.id == "privacy.filterLists" {
                let custom = try JSONDecoder().decode([FilterListRecord].self, from: JSONEncoder().encode(value))
                let old = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(
                    [FilterListRecord].self,
                    from: $0
                ) } ?? []
                let records = FilterListCatalogService.shared
                    .normalizedRecords(from: old.filter { $0.sourceKind == .builtin } + custom)
                value = try JSONDecoder().decode(PreferenceValue.self, from: JSONEncoder().encode(records))
            }
            if let path = entry.path {
                let initial = grouped[key] ?? defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(
                    PreferenceValue.self,
                    from: $0
                ) } ?? .object([:])
                grouped[key] = Self.setting(value, path: path, in: initial)
            } else {
                grouped[key] = value
            }
        }
        for (key, value) in grouped {
            let definition = allDefinitions(document).first { $0.defaultsKey == key }
            if definition?.storage == "json" {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let encoded = try encoder.encode(value)
                let current = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(
                    PreferenceValue.self,
                    from: $0
                ) }
                if current != value {
                    defaults.set(encoded, forKey: key)
                }
            } else if value == .null {
                if defaults.object(forKey: key) != nil {
                    defaults.removeObject(forKey: key)
                }
            } else if (try? defaults.object(forKey: key).map(PreferenceValue.from)) != value {
                defaults.set(value.foundation, forKey: key)
            }
        }
        for space in spaces {
            let name = next["space.\(space.id).name"]?.text ?? space.name
            let emoji = next["space.\(space.id).emoji"]?.text ?? space.emoji
            if name != space.name || emoji != space.emoji {
                try spaceWriter?(space.id, name, emoji)
            }
        }
        if let discovered = spaceReader?(), discovered != spaces {
            spaces = discovered
        }
        if values != next {
            values = next
        }
        if revision != document.revision {
            revision = document.revision
        }
        if integrateApp, !changed.isEmpty {
            NativePreferenceAdapter.apply(changed, defaults: defaults)
        }
        if integrateApp, !changed.isEmpty {
            NotificationCenter.default.post(name: .oraPreferencesChanged, object: self)
        }
    }

    private static func setting(_ value: PreferenceValue, path: [String], in root: PreferenceValue) -> PreferenceValue {
        guard let first = path.first else { return value }
        var object = root.dictionary ?? [:]
        object[first] = setting(value, path: Array(path.dropFirst()), in: object[first] ?? .object([:]))
        return .object(object)
    }
}
