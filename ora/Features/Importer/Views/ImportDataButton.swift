import SwiftUI

/// Lives in the macOS menu bar (`OraCommands`), which does not inherit `@EnvironmentObject`s
/// from any window's view hierarchy. Import actions are dispatched as notifications so the
/// actual work runs in the focused window, where TabManager et al. are actually available —
/// touching an `@EnvironmentObject` here directly would crash (see issue #99).
struct ImportDataButton: View {
    var body: some View {
        Menu("Import Data") {
            Button("Arc") {
                NotificationCenter.default.post(name: .importArcData, object: NSApp.keyWindow)
            }
            Button("Safari") {
                // importSafari()
            }
            Button("Chrome") {
                // importChrome()
            }
        }
    }
}
