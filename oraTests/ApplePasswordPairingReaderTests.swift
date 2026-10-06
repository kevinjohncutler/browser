import Foundation
import Testing

@MainActor
struct ApplePasswordPairingReaderTests {
    @Test func readsWholeGroupedAndSplitLabelsWithoutGuessing() {
        #expect(ApplePasswordPairingReader.code(from: ["Enable AutoFill", "482 913", "Done"]) == "482913")
        #expect(ApplePasswordPairingReader.code(from: ["4", "8", "2", "9", "1", "3"]) == "482913")
        #expect(ApplePasswordPairingReader.code(from: ["482913", "482913"]) == "482913")
        #expect(ApplePasswordPairingReader.code(from: ["482913", "123456"]) == nil)
        #expect(ApplePasswordPairingReader.code(from: ["1234567", "12345", "account 482913"]) == nil)
        #expect(ApplePasswordPairingReader.code(from: ["1", "2", "3", "4", "5", "6", "7"]) == nil)
        #expect(ApplePasswordPairingReader.code(from: ["１２３４５６"]) == nil)
    }

    @Test func readsOnlyAfterPermissionAndAuthentication() async throws {
        var authenticated = false
        var reads = 0
        let reader = ApplePasswordPairingReader(
            authorize: { authenticated = true
                return true
            },
            permission: { true },
            labels: { pid in
                #expect(authenticated)
                #expect(pid == 42)
                reads += 1
                return [["482 913"]]
            }
        )
        #expect(try await reader.read(parentPID: 42) == "482913")
        #expect(reads == 1)
    }

    @Test func deniedPermissionAndCanceledAuthenticationNeverReadCode() async {
        var prompts = 0
        var reads = 0
        let denied = ApplePasswordPairingReader(
            authorize: { prompts += 1
                return true
            },
            permission: { false },
            labels: { _ in reads += 1
                return [["482913"]]
            }
        )
        await #expect(throws: (any Error).self) { try await denied.read(parentPID: 42) }
        #expect(prompts == 0)
        let canceled = ApplePasswordPairingReader(
            authorize: { prompts += 1
                return false
            },
            permission: { true },
            labels: { _ in reads += 1
                return [["482913"]]
            }
        )
        await #expect(throws: (any Error).self) { try await canceled.read(parentPID: 42) }
        #expect(prompts == 1)
        #expect(reads == 0)
    }

    @Test func rejectsAmbiguousDialogsAndCanceledInFlightAuthentication() async {
        let ambiguous = ApplePasswordPairingReader(
            authorize: { true },
            permission: { true },
            labels: { _ in [["482913"], ["123456"]] }
        )
        await #expect(throws: (any Error).self) { try await ambiguous.read(parentPID: 42) }
        var waiting = false
        var reads = 0
        let canceled = ApplePasswordPairingReader(authorize: {
            waiting = true
            try? await Task.sleep(nanoseconds: 30_000_000)
            return true
        }, permission: { true }, labels: { _ in reads += 1
            return [["482913"]]
        })
        let task = Task { try await canceled.read(parentPID: 42) }
        while !waiting {
            await Task.yield()
        }
        canceled.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(reads == 0)
    }

    @Test func acceptsOwnChildAncestryAndRejectsOtherProcesses() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["2"]
        try process.run()
        defer { process.terminate()
            process.waitUntilExit()
        }
        #expect(ApplePasswordPairingReader.isDescendant(
            process.processIdentifier,
            of: ProcessInfo.processInfo.processIdentifier
        ))
        #expect(!ApplePasswordPairingReader.isDescendant(
            ProcessInfo.processInfo.processIdentifier,
            of: process.processIdentifier
        ))
        #expect(!ApplePasswordPairingReader.isDescendant(process.processIdentifier, of: process.processIdentifier))
    }
}
