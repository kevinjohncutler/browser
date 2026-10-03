@testable import Ora
import Testing

@MainActor
struct PasswordUnlockSessionTests {
    @Test func authenticatesOnceAcrossAutofillAndVaultRequests() async {
        var prompts = 0
        let session = PasswordUnlockSession { _ in prompts += 1
            return true
        }
        #expect(await session.authenticate(reason: "Autofill"))
        #expect(await session.authenticate(reason: "Open vault"))
        #expect(await session.authenticate(reason: "Another website"))
        #expect(prompts == 1)
        #expect(session.isUnlocked)
    }

    @Test func coalescesConcurrentUnlockRequests() async {
        var prompts = 0
        let session = PasswordUnlockSession { _ in
            prompts += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
            return true
        }
        async let first = session.authenticate(reason: "First tab")
        async let second = session.authenticate(reason: "Second tab")
        #expect(await first)
        #expect(await second)
        #expect(prompts == 1)
    }

    @Test func cancellationDoesNotUnlockAndCanBeRetried() async {
        var prompts = 0
        let session = PasswordUnlockSession { _ in prompts += 1
            return prompts > 1
        }
        #expect(await !session.authenticate(reason: "Canceled"))
        #expect(!session.isUnlocked)
        #expect(await session.authenticate(reason: "Retry"))
        #expect(prompts == 2)
    }

    @Test func manualLockRejectsAnOlderInFlightAuthentication() async {
        var prompts = 0
        let session = PasswordUnlockSession { _ in
            prompts += 1
            try? await Task.sleep(nanoseconds: 30_000_000)
            return true
        }
        let first = Task { await session.authenticate(reason: "Before lock") }
        while prompts == 0 {
            await Task.yield()
        }
        session.lock()
        #expect(await !first.value)
        #expect(!session.isUnlocked)
        #expect(await session.authenticate(reason: "After lock"))
        #expect(prompts == 2)
    }

    @Test func freshBrowserSessionStartsLocked() async {
        let first = PasswordUnlockSession { _ in true }
        #expect(await first.authenticate(reason: "First launch"))
        let next = PasswordUnlockSession { _ in true }
        #expect(!next.isUnlocked)
    }
}
