import Foundation

@MainActor
final class Preferences: ObservableObject {
    private static let themeKey = "glowTheme"
    private static let muteShortcutKey = "muteShortcut"
    private static let skipShortcutKey = "skipShortcut"
    private static let skipAllShortcutKey = "skipAllShortcut"
    private static let permissionsKey = "asksForPermissionInNotch"
    private static let pinnedKey = "keepsPanelOpen"
    private static let wakeWordKey = "listensForWakeWord"
    private static let headphonesKey = "listensThroughHeadphones"
    private static let musicRuleKey = "skipsHeadphonesDuringMusic"
    private static let phrasesKey = "voicePhrases"
    private static let awayDelayKey = "awayDelaySeconds"

    @Published private(set) var theme: GlowTheme
    @Published private(set) var opensAtLogin: Bool
    @Published private(set) var muteShortcut: Shortcut?
    @Published private(set) var skipShortcut: Shortcut?
    @Published private(set) var skipAllShortcut: Shortcut?
    private var skipHotkey: Hotkey?
    private var skipAllHotkey: Hotkey?
    @Published private(set) var asksForPermission: Bool
    /// Once opened, the notch panel stays open until it is unpinned, instead of collapsing when the mouse leaves.
    @Published private(set) var isPanelPinned: Bool
    /// Listen on-device for "Hey orchestrator" to dictate a message to the orchestrator session hands-free.
    @Published private(set) var listensForWakeWord: Bool
    /// When the user is away from the Mac, listen for the wake word through the AirPods' mic (call-quality audio).
    @Published private(set) var listensThroughHeadphones: Bool
    /// …but not while Spotify or Apple Music is playing, so music keeps full quality.
    @Published private(set) var skipsHeadphonesDuringMusic: Bool
    /// The spoken commands; changes apply to the next thing heard.
    @Published private(set) var phrases: VoicePhrases
    /// How long without keyboard or mouse use counts as away (then the AirPods mic takes over).
    @Published private(set) var awayDelay: TimeInterval
    static let awayDelayRange: ClosedRange<TimeInterval> = 30...900
    private let muteHotkey: Hotkey

    init(muteHotkey: Hotkey) {
        theme = UserDefaults.standard.string(forKey: Self.themeKey).flatMap(GlowTheme.init(rawValue:)) ?? .aurora
        opensAtLogin = LoginItem.isEnabled
        asksForPermission = UserDefaults.standard.object(forKey: Self.permissionsKey) as? Bool ?? true
        isPanelPinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)
        listensForWakeWord = UserDefaults.standard.bool(forKey: Self.wakeWordKey)
        listensThroughHeadphones = UserDefaults.standard.bool(forKey: Self.headphonesKey)
        skipsHeadphonesDuringMusic = UserDefaults.standard.object(forKey: Self.musicRuleKey) as? Bool ?? true
        let savedPhrases = UserDefaults.standard.data(forKey: Self.phrasesKey).flatMap { try? JSONDecoder().decode(VoicePhrases.self, from: $0) }
        let usable = savedPhrases.flatMap { $0.problem == nil ? $0 : nil } ?? .defaults
        phrases = usable
        VoicePhrases.current = usable
        let delay = UserDefaults.standard.object(forKey: Self.awayDelayKey) as? Double ?? 120
        awayDelay = min(max(delay, Self.awayDelayRange.lowerBound), Self.awayDelayRange.upperBound)
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

    /// Saves the phrases if they're usable; otherwise returns what's wrong and keeps the old ones.
    func setPhrases(_ new: VoicePhrases) -> String? {
        if let problem = new.problem { return problem }
        phrases = new
        VoicePhrases.current = new
        UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: Self.phrasesKey)
        return nil
    }

    func setAwayDelay(_ seconds: TimeInterval) {
        awayDelay = min(max(seconds, Self.awayDelayRange.lowerBound), Self.awayDelayRange.upperBound)
        UserDefaults.standard.set(awayDelay, forKey: Self.awayDelayKey)
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

    /// Shortcuts that skip the reply being read aloud, or it and everything queued after it.
    func attachSkipHotkeys(skip: Hotkey, skipAll: Hotkey) {
        skipHotkey = skip
        skipAllHotkey = skipAll
        skipShortcut = Self.saved(Self.skipShortcutKey).flatMap { skip.register($0) ? $0 : nil }
        skipAllShortcut = Self.saved(Self.skipAllShortcutKey).flatMap { skipAll.register($0) ? $0 : nil }
    }

    func setSkipShortcut(_ shortcut: Shortcut?) -> Bool {
        guard skipHotkey?.register(shortcut) ?? false else { return false }
        skipShortcut = shortcut
        Self.save(shortcut, Self.skipShortcutKey)
        return true
    }

    func setSkipAllShortcut(_ shortcut: Shortcut?) -> Bool {
        guard skipAllHotkey?.register(shortcut) ?? false else { return false }
        skipAllShortcut = shortcut
        Self.save(shortcut, Self.skipAllShortcutKey)
        return true
    }

    func pauseSkipShortcuts(_ paused: Bool) {
        _ = skipHotkey?.register(paused ? nil : skipShortcut)
        _ = skipAllHotkey?.register(paused ? nil : skipAllShortcut)
    }

    private static func saved(_ key: String) -> Shortcut? {
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
