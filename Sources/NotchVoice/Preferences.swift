import Foundation

/// How the talk shortcut starts and ends a message to the orchestrator.
enum TalkMode: String, CaseIterable, Identifiable {
    /// Hold the keys while speaking; letting go sends.
    case hold
    /// Press once to start; a pause or a second press sends.
    case press

    var id: String { rawValue }
}

@MainActor
final class Preferences: ObservableObject {
    private static let themeKey = "glowTheme"
    private static let muteShortcutKey = "muteShortcut"
    private static let permissionsKey = "asksForPermissionInNotch"
    private static let menuBarKey = "showsSessionsInMenuBar"
    private static let wakePhraseKey = "listensForWakePhrase"
    private static let wakeNameKey = "wakeName"
    static let defaultWakeName = "Jarvis"
    private static let talkShortcutKey = "talkShortcut"
    private static let talkModeKey = "talkMode"

    @Published private(set) var theme: GlowTheme
    @Published private(set) var opensAtLogin: Bool
    @Published private(set) var muteShortcut: Shortcut?
    @Published private(set) var asksForPermission: Bool
    @Published private(set) var showsSessionsInMenuBar: Bool
    @Published private(set) var listensForWakePhrase: Bool
    /// The name in the wake phrase, "Hey <name>".
    @Published private(set) var wakeName: String
    @Published private(set) var talkShortcut: Shortcut?
    @Published private(set) var talkMode: TalkMode
    private let muteHotkey: Hotkey
    private let talkHotkey: Hotkey

    init(muteHotkey: Hotkey, talkHotkey: Hotkey) {
        theme = UserDefaults.standard.string(forKey: Self.themeKey).flatMap(GlowTheme.init(rawValue:)) ?? .aurora
        opensAtLogin = LoginItem.isEnabled
        asksForPermission = UserDefaults.standard.object(forKey: Self.permissionsKey) as? Bool ?? true
        showsSessionsInMenuBar = UserDefaults.standard.object(forKey: Self.menuBarKey) as? Bool ?? true
        listensForWakePhrase = UserDefaults.standard.bool(forKey: Self.wakePhraseKey)
        wakeName = TalkPhrases.cleanName(UserDefaults.standard.string(forKey: Self.wakeNameKey) ?? "") ?? Self.defaultWakeName
        talkMode = UserDefaults.standard.string(forKey: Self.talkModeKey).flatMap(TalkMode.init(rawValue:)) ?? .hold
        self.muteHotkey = muteHotkey
        self.talkHotkey = talkHotkey
        muteShortcut = Self.savedShortcut(Self.muteShortcutKey).flatMap { muteHotkey.register($0) ? $0 : nil }
        talkShortcut = Self.savedShortcut(Self.talkShortcutKey).flatMap { talkHotkey.register($0) ? $0 : nil }
    }

    func setListensForWakePhrase(_ listens: Bool) {
        listensForWakePhrase = listens
        UserDefaults.standard.set(listens, forKey: Self.wakePhraseKey)
    }

    /// Keeps a name that is one to three words of letters; anything else goes back to the default.
    func setWakeName(_ name: String) {
        wakeName = TalkPhrases.cleanName(name) ?? Self.defaultWakeName
        UserDefaults.standard.set(wakeName, forKey: Self.wakeNameKey)
    }

    func setTalkMode(_ mode: TalkMode) {
        talkMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.talkModeKey)
    }

    func setTalkShortcut(_ shortcut: Shortcut?) -> Bool {
        guard shortcut != muteShortcut || shortcut == nil, talkHotkey.register(shortcut) else { return false }
        talkShortcut = shortcut
        Self.save(shortcut, Self.talkShortcutKey)
        return true
    }

    func setTheme(_ theme: GlowTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
    }

    func setAsksForPermission(_ enabled: Bool) {
        asksForPermission = enabled
        UserDefaults.standard.set(enabled, forKey: Self.permissionsKey)
    }

    func setShowsSessionsInMenuBar(_ shown: Bool) {
        showsSessionsInMenuBar = shown
        UserDefaults.standard.set(shown, forKey: Self.menuBarKey)
    }

    func setOpensAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        refresh()
    }

    func setMuteShortcut(_ shortcut: Shortcut?) -> Bool {
        guard shortcut != talkShortcut || shortcut == nil, muteHotkey.register(shortcut) else { return false }
        muteShortcut = shortcut
        Self.save(shortcut, Self.muteShortcutKey)
        return true
    }

    /// Turns both shortcuts off while one is being recorded, so the keys reach the recorder instead of muting or
    /// starting to listen.
    func pauseShortcuts(_ paused: Bool) {
        _ = muteHotkey.register(paused ? nil : muteShortcut)
        _ = talkHotkey.register(paused ? nil : talkShortcut)
    }

    func refresh() {
        opensAtLogin = LoginItem.isEnabled
    }

    private static func savedShortcut(_ key: String) -> Shortcut? {
        guard let saved = UserDefaults.standard.dictionary(forKey: key),
              let keyCode = saved["keyCode"] as? UInt32,
              let modifiers = saved["modifiers"] as? UInt32 else { return nil }
        return Shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private static func save(_ shortcut: Shortcut?, _ key: String) {
        if let shortcut {
            UserDefaults.standard.set(["keyCode": shortcut.keyCode, "modifiers": shortcut.modifiers], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
