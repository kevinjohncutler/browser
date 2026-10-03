import Combine
import Foundation
import LocalAuthentication

@MainActor
final class PasswordUnlockSession: ObservableObject {
    static let shared = PasswordUnlockSession()
    @Published private(set) var isUnlocked = false
    private let prompt: @MainActor (String) async -> Bool
    private var pending: Task<Bool, Never>?
    private var generation = UUID()

    init(prompt: @escaping @MainActor (String) async -> Bool = PasswordUnlockSession.systemAuthentication) {
        self.prompt = prompt
    }

    func authenticate(reason: String) async -> Bool {
        if isUnlocked {
            return true
        }
        let token = generation
        if pending == nil {
            let prompt = self.prompt
            pending = Task { await prompt(reason) }
        }
        guard let request = pending else { return false }
        let success = await request.value
        guard generation == token else { return false }
        pending = nil
        isUnlocked = success
        return success
    }

    func lock() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        isUnlocked = false
    }

    static func systemAuthentication(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                    continuation.resume(returning: success)
                }
            }
        } onCancel: {
            context.invalidate()
        }
    }
}
