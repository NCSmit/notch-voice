import Foundation

/// How the talk shortcut starts and ends a message to the orchestrator.
enum TalkMode: String, CaseIterable, Identifiable {
    /// Hold the keys while speaking; letting go sends.
    case hold
    /// Press once to start; a pause or a second press sends.
    case press

    var id: String { rawValue }
}

/// What writes out a spoken message to the orchestrator. "Hey Jarvis" and the end of a message are always heard by
/// Apple's recognizer, on this Mac.
enum Transcriber: String, CaseIterable, Identifiable {
    /// Apple's speech recognition, on this Mac.
    case apple
    /// Wispr Flow, when it's installed.
    case wisprFlow

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
    private static let skipShortcutKey = "skipShortcut"
    private static let talkModeKey = "talkMode"
    private static let transcriberKey = "transcriber"
    private static let pauseKey = "pauseBeforeSending"

    @Published private(set) var theme: GlowTheme
    @Published private(set) var opensAtLogin: Bool
    @Published private(set) var muteShortcut: Shortcut?
    @Published private(set) var asksForPermission: Bool
    @Published private(set) var showsSessionsInMenuBar: Bool
    @Published private(set) var listensForWakePhrase: Bool
    /// The name in the wake phrase, "Hey <name>".
    @Published private(set) var wakeName: String
    @Published private(set) var talkShortcut: Shortcut?
    @Published private(set) var skipShortcut: Shortcut?
    @Published private(set) var talkMode: TalkMode
    @Published private(set) var transcriber: Transcriber
    /// How long a pause sends a message said after "Hey Jarvis", or started by pressing the talk shortcut.
    @Published private(set) var pauseBeforeSending: TimeInterval
    /// Wispr Flow is installed, so it can be chosen to write out messages.
    @Published private(set) var hasWisprFlow: Bool
    private let muteHotkey: Hotkey
    private let talkHotkey: Hotkey
    private let skipHotkey: Hotkey

    init(muteHotkey: Hotkey, talkHotkey: Hotkey, skipHotkey: Hotkey) {
        theme = UserDefaults.standard.string(forKey: Self.themeKey).flatMap(GlowTheme.init(rawValue:)) ?? .aurora
        opensAtLogin = LoginItem.isEnabled
        asksForPermission = UserDefaults.standard.object(forKey: Self.permissionsKey) as? Bool ?? true
        showsSessionsInMenuBar = UserDefaults.standard.object(forKey: Self.menuBarKey) as? Bool ?? true
        listensForWakePhrase = UserDefaults.standard.bool(forKey: Self.wakePhraseKey)
        wakeName = TalkPhrases.cleanName(UserDefaults.standard.string(forKey: Self.wakeNameKey) ?? "") ?? Self.defaultWakeName
        talkMode = UserDefaults.standard.string(forKey: Self.talkModeKey).flatMap(TalkMode.init(rawValue:)) ?? .hold
        transcriber = UserDefaults.standard.string(forKey: Self.transcriberKey).flatMap(Transcriber.init(rawValue:)) ?? .apple
        hasWisprFlow = WisprFlow.isAvailable
        pauseBeforeSending = TalkPolicy.pause(UserDefaults.standard.object(forKey: Self.pauseKey) as? Double ?? TalkPolicy.defaultPause)
        self.muteHotkey = muteHotkey
        self.talkHotkey = talkHotkey
        self.skipHotkey = skipHotkey
        muteShortcut = Self.savedShortcut(Self.muteShortcutKey).flatMap { muteHotkey.register($0) ? $0 : nil }
        talkShortcut = Self.savedShortcut(Self.talkShortcutKey).flatMap { talkHotkey.register($0) ? $0 : nil }
        skipShortcut = Self.savedShortcut(Self.skipShortcutKey).flatMap { skipHotkey.register($0) ? $0 : nil }
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

    func setTranscriber(_ transcriber: Transcriber) {
        self.transcriber = transcriber
        UserDefaults.standard.set(transcriber.rawValue, forKey: Self.transcriberKey)
    }

    func setPauseBeforeSending(_ seconds: TimeInterval) {
        pauseBeforeSending = TalkPolicy.pause(seconds)
        UserDefaults.standard.set(pauseBeforeSending, forKey: Self.pauseKey)
    }

    func setTalkShortcut(_ shortcut: Shortcut?) -> Bool {
        guard !isTaken(shortcut, besides: talkShortcut), talkHotkey.register(shortcut) else { return false }
        talkShortcut = shortcut
        Self.save(shortcut, Self.talkShortcutKey)
        return true
    }

    func setSkipShortcut(_ shortcut: Shortcut?) -> Bool {
        guard !isTaken(shortcut, besides: skipShortcut), skipHotkey.register(shortcut) else { return false }
        skipShortcut = shortcut
        Self.save(shortcut, Self.skipShortcutKey)
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
        guard !isTaken(shortcut, besides: muteShortcut), muteHotkey.register(shortcut) else { return false }
        muteShortcut = shortcut
        Self.save(shortcut, Self.muteShortcutKey)
        return true
    }

    /// Turns both shortcuts off while one is being recorded, so the keys reach the recorder instead of muting or
    /// starting to listen.
    func pauseShortcuts(_ paused: Bool) {
        _ = muteHotkey.register(paused ? nil : muteShortcut)
        _ = talkHotkey.register(paused ? nil : talkShortcut)
        _ = skipHotkey.register(paused ? nil : skipShortcut)
    }

    private func isTaken(_ shortcut: Shortcut?, besides own: Shortcut?) -> Bool {
        Self.isTaken(shortcut, besides: own, among: [muteShortcut, talkShortcut, skipShortcut])
    }

    /// Whether another of NotchVoice's own shortcuts already uses these keys. Keeping the keys it already has is fine.
    nonisolated static func isTaken(_ shortcut: Shortcut?, besides own: Shortcut?, among shortcuts: [Shortcut?]) -> Bool {
        guard let shortcut, shortcut != own else { return false }
        return shortcuts.contains(shortcut)
    }

    func refresh() {
        opensAtLogin = LoginItem.isEnabled
        hasWisprFlow = WisprFlow.isAvailable
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
