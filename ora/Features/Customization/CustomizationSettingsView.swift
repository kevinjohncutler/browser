import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CustomizationSettingsView: View {
    @ObservedObject private var store: CustomizationStore
    @State private var search = ""
    @State private var error: String?
    @State private var importProfile = false
    @State private var exportProfile = false
    @State private var profileData = Data()

    init(store: CustomizationStore = .shared) {
        self.store = store
    }

    private var filtered: [PreferenceDefinition] {
        store.definitions
            .filter {
                search.isEmpty || ($0.title + " " + $0.id + " " + $0.description)
                    .localizedCaseInsensitiveContains(search)
            }
    }

    var body: some View {
        SettingsSection {
            SettingsCard(header: "Connect your model") {
                Text(
                    "Ask your model to customize Ora's appearance, layout, or browser preferences. Changes persist and supported settings apply while Ora is running."
                )
                Text(
                    "Model Context Protocol (MCP) connects Ora to compatible clients. The local server requires Python."
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy Claude Code setup") { copy(MCPIntegration.claudeCommand) }
                    Button("Copy client configuration") { copy(MCPIntegration.configuration) }
                }
                Text(
                    "Run the copied setup command, or add the copied configuration to your client's MCP settings. Restart the client to discover Ora's tools. Use one Ora registration per client."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard(header: "Personalization") {
                HStack {
                    Button("Undo last change") { perform { try store.undo() } }
                    Button("Import profile") { importProfile = true }
                    Button("Export profile") {
                        perform { profileData = try store.exportProfile(name: "Ora personalization")
                            exportProfile = true
                        }
                    }
                    Button("Reset appearance") {
                        perform { try store.reset(store.definitions.filter { $0.category == "Appearance" }.map(\.id)) }
                    }
                }
                TextField("Find a setting", text: $search)
                if let message = error ?? store.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            ForEach(Array(Set(filtered.map(\.category))).sorted(), id: \.self) { category in
                SettingsCard(header: category) {
                    ForEach(filtered.filter { $0.category == category }) { definition in
                        PreferenceEditorRow(
                            definition: definition,
                            value: store.values[definition.id] ?? definition.defaultValue,
                            spaceName: store.spaces.first { definition.id.hasPrefix("space.\($0.id).") }?.name
                        ) { value in
                            perform { try store.update([definition.id: value]) }
                        } reset: { perform { try store.reset([definition.id]) } }
                    }
                }
            }
        }
        .fileImporter(isPresented: $importProfile, allowedContentTypes: [.json]) { result in
            perform {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                try store.importProfile(Data(contentsOf: url))
            }
        }
        .fileExporter(
            isPresented: $exportProfile,
            document: OraProfileFile(data: profileData),
            contentType: .json,
            defaultFilename: "Ora personalization"
        ) { result in
            if case let .failure(failure) = result {
                error = failure.localizedDescription
            }
        }
    }

    private func perform(_ body: () throws -> Void) {
        do { try body()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct OraProfileFile: FileDocument {
    static var readableContentTypes: [UTType] {
        [.json]
    }

    var data: Data
    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws
        -> FileWrapper
    {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct PreferenceEditorRow: View {
    let definition: PreferenceDefinition
    let value: PreferenceValue
    let spaceName: String?
    let save: (PreferenceValue) -> Void
    let reset: () -> Void
    @State private var draft: String?
    @State private var number: Double?
    @State private var error: String?

    private var encoded: String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value.foundation,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        ) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(definition.title)
                if definition
                    .scope ==
                    "space"
                {
                    Text(spaceName ?? String(definition.id.split(separator: ".")[1]).prefix(8).description)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset", action: reset).buttonStyle(.borderless)
            }
            editor
            Text(definition
                .description +
                (definition.apply == "live" ? "" : definition
                    .apply == "nextLaunch" ? " Applies on next launch." : " Applies on next navigation."))
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
        .help(definition.id)
    }

    @ViewBuilder private var editor: some View {
        if let boolean = value.boolean {
            Toggle("Enabled", isOn: Binding(get: { boolean }, set: { save(.bool($0)) }))
        } else if let options = definition.schema["enum"]?.items, options.allSatisfy({ $0.text != nil }) {
            Picker("Value", selection: Binding(get: { value.text ?? "" }, set: { save(.string($0)) })) {
                ForEach(options.compactMap(\.text), id: \.self) { Text($0).tag($0) }
            }.labelsHidden()
        } else if definition.schema["pattern"]?.text == "^#[0-9a-fA-F]{6}$" {
            ColorPicker("Color", selection: Binding(get: { Color(hex: value.text ?? "#171717") }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                save(.string(String(
                    format: "#%02x%02x%02x",
                    Int((rgb.redComponent * 255).rounded()),
                    Int((rgb.greenComponent * 255).rounded()),
                    Int((rgb.blueComponent * 255).rounded())
                )))
            }), supportsOpacity: false)
        } else if let numeric = value.numeric,
                  let minimum = definition.schema["minimum"]?.numeric,
                  let maximum = definition.schema["maximum"]?.numeric
        {
            HStack {
                Slider(
                    value: Binding(get: { number ?? numeric }, set: { number = $0 }),
                    in: minimum ... maximum,
                    step: definition.schema["type"] == .string("integer") ? 1 : maximum <= 1 ? 0.01 : 1,
                    onEditingChanged: {
                        editing in if !editing, let number {
                            save(.number(number))
                            self.number = nil
                        }
                    }
                )
                Text(String(format: maximum <= 1 ? "%.2f" : "%.0f", number ?? numeric)).monospacedDigit()
                    .frame(width: 44)
            }
        } else if let options = definition.schema["enum"]?.items {
            Picker("Value", selection: Binding(get: { numericIndex(options) }, set: { save(options[$0]) })) {
                ForEach(options.indices, id: \.self) { index in
                    Text(String(describing: options[index].foundation)).tag(index)
                }
            }.labelsHidden()
        } else {
            if value.dictionary != nil || value.items != nil {
                TextEditor(text: Binding(get: { draft ?? encoded }, set: { draft = $0 }))
                    .font(.system(.caption, design: .monospaced)).frame(height: 100)
            } else {
                TextField("Value", text: Binding(get: { draft ?? value.text ?? "" }, set: { draft = $0 }))
            }
            Button("Apply") {
                do {
                    let edited: PreferenceValue = if value.dictionary != nil || value
                        .items != nil
                    {
                        try JSONDecoder().decode(
                            PreferenceValue.self,
                            from: Data((draft ?? encoded).utf8)
                        )
                    } else {
                        (draft ?? "").isEmpty && definition
                            .defaultValue == .null ? .null : .string(draft ?? value.text ?? "")
                    }
                    try PreferenceCatalog.validate(edited, schema: definition.schema, label: definition.title)
                    save(edited)
                    draft = nil
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func numericIndex(_ options: [PreferenceValue]) -> Int {
        options.firstIndex(of: value) ?? 0
    }
}
