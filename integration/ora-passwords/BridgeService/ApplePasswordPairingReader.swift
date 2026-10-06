import AppKit
import ApplicationServices
import Darwin
import LocalAuthentication
import Security

/// Reads only this bridge's signed Apple helper after macOS authenticates the user.
/// The pairing secret is returned through the checked XPC connection and never persisted.
@MainActor
final class ApplePasswordPairingReader {
    private let authorize: () async -> Bool
    private let permission: () -> Bool
    private let labels: (pid_t) -> [[String]]
    private var authentication: LAContext?
    private var generation = UUID()
    private var busy = false

    init(
        authorize: (() async -> Bool)? = nil,
        permission: (() -> Bool)? = nil,
        labels: ((pid_t) -> [[String]])? = nil
    ) {
        self.authorize = authorize ?? { false }
        self.permission = permission ?? {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt
                    .takeUnretainedValue() as String: true] as CFDictionary)
        }
        self.labels = labels ?? Self.helperLabels
        usesSystemAuthentication = authorize == nil
    }

    private let usesSystemAuthentication: Bool

    func read(parentPID: pid_t, attempts: Int = 40) async throws -> String {
        guard parentPID > 0, !busy else { throw failure("An Apple Passwords unlock is already in progress.") }
        busy = true
        defer { busy = false }
        let token = generation
        guard permission() else {
            throw failure(
                "Allow Ora's password helper in System Settings > Privacy & Security > Accessibility once. You can enter Apple's code manually until then."
            )
        }
        let approved = usesSystemAuthentication ? await authenticate() : await authorize()
        guard approved, generation == token, !Task.isCancelled else {
            throw failure("Apple Passwords unlock was canceled. Your code has not been entered.")
        }
        let deadline = Date().addingTimeInterval(8)
        for _ in 0 ..< attempts {
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            guard Date() < deadline else { break }
            let candidates = labels(parentPID).compactMap(Self.code)
            // Never guess among multiple dialogs. A stale or unrelated code invalidates the handshake.
            if candidates.count == 1 {
                return candidates[0]
            }
            if candidates
                .count > 1
            {
                throw failure("More than one Apple pairing dialog is open. Enter the code manually.")
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw failure(
            "Apple's pairing code was not readable. Enter the code manually, or reopen Unlock Apple Passwords to retry."
        )
    }

    func cancel() {
        generation = UUID()
        authentication?.invalidate()
        authentication = nil
    }

    private func authenticate() async -> Bool {
        let context = LAContext()
        authentication = context
        defer { authentication = nil }
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Enable Apple Passwords in Ora without typing the pairing code"
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    /// Accepts whole static labels only, not numbers embedded in instructions or account text.
    static func code(from labels: [String]) -> String? {
        var matches = Set<String>()
        var digits: [String] = []
        func finishDigits() {
            if digits.count == 6 {
                matches.insert(digits.joined())
            }
            digits.removeAll()
        }
        for label in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let compact = trimmed.filter { !$0.isWhitespace && $0 != "-" }
            if compact.count == 6, compact.allSatisfy({ $0.isASCII && $0.isNumber }) {
                matches.insert(compact)
            }
            if trimmed.count == 1, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) {
                digits.append(trimmed)
            } else {
                finishDigits()
            }
        }
        finishDigits()
        return matches.count == 1 ? matches.first : nil
    }

    private static func helperLabels(parentPID: pid_t) -> [[String]] {
        var result: [[String]] = []
        let deadline = Date().addingTimeInterval(1)
        for app in NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.PasswordManagerBrowserExtensionHelper")
        {
            let pid = app.processIdentifier
            guard isDescendant(pid, of: parentPID), isAppleHelper(pid) else { continue }
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.25)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows.prefix(4) {
                guard Date() < deadline else { return result }
                var labels: [String] = []
                var remaining = 256
                collect(window, depth: 0, deadline: deadline, remaining: &remaining, into: &labels)
                result.append(labels)
            }
        }
        return result
    }

    private static func collect(
        _ element: AXUIElement,
        depth: Int,
        deadline: Date,
        remaining: inout Int,
        into labels: inout [String]
    ) {
        guard depth < 8, remaining > 0, Date() < deadline else { return }
        remaining -= 1
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           role as? String == kAXStaticTextRole as String
        {
            // Value and title can be identical. Read one, so split digits are not duplicated.
            for name in [kAXValueAttribute, kAXTitleAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                   let text = value as? String, !text.isEmpty
                {
                    labels.append(text)
                    break
                }
            }
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
           let children = value as? [AXUIElement]
        {
            for child in children.prefix(remaining) {
                collect(child, depth: depth + 1, deadline: deadline, remaining: &remaining, into: &labels)
            }
        }
    }

    static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        guard pid > 1, ancestor > 1, pid != ancestor else { return false }
        var current = pid
        for _ in 0 ..< 16 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) ==
                MemoryLayout<proc_bsdinfo>.size else { return false }
            current = pid_t(info.pbi_ppid)
            if current == ancestor {
                return true
            }
            if current <= 1 {
                return false
            }
        }
        return false
    }

    private static func isAppleHelper(_ pid: pid_t) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) ==
            errSecSuccess,
            let code,
            SecRequirementCreateWithString(
                "anchor apple and identifier \"com.apple.PasswordManagerBrowserExtensionHelper\"" as CFString,
                [],
                &requirement
            ) == errSecSuccess,
            let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "OraPasswordPairing", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
