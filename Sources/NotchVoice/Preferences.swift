import Foundation

@MainActor
final class Preferences: ObservableObject {
    private static let themeKey = "glowTheme"

    @Published private(set) var theme: GlowTheme
    @Published private(set) var opensAtLogin: Bool

    init() {
        theme = UserDefaults.standard.string(forKey: Self.themeKey).flatMap(GlowTheme.init(rawValue:)) ?? .aurora
        opensAtLogin = LoginItem.isEnabled
    }

    func setTheme(_ theme: GlowTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
    }

    func setOpensAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        refresh()
    }

    func refresh() {
        opensAtLogin = LoginItem.isEnabled
    }
}
