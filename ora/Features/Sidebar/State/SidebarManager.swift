import Combine
import SwiftUI

enum SidebarPosition: String, Hashable {
    case primary
    case secondary
}

@MainActor
class SidebarManager: ObservableObject {
    @AppStorage("ui.sidebar.hidden") var isSidebarHidden: Bool = false
    @AppStorage("ui.sidebar.position") var sidebarPosition: SidebarPosition = .primary

    @Published var primaryFraction = FractionHolder.usingUserDefaults(0.2, key: "ui.sidebar.fraction.primary")
    @Published var secondaryFraction = FractionHolder.usingUserDefaults(0.2, key: "ui.sidebar.fraction.secondary")
    @Published var hiddenSidebar = SideHolder.usingUserDefaults(key: "ui.sidebar.visibility")

    private var preferenceObserver: AnyCancellable?

    init() {
        applyCustomizedLayout()
        preferenceObserver = NotificationCenter.default.publisher(for: .oraPreferencesChanged)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applyCustomizedLayout() } }
    }

    private func applyCustomizedLayout() {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: "ui.sidebar.fraction.primary") as? Double,
           primaryFraction.value != value
        {
            primaryFraction.value = value
        }
        if let value = defaults.object(forKey: "ui.sidebar.fraction.secondary") as? Double,
           secondaryFraction.value != value
        {
            secondaryFraction.value = value
        }
        let side: SplitSide? = isSidebarHidden ? (sidebarPosition == .primary ? .primary : .secondary) : nil
        if hiddenSidebar.side != side {
            hiddenSidebar.side = side
        }
        objectWillChange.send()
    }

    var currentFraction: FractionHolder {
        sidebarPosition == .primary ? primaryFraction : secondaryFraction
    }

    func updateSidebarHidden() {
        isSidebarHidden = hiddenSidebar.side == .primary || hiddenSidebar.side == .secondary
    }

    func toggleSidebar() {
        let targetSide = sidebarPosition == .primary ? SplitSide.primary : .secondary
        withAnimation(.spring(response: 0.2, dampingFraction: 1.0)) {
            hiddenSidebar.side = (hiddenSidebar.side == targetSide) ? nil : targetSide
            updateSidebarHidden()
        }
    }

    func toggleSidebarPosition() {
        let isCurrentSidebarHidden = hiddenSidebar.side == (sidebarPosition == .primary ? .primary : .secondary)
        sidebarPosition = sidebarPosition == .primary ? .secondary : .primary
        if isCurrentSidebarHidden {
            hiddenSidebar.side = sidebarPosition == .primary ? .primary : .secondary
        }
    }
}
