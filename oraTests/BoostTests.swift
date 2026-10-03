import AppKit
import Foundation
@testable import Ora
import SwiftUI
import Testing
import WebKit

@MainActor
struct BoostTests {
    func makeStore() throws -> BoostStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return BoostStore(directory: directory, watch: false)
    }

    @Test func persistsRulesAndPreservesLastGoodData() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let rule = CSSBoost(
            id: "test",
            name: "Dark",
            pattern: "*.example.com",
            css: "body {background:#171717}",
            enabled: true
        )
        try store.save(rule)
        let reopened = BoostStore(directory: store.directory, watch: false)
        #expect(reopened.rules == [rule])
        try Data("bad data".utf8).write(to: store.fileURL, options: .atomic)
        reopened.reload()
        #expect(reopened.rules == [rule])
        #expect(reopened.errorMessage != nil)
        #expect(BoostStore.validPattern("*"))
        #expect(!BoostStore.validPattern("https://example.com"))
        #expect(!BoostStore.validPattern("*example.com"))
        #expect(!BoostStore.validPattern("example.com/other"))
    }

    @Test func rendersNativeCSSEditorOffscreen() throws {
        guard let path = ProcessInfo.processInfo.environment["ORA_PREVIEW_DIRECTORY"] else { return }
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(CSSBoost(
            id: "fixture",
            name: "Dark reading",
            pattern: "*.example.com",
            css: "html,body {background:#171717 !important;color:#e5e5e5 !important}",
            enabled: true
        ))
        let view = BoostsSettingsView(store: store)
            .environment(\.colorScheme, .dark)
            .environment(\.theme, Theme(colorScheme: .dark))
            .frame(width: 800, height: 760)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 760)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("css-boost-editor.png"))
        #expect(HeadlessTestHost.hasNoAppWindows)
    }

    @Test func privateContextIsRemoved() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let url = try #require(URL(string: "https://example.com"))
        store.publishActivePage(url: url, title: "Example", isPrivate: false)
        let file = store.directory.appendingPathComponent("active-page.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        store.publishActivePage(url: url, title: "Private", isPrivate: true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func appliesChangesWrittenByTheActualMCPServer() async throws {
        guard let server = ProcessInfo.processInfo.environment["ORA_CSS_SERVER_PATH"],
              let interpreter = ProcessInfo.processInfo.environment["ORA_PYTHON_PATH"] else { return }
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [server, "--directory", store.directory.path]
        let output = Pipe()
        process.standardOutput = output
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": "upsert_css_boost", "arguments": [
                "id": "mcp",
                "name": "Dark",
                "pattern": "*.example.com",
                "css": "body{background:#171717}"
            ]
        ]]
        let requestFile = store.directory.appendingPathComponent("request.json")
        try (JSONSerialization.data(withJSONObject: request) + Data([10])).write(to: requestFile)
        let input = try FileHandle(forReadingFrom: requestFile)
        defer { try? input.close() }
        process.standardInput = input
        try process.run()
        for _ in 0 ..< 200 where process.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw CocoaError(.fileReadUnknown)
        }
        let reply = output.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0)
        let response = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect((response["result"] as? [String: Any])?["isError"] as? Bool == false)
        store.reload()
        #expect(store.rules.first?.id == "mcp")
        let reopened = BoostStore(directory: store.directory, watch: false)
        #expect(reopened.rules == store.rules)
    }

    func evaluate(_ page: BrowserPage, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            page.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    func waitForPage(_ page: BrowserPage) async throws {
        for _ in 0 ..< 200 {
            if !page.isLoading, page.currentURL != nil,
               await (try? evaluate(page, "document.readyState")) as? String == "complete"
            {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw CocoaError(.fileReadUnknown)
    }

    func assertBackground(_ page: BrowserPage, expected: String) async throws {
        let value = try await evaluate(page, "getComputedStyle(document.documentElement).backgroundColor")
        #expect(value as? String == expected)
        try await assertDarkPixels(page)
    }

    func assertDarkPixels(_ page: BrowserPage) async throws {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            page.takeSnapshot(configuration: .full) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 10, y: bitmap.pixelsHigh - 10)?
            .usingColorSpace(.deviceRGB))
        #expect(color.redComponent < 0.2)
        #expect(color.greenComponent < 0.2)
        #expect(color.blueComponent < 0.2)
        if let path = ProcessInfo.processInfo.environment["ORA_PREVIEW_DIRECTORY"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("webkit-dark-background.png"))
        }
    }

    @Test func realWebKitRefreshNavigationAndLiveBoosts() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["ORA_WEB_FIXTURE_URL"] else { return }
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let page = BrowserPage(
            profile: BrowserEngineProfile(identifier: UUID(), isPrivate: true),
            configuration: .oraDefault(
                userScripts: [BrowserUserScript(
                    name: "fixture",
                    source: "window.oraFixture = true;",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )],
                privacySettings: SpacePrivacySettings()
            ),
            delegate: nil,
            boostStore: store
        )
        defer { page.teardown() }
        page.contentView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        let webView = try #require(page.contentView as? WKWebView)
        #expect(try #require(webView.underPageBackgroundColor?.usingColorSpace(.deviceRGB)).redComponent < 0.2)
        #expect(webView.value(forKey: "drawsBackground") as? Bool == false)
        let blank = try #require(page.contentView.bitmapImageRepForCachingDisplay(in: page.contentView.bounds))
        page.contentView.cacheDisplay(in: page.contentView.bounds, to: blank)
        let blankColor = try #require(blank.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        #expect(blankColor.alphaComponent < 0.01 || blankColor.redComponent < 0.2)
        for path in ["/plain", "/slow", "/redirect"] {
            try page.load(URLRequest(url: #require(URL(string: fixture + path))))
            try await waitForPage(page)
            try await assertBackground(page, expected: "rgb(23, 23, 23)")
            for _ in 0 ..< 3 {
                page.reload()
                try await assertDarkPixels(page)
                try await waitForPage(page)
                try await assertBackground(page, expected: "rgb(23, 23, 23)")
            }
        }
        let rule = CSSBoost(
            id: "test",
            name: "Dark",
            pattern: "127.0.0.1",
            css: "html,body {background:#202020 !important;color:#eeeeee !important}",
            enabled: true
        )
        try store.save(rule)
        try page.load(URLRequest(url: #require(URL(string: fixture + "/styled"))))
        try await waitForPage(page)
        try await assertBackground(page, expected: "rgb(32, 32, 32)")
        try store.remove(id: rule.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(try await evaluate(page, "getComputedStyle(document.documentElement).backgroundColor") as? String
            == "rgb(255, 255, 255)")
        try store.save(rule)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await assertBackground(page, expected: "rgb(32, 32, 32)")
        page.reload()
        try await waitForPage(page)
        try await assertBackground(page, expected: "rgb(32, 32, 32)")
        let wildcard = CSSBoost(
            id: "wildcard",
            name: "Local scope",
            pattern: "*.localhost",
            css: "html,body{background:#202020 !important}",
            enabled: true
        )
        try store.remove(id: rule.id)
        try store.save(wildcard)
        try page.load(URLRequest(url: #require(URL(string: fixture + "/plain"))))
        try await waitForPage(page)
        try await assertBackground(page, expected: "rgb(23, 23, 23)")
        let otherHost = fixture.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        try page.load(URLRequest(url: #require(URL(string: otherHost + "/plain"))))
        try await waitForPage(page)
        try await assertBackground(page, expected: "rgb(32, 32, 32)")
        var disabled = wildcard
        disabled.enabled = false
        try store.save(disabled)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await assertBackground(page, expected: "rgb(23, 23, 23)")
        #expect(try await evaluate(page, "window.oraFixture") as? Bool == true)
        #expect(HeadlessTestHost.hasNoAppWindows)
    }
}
