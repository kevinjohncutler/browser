import AppKit
import Combine
@preconcurrency import WebKit

@available(macOS 15.4, *)
@MainActor
final class PasswordExtensionRuntime: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    static let shared = PasswordExtensionRuntime()
    static var installationDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("OraDev/Extensions/ApplePasswords", isDirectory: true)
    }

    let controller: WKWebExtensionController
    @Published private(set) var status = "Apple Passwords extension is not installed."
    private(set) var context: WKWebExtensionContext?
    private var windows: [PasswordExtensionWindow] = []
    private var connections: [UUID: any PasswordMessageConnection] = [:]
    private var popup: NSPopover?
    private var loading = false
    private let makeNativeConnection: () -> any PasswordMessageConnection

    init(persistent: Bool = true, makeNativeConnection: (@MainActor () -> any PasswordMessageConnection)? = nil) {
        controller = WKWebExtensionController(configuration: persistent ? .default() : .nonPersistent())
        self.makeNativeConnection = makeNativeConnection ?? { LocalPasswordMessaging() }
        super.init()
        controller.delegate = self
    }

    func configure(_ configuration: WKWebViewConfiguration, isPrivate: Bool) {
        guard !isPrivate else { return }
        configuration.webExtensionController = controller
    }

    func startIfInstalled() {
        guard SettingsStore.shared.passwordManagerProvider == .applePasswords, context == nil, !loading,
              FileManager.default
              .fileExists(atPath: Self.installationDirectory.appendingPathComponent("manifest.json").path)
        else { return }
        Task { do { try await load(from: Self.installationDirectory) } catch { status = error.localizedDescription } }
    }

    func load(from directory: URL, identifier: String = NativePasswordMessaging.extensionIdentifier) async throws {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if context != nil {
            shutdown()
        }
        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        guard webExtension.manifestVersion == 3 else { throw CocoaError(.fileReadCorruptFile) }
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = identifier
        guard let baseURL = URL(string: "chrome-extension://\(identifier)/")
        else { throw CocoaError(.fileReadCorruptFile) }
        context.baseURL = baseURL
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(
                .grantedExplicitly,
                for: permission
            )
        }
        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(
                .grantedExplicitly,
                for: pattern
            )
        }
        try controller.load(context)
        self.context = context
        for window in windows {
            controller.didOpenWindow(window)
        }
        status = "Extension loaded. Waiting for Apple's password helper."
        var completion: Swift.Result<Void, Error>?
        context.loadBackgroundContent { error in
            completion = error.map { .failure($0) } ?? .success(())
        }
        for _ in 0 ..< 200 {
            if let completion {
                try completion.get()
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw NSError(
            domain: "OraPasswordExtension",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: "Apple Passwords background did not start: \(context.errors.map(\.localizedDescription).joined(separator: "; "))"
            ]
        )
    }

    func attach(_ webView: WKWebView) -> PasswordExtensionTab {
        let tab = PasswordExtensionTab(webView: webView, runtime: self)
        let window = PasswordExtensionWindow()
        window.items = [tab]
        tab.owner = window
        windows.append(window)
        controller.didOpenWindow(window)
        return tab
    }

    func detach(_ tab: PasswordExtensionTab) {
        controller.didCloseTab(tab, windowIsClosing: true)
        if let window = tab.owner {
            controller.didCloseWindow(window)
            windows.removeAll { $0 === window }
        }
    }

    func activate(_ tab: PasswordExtensionTab) {
        guard let window = tab.owner else { return }
        windows.removeAll { $0 === window }
        windows.insert(window, at: 0)
        controller.didFocusWindow(window)
        controller.didActivateTab(tab, previousActiveTab: nil)
    }

    func changed(_ tab: PasswordExtensionTab) {
        controller.didChangeTabProperties([.URL, .title, .loading], for: tab)
    }

    func showAction() {
        guard let context else { return }
        context.performAction(for: windows.first?.items.first)
    }

    func shutdown() {
        for connection in Array(connections.values) {
            connection.close()
        }
        connections.removeAll()
        if let context {
            try? controller.unload(context)
        }
        context = nil
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        windows
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        windows.first
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard port.applicationIdentifier == NativePasswordMessaging.applicationIdentifier,
              context === self.context
        else {
            completionHandler(NSError(
                domain: "OraPasswordHelper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "This extension cannot connect to the requested application."]
            ))
            return
        }
        let id = UUID()
        let connection = makeNativeConnection()
        connections[id] = connection
        port.messageHandler = { [weak connection] message, error in
            guard error == nil, let message else { return }
            do { try connection?.send(message) } catch { port.disconnect() }
        }
        port.disconnectHandler = { [weak self] _ in self?.connections.removeValue(forKey: id)?.close() }
        connection.onMessage = { [weak self] message in
            self?.status = "Connected to Apple's password helper."
            port.sendMessage(message) {
                error in if error != nil {
                    port.disconnect()
                }
            }
        }
        connection.onDisconnect = { [weak self] error in
            self?.status = error?.localizedDescription ?? "Apple Passwords helper disconnected."
            port.disconnect()
            self?.connections.removeValue(forKey: id)
        }
        do { try connection.start()
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard ProcessInfo.processInfo.environment["ORA_HEADLESS_TESTING"] != "1",
              let view = action.popupWebView,
              let tab = action.associatedTab as? PasswordExtensionTab,
              let anchor = tab.view, anchor.window != nil
        else {
            completionHandler(NSError(
                domain: "OraPasswordHelper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The password popup needs an active browser window."]
            ))
            return
        }
        let host = NSViewController()
        host.view = view
        let popover = NSPopover()
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 360, height: 400)
        popover.behavior = .transient
        popover.show(
            relativeTo: NSRect(x: 12, y: anchor.bounds.height - 1, width: 1, height: 1),
            of: anchor,
            preferredEdge: .minY
        )
        popup = popover
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
final class PasswordExtensionWindow: NSObject, WKWebExtensionWindow {
    var items: [PasswordExtensionTab] = []
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        items
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        items.first
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        items.first?.view?.window?.frame ?? .zero
    }
}

@available(macOS 15.4, *)
@MainActor
final class PasswordExtensionTab: NSObject, WKWebExtensionTab {
    weak var view: WKWebView?
    weak var runtime: PasswordExtensionRuntime?
    weak var owner: PasswordExtensionWindow?
    init(webView: WKWebView, runtime: PasswordExtensionRuntime) {
        view = webView
        self.runtime = runtime
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        view
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        owner
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        view?.isLoading == false
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        runtime?.activate(self)
        if ProcessInfo.processInfo
            .environment["ORA_HEADLESS_TESTING"] != "1"
        {
            view?.window?.makeKeyAndOrderFront(nil)
        }
        completionHandler(nil)
    }
}
