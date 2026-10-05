import Darwin
import Foundation

enum MCPIntegration {
    static var serverURL: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"))
            .appendingPathComponent("OraMCP/server.py")
    }

    static var pythonCommand: String {
        let accountHome = getpwuid(getuid())
            .flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        let candidates = [
            URL(fileURLWithPath: accountHome).appendingPathComponent(".pyenv/shims/python").path,
            "/opt/homebrew/bin/python",
            "/usr/local/bin/python"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "python"
    }

    static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static var claudeCommand: String {
        "claude mcp add --scope user ora-css -- " + quote(pythonCommand) + " " + quote(serverURL.path)
    }

    static var configuration: String {
        let object = ["mcpServers": ["ora-css": ["command": pythonCommand, "args": [serverURL.path]] as [String: Any]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
