import Foundation

/// Chromium native messaging framing used by Apple's system password helper.
struct NativeMessageFramer {
    static let maximumMessageSize = 1_048_576
    private var buffer = Data()

    static func encode(_ message: Any) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard body.count <= maximumMessageSize else { throw CocoaError(.fileReadTooLarge) }
        var size = UInt32(body.count).littleEndian
        var result = withUnsafeBytes(of: &size) { Data($0) }
        result.append(body)
        return result
    }

    mutating func receive(_ chunk: Data) throws -> [Any] {
        buffer.append(chunk)
        var messages: [Any] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            guard size > 0, size <= Self.maximumMessageSize else { throw CocoaError(.fileReadCorruptFile) }
            guard buffer.count >= Int(size) + 4 else { break }
            try messages.append(JSONSerialization.jsonObject(
                with: Data(buffer.dropFirst(4).prefix(Int(size))),
                options: [.fragmentsAllowed]
            ))
            buffer = Data(buffer.dropFirst(Int(size) + 4))
        }
        return messages
    }

    var hasIncompleteMessage: Bool {
        !buffer.isEmpty
    }
}

@MainActor
final class NativePasswordMessaging {
    nonisolated static let applicationIdentifier = "com.apple.passwordmanager"
    nonisolated static let extensionIdentifier = "pejdijmoenmkgeppbflobdenhhabjlaj"
    nonisolated static let helperURL =
        URL(
            fileURLWithPath: "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper"
        )

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var framer = NativeMessageFramer()
    private var closed = false
    private var reachedEnd = false
    private var exitStatus: Int32?
    var onMessage: ((Any) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    init(executable: URL = helperURL, arguments: [String] = ["chrome-extension://\(extensionIdentifier)/"]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        // Never log helper output: diagnostic streams may contain credential context.
        process.standardError = FileHandle.nullDevice
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                self?.terminated(status)
            }
        }
        do { try process.run() } catch { finish(error)
            throw error
        }
    }

    func send(_ message: Any) throws {
        guard !closed, process.isRunning else { throw CocoaError(.fileWriteUnknown) }
        try input.fileHandleForWriting.write(contentsOf: NativeMessageFramer.encode(message))
    }

    func close() {
        guard !closed else { return }
        finish(nil)
        if process.isRunning {
            process.terminate()
        }
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        if data.isEmpty {
            reachedEnd = true
            if framer.hasIncompleteMessage {
                finish(CocoaError(.fileReadCorruptFile))
            } else if let exitStatus {
                terminated(exitStatus)
            }
            return
        }
        do {
            for message in try framer.receive(data) {
                onMessage?(message)
            }
        } catch { finish(error)
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func terminated(_ status: Int32) {
        exitStatus = status
        guard reachedEnd else { return }
        finish(status == 0 ? nil : NSError(
            domain: "OraPasswordHelper", code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: "Apple's password helper exited (status \(status)). The browser's signing identity may not be authorized by macOS."
            ]
        ))
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        onDisconnect?(error)
        onMessage = nil
        onDisconnect = nil
    }
}
