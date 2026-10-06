import AppKit
import Foundation
import SwiftData
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable automatic window tabbing for all NSWindow instances
        NSWindow.allowsAutomaticWindowTabbing = false
        _ = SettingsStore.shared
        _ = CustomizationStore.shared
        AppearanceManager.shared.updateAppearance()
        #if DEBUG
            Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle")?.load()
            Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSSwiftUISupport.bundle")?.load()
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SettingsStore.shared.confirmBeforeQuit else { return .terminateNow }
        let targetWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
        guard let targetWindow else { return .terminateNow }
        NotificationCenter.default.post(name: .quitRequested, object: targetWindow)
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleIncomingURLs(urls)
    }

    func getWindow() -> NSWindow? {
        if let key = NSApp.keyWindow {
            return key
        }
        if let visible = NSApp.windows.first(where: { $0.isVisible }) {
            return visible
        }
        if let any = NSApp.windows.first {
            any.makeKeyAndOrderFront(nil)
            return any
        }
        return WindowFactory.makeMainWindow(rootView: OraRoot())
    }

    func handleIncomingURLs(_ urls: [URL]) {
        let window = getWindow()!
        for url in urls {
            let userInfo: [AnyHashable: Any] = ["url": url]
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openURL, object: window, userInfo: userInfo)
            }
        }
    }
}

func deleteSwiftDataStore(_ loc: String) {
    let fileManager = FileManager.default
    let storeURL = URL.applicationSupportDirectory.appending(path: loc)
    let shmURL = storeURL.appendingPathExtension("-shm")
    let walURL = storeURL.appendingPathExtension("-wal")
    try? fileManager.removeItem(at: storeURL)
    try? fileManager.removeItem(at: shmURL)
    try? fileManager.removeItem(at: walURL)
}

class AppState: ObservableObject {
    @Published var showLauncher: Bool = false
    @Published var launcherSearchText: String = ""
    @Published var showFinderIn: UUID?
    @Published var isFloatingTabSwitchVisible: Bool = false
    @Published var isFullscreen: Bool = false
    @Published var isURLBarEditing: Bool = false
}

@main
enum OraEntryPoint {
    @MainActor static func main() {
        #if DEBUG
            if PasswordBridgeDiagnostics.runIfRequested() {
                return
            }
            if ProcessInfo.processInfo.environment["ORA_PASSWORD_HELPER_PROBE"] == "1" {
                let application = NSApplication.shared
                application.setActivationPolicy(.prohibited)
                Task { @MainActor in
                    let connection = NativePasswordMessaging()
                    var result: String?
                    connection
                        .onDisconnect = { error in result = error?.localizedDescription ?? "Helper closed normally." }
                    do { try connection.start() } catch { result = error.localizedDescription }
                    for _ in 0 ..< 120 {
                        if result != nil {
                            break
                        }
                        try? await Task.sleep(nanoseconds: 25_000_000)
                    }
                    print(result ?? "Helper remained alive. No credential request was sent.")
                    if #available(macOS 15.4, *) {
                        print(PasswordExtensionRuntime.installationDirectory.path)
                    }
                    connection.close()
                    fflush(stdout)
                    exit(0)
                }
                application.run()
                return
            }
            if ProcessInfo.processInfo.environment["ORA_CSS_DIAGNOSTICS"] == "1" {
                print(BoostStore.shared.directory.path)
                return
            }
            if ProcessInfo.processInfo.environment["ORA_HEADLESS_TESTING"] == "1" {
                let application = NSApplication.shared
                application.setActivationPolicy(.prohibited)
                application.run()
                return
            }
        #endif
        OraApp.main()
    }
}

struct OraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Shared model container that uses the same configuration as the main browser
    private let sharedModelContainer: ModelContainer? =
        try? ModelConfiguration.createOraContainer(isPrivate: false)

    var body: some Scene {
        WindowGroup(id: "normal") {
            OraRoot()
                .frame(minWidth: 500, minHeight: 360)
                .environmentObject(DefaultBrowserManager.shared)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])

        WindowGroup("Private", id: "private") {
            OraRoot(isPrivate: true)
                .frame(minWidth: 500, minHeight: 360)
                .environmentObject(DefaultBrowserManager.shared)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])

        WindowGroup("Settings", id: "settings") {
            if let sharedModelContainer {
                SettingsWindowRoot()
                    .environmentObject(AppearanceManager.shared)
                    .environmentObject(UpdateService.shared)
                    .environmentObject(DefaultBrowserManager.shared)
                    .modelContainer(sharedModelContainer)
            } else {
                // Fallback UI when SwiftData is completely broken
                VStack {
                    Text("Settings Unavailable")
                        .font(.title)
                }
                .padding()
                .frame(width: 400, height: 300)
            }
        }
        .windowToolbarStyle(UnifiedCompactWindowToolbarStyle())
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 640)
        .commands { OraCommands() }
    }
}
