import Foundation

@MainActor
final class Preferences: ObservableObject {
    private static let themeKey = "glowTheme"
    private static let muteShortcutKey = "muteShortcut"

    @Published private(set) var theme: GlowTheme
    @Published private(set) var opensAtLogin: Bool
    @Published private(set) var muteShortcut: Shortcut?
    private let muteHotkey: Hotkey

    init(muteHotkey: Hotkey) {
        theme = UserDefaults.standard.string(forKey: Self.themeKey).flatMap(GlowTheme.init(rawValue:)) ?? .aurora
        opensAtLogin = LoginItem.isEnabled
        self.muteHotkey = muteHotkey
        muteShortcut = Self.savedMuteShortcut.flatMap { muteHotkey.register($0) ? $0 : nil }
    }

    func setTheme(_ theme: GlowTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
    }

    func setOpensAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        refresh()
    }

    func setMuteShortcut(_ shortcut: Shortcut?) -> Bool {
        guard muteHotkey.register(shortcut) else { return false }
        muteShortcut = shortcut
        if let shortcut {
            UserDefaults.standard.set(["keyCode": shortcut.keyCode, "modifiers": shortcut.modifiers], forKey: Self.muteShortcutKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.muteShortcutKey)
        }
        return true
    }

    func refresh() {
        opensAtLogin = LoginItem.isEnabled
    }

    private static var savedMuteShortcut: Shortcut? {
        guard let saved = UserDefaults.standard.dictionary(forKey: muteShortcutKey),
              let keyCode = saved["keyCode"] as? UInt32,
              let modifiers = saved["modifiers"] as? UInt32 else { return nil }
        return Shortcut(keyCode: keyCode, modifiers: modifiers)
    }
}
