import Foundation

@MainActor
final class Preferences: ObservableObject {
    private static let themeKey = "glowTheme"
    private static let muteShortcutKey = "muteShortcut"
    private static let permissionsKey = "asksForPermissionInNotch"
    private static let pinnedKey = "keepsPanelOpen"
    private static let wakeWordKey = "listensForWakeWord"
    private static let headphonesKey = "listensThroughHeadphones"
    private static let musicRuleKey = "skipsHeadphonesDuringMusic"

    @Published private(set) var theme: GlowTheme
    @Published private(set) var opensAtLogin: Bool
    @Published private(set) var muteShortcut: Shortcut?
    @Published private(set) var asksForPermission: Bool
    /// Once opened, the notch panel stays open until it is unpinned, instead of collapsing when the mouse leaves.
    @Published private(set) var isPanelPinned: Bool
    /// Listen on-device for "Hey orchestrator" to dictate a message to the orchestrator session hands-free.
    @Published private(set) var listensForWakeWord: Bool
    /// When the user is away from the Mac, listen for the wake word through the AirPods' mic (call-quality audio).
    @Published private(set) var listensThroughHeadphones: Bool
    /// …but not while Spotify or Apple Music is playing, so music keeps full quality.
    @Published private(set) var skipsHeadphonesDuringMusic: Bool
    private let muteHotkey: Hotkey

    init(muteHotkey: Hotkey) {
        theme = UserDefaults.standard.string(forKey: Self.themeKey).flatMap(GlowTheme.init(rawValue:)) ?? .aurora
        opensAtLogin = LoginItem.isEnabled
        asksForPermission = UserDefaults.standard.object(forKey: Self.permissionsKey) as? Bool ?? true
        isPanelPinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)
        listensForWakeWord = UserDefaults.standard.bool(forKey: Self.wakeWordKey)
        listensThroughHeadphones = UserDefaults.standard.bool(forKey: Self.headphonesKey)
        skipsHeadphonesDuringMusic = UserDefaults.standard.object(forKey: Self.musicRuleKey) as? Bool ?? true
        self.muteHotkey = muteHotkey
        muteShortcut = Self.savedMuteShortcut.flatMap { muteHotkey.register($0) ? $0 : nil }
    }

    func setTheme(_ theme: GlowTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
    }

    func setAsksForPermission(_ enabled: Bool) {
        asksForPermission = enabled
        UserDefaults.standard.set(enabled, forKey: Self.permissionsKey)
    }

    func setPanelPinned(_ pinned: Bool) {
        isPanelPinned = pinned
        UserDefaults.standard.set(pinned, forKey: Self.pinnedKey)
    }

    func setListensForWakeWord(_ enabled: Bool) {
        listensForWakeWord = enabled
        UserDefaults.standard.set(enabled, forKey: Self.wakeWordKey)
    }

    func setListensThroughHeadphones(_ enabled: Bool) {
        listensThroughHeadphones = enabled
        UserDefaults.standard.set(enabled, forKey: Self.headphonesKey)
    }

    func setSkipsHeadphonesDuringMusic(_ enabled: Bool) {
        skipsHeadphonesDuringMusic = enabled
        UserDefaults.standard.set(enabled, forKey: Self.musicRuleKey)
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

    func pauseMuteShortcut(_ paused: Bool) {
        _ = muteHotkey.register(paused ? nil : muteShortcut)
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
