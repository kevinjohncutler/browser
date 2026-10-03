import AppKit
@testable import Ora
import SwiftUI
import Testing

@MainActor
struct BrowserLayoutTests {
    @Test func rendersSidebarAddressFieldHeadlessly() throws {
        let manager = try ImporterTests.makeManager()
        let space = try #require(manager.activeContainer)
        let tab = try manager.addTab(
            url: #require(URL(string: "https://example.com/docs")),
            container: space,
            isPrivate: false,
            activate: false
        )
        manager.activeTab = tab
        let history = HistoryManager(modelContainer: manager.modelContainer, modelContext: manager.modelContext)
        let downloads = DownloadManager(modelContainer: manager.modelContainer, modelContext: manager.modelContext)
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(spacing: 0) {
                SidebarHeader()
                URLBar(onSidebarToggle: {}, isInSidebar: true).padding(.horizontal, 10)
                Text("Favorite tabs and folders").padding(20)
                Spacer()
            }
            .environmentObject(manager)
            .environmentObject(AppState())
            .environmentObject(SidebarManager())
            .environmentObject(ToolbarManager())
            .environmentObject(ToastManager.shared)
            .environmentObject(history)
            .environmentObject(downloads)
            .environmentObject(PrivacyMode(isPrivate: false))
            .environment(\.theme, Theme(colorScheme: scheme))
            .environment(\.colorScheme, scheme)
            .frame(width: 320, height: 220)
            .background(scheme == .dark ? Color(white: 0.09) : Color(white: 0.98))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(data.count > 1000)
            #expect(NSApplication.shared.windows.isEmpty)
            if let path = ProcessInfo.processInfo.environment["ORA_PREVIEW_DIRECTORY"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(
                    scheme == .dark ? "address-sidebar-dark.png" : "address-sidebar-light.png"
                ))
            }
        }
    }
}
