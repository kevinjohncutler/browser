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
    private var helperReady = false
    private var startupUnlockPending = false
    private var startupUnlockTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var appearanceObserver: NSKeyValueObservation?
    private weak var popupWebView: WKWebView?
    private let automaticallyUnlock: Bool
    private let automaticallyPair: Bool
    private let pairingPreferenceOverride: Bool?
    private let popupPresenter: ((WKWebExtension.Action) -> Void)?
    private let makeNativeConnection: () -> any PasswordMessageConnection

    init(
        persistent: Bool = true,
        automaticallyUnlock: Bool? = nil,
        automaticallyPair: Bool? = nil,
        popupPresenter: ((WKWebExtension.Action) -> Void)? = nil,
        makeNativeConnection: (@MainActor () -> any PasswordMessageConnection)? = nil
    ) {
        controller = WKWebExtensionController(configuration: persistent ? .default() : .nonPersistent())
        self.automaticallyUnlock = automaticallyUnlock ??
            (persistent && ProcessInfo.processInfo.environment["ORA_HEADLESS_TESTING"] != "1")
        self.automaticallyPair = automaticallyPair ??
            (persistent && ProcessInfo.processInfo.environment["ORA_HEADLESS_TESTING"] != "1")
        self.pairingPreferenceOverride = automaticallyPair
        self.popupPresenter = popupPresenter
        self.makeNativeConnection = makeNativeConnection ?? { LocalPasswordMessaging() }
        super.init()
        controller.delegate = self
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updatePopupAppearance() }
        }
    }

    func configure(_ configuration: WKWebViewConfiguration, isPrivate: Bool) {
        guard !isPrivate else { return }
        configuration.webExtensionController = controller
    }

    func startIfInstalled() {
        guard SettingsStore.shared.passwordsEnabled, SettingsStore.shared.passwordAutofillEnabled,
              SettingsStore.shared.passwordManagerProvider == .applePasswords, context == nil, !loading,
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
        if identifier == NativePasswordMessaging.extensionIdentifier {
            try ApplePasswordCompatibility.prepare(directory: directory)
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
        startupUnlockPending = automaticallyUnlock
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
        scheduleStartupUnlock()
    }

    func changed(_ tab: PasswordExtensionTab) {
        controller.didChangeTabProperties([.URL, .title, .loading], for: tab)
    }

    func showAction() {
        if let popup, popup.isShown {
            popup.contentViewController?.view.window?.makeKey()
            if let view = popupWebView {
                pairAutomatically(in: view)
            }
            return
        }
        guard let context else { startIfInstalled()
            return
        }
        context.performAction(for: windows.first?.items.first)
    }

    private func scheduleStartupUnlock() {
        guard startupUnlockPending, helperReady, context != nil, startupUnlockTask == nil else { return }
        startupUnlockTask = Task { [weak self] in
            defer { self?.startupUnlockTask = nil }
            // Tab activation can precede the SwiftUI host attaching its content view to the window.
            for _ in 0 ..< 200 {
                guard let self, !Task.isCancelled, startupUnlockPending else { return }
                if let tab = windows.first?.items.first,
                   popupPresenter != nil || tab.view?.window?.isVisible == true
                {
                    startupUnlockPending = false
                    showAction()
                    return
                }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
        }
    }

    func shutdown() {
        pairingTask?.cancel()
        pairingTask = nil
        popupWebView = nil
        startupUnlockTask?.cancel()
        startupUnlockTask = nil
        startupUnlockPending = false
        helperReady = false
        popup?.close()
        popup = nil
        for connection in Array(connections.values) {
            connection.close()
        }
        connections.removeAll()
        if let context {
            try? controller.unload(context)
        }
        context = nil
    }

    func lock() async {
        pairingTask?.cancel()
        if let connection = connections.values.first {
            await connection.endSession()
        }
        shutdown()
        status = "Apple Passwords pairing cleared. Unlock to start a new session."
    }

    private func updatePopupAppearance() {
        // Extension popovers can have an independent light appearance without an explicit update.
        popupWebView?.appearance = NSApp.effectiveAppearance
        popup?.appearance = NSApp.effectiveAppearance
    }

    private func pairAutomatically(in view: WKWebView) {
        guard automaticallyPair, pairingTask == nil,
              pairingPreferenceOverride ?? UserDefaults.standard.bool(forKey: "passwords.apple.automaticPairing")
        else { return }
        pairingTask = Task { [weak self, weak view] in
            defer { self?.pairingTask = nil }
            for _ in 0 ..< 240 {
                guard let self, let view, !Task.isCancelled else { return }
                guard pairingPreferenceOverride ?? UserDefaults.standard
                    .bool(forKey: "passwords.apple.automaticPairing") else { return }
                // Wait for Apple's reply to the challenge before entering any code.
                if await (try? view.evaluateJavaScript("window.oraCanSubmitPairingCode?.() === true")) as? Bool ==
                    true
                {
                    guard let connection = connections.values.first else { return }
                    do {
                        let code = try await connection.readPairingCode()
                        guard !Task.isCancelled, popupWebView === view,
                              pairingPreferenceOverride ?? UserDefaults.standard
                              .bool(forKey: "passwords.apple.automaticPairing") else { return }
                        let submitted = try await view.callAsyncJavaScript(
                            "return window.oraSubmitPairingCode(code)", arguments: ["code": code],
                            in: nil, contentWorld: .page
                        ) as? Bool == true
                        // Submission is not proof that Apple's encrypted handshake succeeded.
                        status = submitted ? "Pairing code entered. Waiting for Apple Passwords." :
                            "Automatic code entry paused because the pairing form changed."
                    } catch { status = error.localizedDescription }
                    return
                }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
        }
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
            if (message as? [String: Any])?["cmd"] as? Int == 14 {
                self?.helperReady = true
                if (message as? [String: Any])?["oraRetainedSession"] != nil {
                    self?.startupUnlockPending = false
                    self?.status = "Apple Passwords pairing restored. Apple authenticates saved credential access."
                }
                self?.scheduleStartupUnlock()
            }
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
        // Keep WebKit's own lifecycle, but do not dismiss pairing on browser or system-dialog clicks.
        let popover = action.popupPopover
        popover?.behavior = .applicationDefined
        popover?.animates = false
        popupWebView = action.popupWebView
        popover?.appearance = NSApp.effectiveAppearance
        updatePopupAppearance()
        if let view = action.popupWebView {
            pairAutomatically(in: view)
        }
        if let popupPresenter {
            popupPresenter(action)
            completionHandler(nil)
            return
        }
        guard ProcessInfo.processInfo.environment["ORA_HEADLESS_TESTING"] != "1",
              let popover,
              let tab = (action.associatedTab as? PasswordExtensionTab) ?? windows.first?.items.first,
              let anchor = tab.view, anchor.window != nil
        else {
            completionHandler(NSError(
                domain: "OraPasswordHelper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The password popup needs an active browser window."]
            ))
            return
        }
        popup?.close()
        popover.show(
            relativeTo: NSRect(
                x: anchor.bounds.minX + 12,
                y: anchor.isFlipped ? anchor.bounds.minY : anchor.bounds.maxY - 1,
                width: 1, height: 1
            ),
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
