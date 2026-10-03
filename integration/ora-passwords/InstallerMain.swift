import Foundation

@main
struct InstallerMain {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(
                domain: "OraInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Usage: installer SOURCE DESTINATION"]
            )
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try ApplePasswordExtensionInstaller.install(from: source, to: destination)
        print("Installed Apple Passwords extension: \(destination.path)")
    }
}
