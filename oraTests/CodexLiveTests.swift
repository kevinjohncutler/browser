import AppKit
import Foundation
@testable import Ora
import SwiftUI
import Testing

/// An opt-in account-backed test of the real Codex client, MCP server, and native poll.
@MainActor
struct CodexLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORA_CODEX_PATH"] != nil))
    func appliesAndUndoesCodexChangesInTheNativeRuntime() async throws {
        let codex = try #require(ProcessInfo.processInfo.environment["ORA_CODEX_PATH"])
        let outputPath = try #require(ProcessInfo.processInfo.environment["ORA_CODEX_OUTPUT_DIRECTORY"])
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let server = try #require(ProcessInfo.processInfo.environment["ORA_CODEX_SERVER_PATH"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OraCodexLive-\(UUID().uuidString)")
        let suite = "Ora.CodexLive.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = CustomizationStore(
            directory: root.appendingPathComponent("Customization"),
            defaults: defaults,
            watch: true,
            integrateApp: false
        )
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let manager = try ImporterTests.makeManager()
        var evidence: [[String: PreferenceValue]] = []
        func capture(_ name: String) throws {
            try evidence.append(render(name, store: store, defaults: defaults, output: output, manager: manager))
            try JSONEncoder().encode(evidence).write(
                to: output.appendingPathComponent("native-evidence.json"), options: .atomic
            )
        }
        try capture("before")
        let prompt = """
        This is an authorized live integration test. Use only the ora Model Context Protocol tools.
        Do not use shell commands, read files, access passwords, browse, or change other settings.
        Read list_settings_schema and get_settings. Record the original theme.dark.sidebar and theme.rowHeight.
        Use update_settings with the current expectedRevision to set
        theme.dark.sidebar to #333333 and theme.rowHeight to 48.
        Read get_settings until app.appliedRevision equals the update revision.
        Confirm the application acknowledged the change.
        Then call undo_settings with that expectedRevision, and read get_settings until
        app.appliedRevision equals the undo revision.
        Confirm both values were restored and report initial, applied, and restored revisions.
        Do not finish without undoing.
        """
        let promptFile = output.appendingPathComponent("prompt.txt")
        try Data(prompt.utf8).write(to: promptFile)
        let input = try FileHandle(forReadingFrom: promptFile)
        let stdoutFile = output.appendingPathComponent("codex-events.jsonl")
        let stderrFile = output.appendingPathComponent("codex-stderr.log")
        FileManager.default.createFile(atPath: stdoutFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderrFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: stdoutFile)
        let stderr = try FileHandle(forWritingTo: stderrFile)
        defer { try? input.close()
            try? stdout.close()
            try? stderr.close()
        }
        let process = try makeProcess(codex: codex, server: server, root: root)
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        var observed: Set = [0]
        let deadline = Date().addingTimeInterval(240)
        while process.isRunning, Date() < deadline {
            if store.revision > 0, !observed.contains(store.revision) {
                observed.insert(store.revision)
                try capture(store.revision == 1 ? "applied" : "restored")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw PreferenceError("Codex live test timed out. See its private event log.")
        }
        for _ in 0 ..< 20 where store.revision < 2 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if store.revision == 2, !observed.contains(2) {
            try capture("restored")
        }
        #expect(process.terminationStatus == 0)
        #expect(observed.contains(1))
        #expect(store.revision == 2)
        #expect(store.values["theme.rowHeight"] == .number(34))
        #expect(store.values["theme.dark.sidebar"] == .string("#262626"))
        #expect(evidence.first { $0["step"] == .string("applied") }?["nativeRowHeight"] == .number(48))
        #expect(evidence.first { $0["step"] == .string("applied") }?["nativeSidebar"] == .string("#333333"))
        try verifyEvents(stdoutFile)
        #expect(HeadlessTestHost.hasNoAppWindows)
    }

    private func verifyEvents(_ stdoutFile: URL) throws {
        let events = try String(contentsOf: stdoutFile, encoding: .utf8).split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(PreferenceValue.self, from: Data($0.utf8)) }
        let calls = events.compactMap { $0.dictionary?["item"]?.dictionary }.filter {
            $0["type"] == .string("mcp_tool_call") && $0["status"] == .string("completed") && $0["server"] ==
                .string("ora")
        }
        for name in ["list_settings_schema", "get_settings", "update_settings", "undo_settings"] {
            #expect(calls.contains { $0["tool"] == .string(name) })
        }
        let reads = calls.filter { $0["tool"] == .string("get_settings") }.compactMap { call in
            call["result"]?.dictionary?["content"]?.items?.compactMap { item in
                item.dictionary?["text"]?.text.flatMap { text in
                    try? JSONDecoder().decode(PreferenceValue.self, from: Data(text.utf8)).dictionary
                }
            }.first
        }
        for revision in [1, 2] {
            #expect(reads.contains { read in
                read["revision"] == .number(Double(revision)) &&
                    read["app"]?.dictionary?["appliedRevision"] == .number(Double(revision))
            })
        }
        #expect(!events.contains { $0.dictionary?["item"]?.dictionary?["type"] == .string("command_execution") })
    }

    private func render(
        _ name: String,
        store: CustomizationStore,
        defaults: UserDefaults,
        output: URL,
        manager: TabManager
    ) throws -> [String: PreferenceValue] {
        let space = try #require(manager.activeContainer)
        let tab = try manager.addTab(
            url: #require(URL(string: "about:blank")),
            container: space,
            isPrivate: false,
            activate: false
        )
        tab.title = "Codex live integration test"
        let history = HistoryManager(modelContainer: manager.modelContainer, modelContext: manager.modelContext)
        let downloads = DownloadManager(modelContainer: manager.modelContainer, modelContext: manager.modelContext)
        let theme = Theme(colorScheme: .dark, preferences: store.values)
        let view = VStack(alignment: .leading, spacing: theme.spacing) {
            Text(name).font(theme.textFont)
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
            Spacer()
        }.padding(16).frame(width: 360, height: 200)
            .foregroundStyle(theme.foreground).background(theme.solidWindowBackgroundColor)
            .environment(\.theme, theme).environment(\.colorScheme, .dark)
            .environmentObject(manager).environmentObject(history).environmentObject(downloads)
            .environmentObject(PrivacyMode(isPrivate: false))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 200)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name).png"))
        return [
            "step": .string(name),
            "revision": .number(Double(store.revision)),
            "rowHeight": .number(Double(theme.rowHeight)),
            "sidebar": store.values["theme.dark.sidebar"] ?? .null,
            "nativeRowHeight": .number(defaults.double(forKey: "customization.theme.rowHeight")),
            "nativeSidebar": .string(defaults
                .string(forKey: "customization.theme.dark.sidebar") ?? ""),
            "noVisibleWindows": .bool(HeadlessTestHost.hasNoAppWindows)
        ]
    }

    private func makeProcess(codex: String, server: String, root: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let arguments = try String(
            data: encoder.encode([server, "--directory", root.appendingPathComponent("Boosts").path]),
            encoding: .utf8
        )
        process.arguments = try [
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--cd",
            root.path,
            "-c",
            "mcp_servers.node_repl.enabled=false",
            "-c",
            "mcp_servers.computer-use.enabled=false",
            "-c",
            "mcp_servers.ora.args=\(#require(arguments))",
            "-c",
            "mcp_servers.ora.required=true",
            "-"
        ]
        if let model = ProcessInfo.processInfo.environment["ORA_CODEX_MODEL"] {
            process.arguments?.insert(contentsOf: ["--model", model], at: 1)
        }
        let inherited = ProcessInfo.processInfo.environment
        process.environment = Dictionary(uniqueKeysWithValues: [
            "HOME",
            "PATH",
            "TMPDIR",
            "USER",
            "LOGNAME",
            "SHELL",
            "LANG",
            "CODEX_HOME"
        ]
        .compactMap { key in inherited[key].map { (key, $0) } })
        // Xcode's test runner does not inherit the interactive shell's Homebrew path.
        let clientDirectory = URL(fileURLWithPath: codex).deletingLastPathComponent().path
        process.environment?["PATH"] = clientDirectory + ":" + (inherited["PATH"] ?? "/usr/bin:/bin")
        return process
    }
}
