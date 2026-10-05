import AppKit
import SwiftUI

// swiftlint:disable identifier_name
struct Theme: Equatable {
    let colorScheme: ColorScheme
    var preferences: [String: PreferenceValue] = [:]

    private func color(_ role: String, scheme: ColorScheme? = nil, fallback: String) -> Color {
        let mode = (scheme ?? colorScheme) == .dark ? "dark" : "light"
        return Color(hex: preferences["theme.\(mode).\(role)"]?.text ?? fallback)
    }

    func metric(_ key: String, fallback: Double) -> CGFloat {
        CGFloat(preferences["theme.\(key)"]?.numeric ?? fallback)
    }

    var spacing: CGFloat {
        metric("spacing", fallback: 8)
    }

    var rowHeight: CGFloat {
        metric("rowHeight", fallback: 34)
    }

    var cornerRadius: CGFloat {
        metric("cornerRadius", fallback: 10)
    }

    var toolbarHeight: CGFloat {
        metric("toolbarHeight", fallback: 38)
    }

    var tintOpacity: Double {
        preferences["theme.tintOpacity"]?.numeric ?? 0.3
    }

    var textFont: Font {
        let design: Font.Design = switch preferences["theme.fontDesign"]?.text {
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        default: .default
        }
        return .system(size: metric("fontSize", fallback: 13), design: design)
    }

    var toolbarBackground: Color {
        color("toolbar", fallback: colorScheme == .dark ? "#262626" : "#e5e5e5")
    }

    var primary: Color {
        color("sidebar", scheme: .light, fallback: "#e5e5e5")
    }

    var primaryDark: Color {
        color("sidebar", scheme: .dark, fallback: "#262626")
    }

    var accent: Color {
        color("accent", fallback: colorScheme == .dark ? "#d4d4d4" : "#525252")
    }

    var background: Color {
        color("background", fallback: colorScheme == .dark ? "#171717" : "#fafafa")
    }

    var foreground: Color {
        color("foreground", fallback: colorScheme == .dark ? "#e5e5e5" : "#262626")
    }

    var subtleWindowBackgroundColor: Color {
        colorScheme == .dark ? self.primaryDark.opacity(tintOpacity) : self.primary.opacity(tintOpacity)
    }

    var solidWindowBackgroundColor: Color {
        colorScheme == .dark ? self.primaryDark : self.primary
    }

    var invertedSolidWindowBackgroundColor: Color {
        colorScheme == .dark ? self.primary : self.primaryDark
    }

    var activeTabBackground: Color {
        color("selectedTab", fallback: colorScheme == .dark ? "#404040" : "#d4d4d4")
    }

    var mutedBackground: Color {
        colorScheme == .dark ? .white.opacity(0.17) : self.primaryDark.opacity(0.1)
    }

    var popoverBackground: Color {
        toolbarBackground
    }

    var popoverMutedBackground: Color {
        colorScheme == .dark ? Color(hex: "#1d1d1d") : self.primaryDark.opacity(0.1)
    }

    var mutedForeground: Color {
        .secondary
    }

    var disabledBackground: Color {
        colorScheme == .dark ? .black.opacity(0.3) : .white.opacity(0.3)
    }

    var disabledForeground: Color {
        colorScheme == .dark ? .white.opacity(0.3) : Color(.disabledControlTextColor)
    }

    var launcherMainBackground: Color {
        colorScheme == .dark ? self.popoverBackground.opacity(0.75) : .white.opacity(0.8)
    }

    var placeholder: Color {
        Color(.placeholderTextColor)
    }

    var border: Color {
        Color(.separatorColor)
    }

    var destructive: Color {
        Color(hex: "#FF6969")
    }

    var success: Color {
        Color(hex: "#93DA97")
    }

    var warning: Color {
        Color(hex: "#FFBF78")
    }

    var info: Color {
        Color(hex: "#799EFF")
    }

    /// Search engine colors
    var grok: Color {
        colorScheme == .dark ? .white : .black
    }

    var claude: Color {
        Color(hex: "#d97757")
    }

    var openai: Color {
        colorScheme == .dark ? .white : .black
    }

    var t3chat: Color {
        Color(hex: "#960971")
    }

    var perplexity: Color {
        Color(hex: "#20808D")
    }

    var reddit: Color {
        Color(hex: "#FF4500")
    }

    var x: Color {
        colorScheme == .dark ? .white : .black
    }

    var google: Color {
        .blue
    }

    var youtube: Color {
        Color(hex: "#FC0D1B")
    }

    var github: Color {
        colorScheme == .dark ? .white : Color(hex: "#181717")
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(colorScheme: .light)  // fallback
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct ThemeProvider: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var customization = CustomizationStore.shared

    func body(content: Content) -> some View {
        let theme = Theme(colorScheme: colorScheme, preferences: customization.values)
        content.environment(\.theme, theme).font(theme.textFont).foregroundStyle(theme.foreground).tint(theme.accent)
    }
}
