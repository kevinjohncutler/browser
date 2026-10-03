import Combine
import Darwin
import Foundation

struct CSSBoost: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var pattern: String
    var css: String
    var enabled: Bool
}

struct CSSBoostDocument: Codable {
    var version = 1
    var rules: [CSSBoost] = []
}

extension Notification.Name {
    static let cssBoostsChanged = Notification.Name("ora.cssBoostsChanged")
}

@MainActor
final class BoostStore: ObservableObject {
    static let shared = BoostStore()
    @Published private(set) var rules: [CSSBoost] = []
    @Published private(set) var errorMessage: String?
    let directory: URL
    private var previousData: Data?
    private var timer: Timer?

    init(directory: URL? = nil, watch: Bool = true) {
        self.directory = directory ?? URL.applicationSupportDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier?
                .hasSuffix(".dev") == true ? "OraDev/Boosts" : "Ora/Boosts")
        reload()
        if watch {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
        }
    }

    deinit { timer?.invalidate() }

    var fileURL: URL {
        directory.appendingPathComponent("boosts.json")
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if previousData != nil {
                previousData = nil
                rules = []
                errorMessage = nil
                NotificationCenter.default.post(name: .cssBoostsChanged, object: self)
            }
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data != previousData else { return }
            let document = try JSONDecoder().decode(CSSBoostDocument.self, from: data)
            guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            rules = document.rules
            previousData = data
            errorMessage = nil
            NotificationCenter.default.post(name: .cssBoostsChanged, object: self)
        } catch {
            errorMessage = "Could not read CSS Boosts: \(error.localizedDescription)"
        }
    }

    func save(_ boost: CSSBoost) throws {
        guard Self.validPattern(boost.pattern), !boost.name.isEmpty, boost.css.utf8.count <= 200_000 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        try mutate { rules in
            if let index = rules.firstIndex(where: { $0.id == boost.id }) {
                rules[index] = boost
            } else {
                rules.append(boost)
            }
        }
    }

    func remove(id: String) throws {
        try mutate { $0.removeAll { $0.id == id } }
    }

    private func mutate(_ mutation: (inout [CSSBoost]) -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("boosts.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var document = CSSBoostDocument()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            document = try JSONDecoder().decode(CSSBoostDocument.self, from: Data(contentsOf: fileURL))
            guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        }
        mutation(&document.rules)
        try JSONEncoder().encode(document).write(to: fileURL, options: .atomic)
        reload()
    }

    static func validPattern(_ pattern: String) -> Bool {
        if pattern == "*" {
            return true
        }
        let host = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
        return host.range(of: #"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil
            && !host.contains("..")
    }

    func publishActivePage(url: URL?, title: String?, isPrivate: Bool) {
        let file = directory.appendingPathComponent("active-page.json")
        guard !isPrivate, let url, ["http", "https"].contains(url.scheme) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let object = [
            "url": url.absoluteString,
            "host": url.host ?? "",
            "title": title ?? "",
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }

    func script() -> String {
        Self.script(rules: rules)
    }

    static func script(rules: [CSSBoost]) -> String {
        let data = (try? JSONEncoder().encode(rules)) ?? Data("[]".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return """
        (() => {
          if (!['http:', 'https:'].includes(location.protocol)) return;
          const rules = \(json);
          const key = '__oraCSSBoosts';
          if (window[key]) { window[key].update(rules); return; }
          let current = rules;
          const styleID = 'ora-css-boosts';
          function apply() {
            if (!document.documentElement) return;
            const host = location.hostname.toLowerCase();
            const css = current.filter(rule => rule.enabled && (rule.pattern === '*' ||
              rule.pattern === host || (rule.pattern.startsWith('*.') &&
                (host === rule.pattern.slice(2) || host.endsWith('.' + rule.pattern.slice(2))))))
              .map(rule => rule.css).join('\\n');
            let style = document.getElementById(styleID);
            if (!style) {
              style = document.createElement('style'); style.id = styleID;
              (document.head || document.documentElement).appendChild(style);
            }
            if (style.textContent !== css) style.textContent = css;
          }
          window[key] = { update(next) { current = next; apply(); } };
          new MutationObserver(apply).observe(document, {childList: true, subtree: true});
          apply();
        })();
        """
    }

    static let defaultBackgroundScript = """
    (() => {
      const install = () => {
        if (!document.documentElement) return;
        if (document.getElementById('ora-default-background')) return;
        const style = document.createElement('style');
        style.id = 'ora-default-background';
        style.textContent = 'html { color-scheme: dark; background-color: #171717; color: #e5e5e5; }';
        (document.head || document.documentElement).prepend(style);
      };
      new MutationObserver(install).observe(document, {childList:true, subtree:true});
      install();
    })();
    """
}
