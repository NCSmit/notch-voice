import AppKit
import Combine

@main
@MainActor
enum NotchVoiceApp {
    private static let delegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains("--unregister-login-item") {
            LoginItem.setEnabled(false)
            return
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?
    private var settings: SettingsWindowController?
    private var permissions: PermissionCenter?
    private var sessions: SessionStore?
    private var statusItem: StatusItemController?
    private var dictation: DictationMonitor?
    private var talk: TalkController?
    private var questions: QuestionCenter?
    private var questionSetting: AnyCancellable?
    private var dictationChanges: AnyCancellable?
    private var permissionSetting: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAlreadyRunning {
            NSApp.terminate(nil)
            return
        }
        let voice = VoiceController()
        let muteHotkey = Hotkey { [weak self] in
            voice.setEnabled(!voice.isEnabled)
            self?.notch?.flash()
        }
        let talkHotkey = Hotkey(
            action: { [weak self] in self?.talk?.shortcutPressed() },
            release: { [weak self] in self?.talk?.shortcutReleased() }
        )
        let skipHotkey = Hotkey { voice.skip(all: false) }
        let preferences = Preferences(muteHotkey: muteHotkey, talkHotkey: talkHotkey, skipHotkey: skipHotkey)
        let dictation = DictationMonitor()
        dictationChanges = dictation.$isDictating.sink { dictating in
            MainActor.assumeIsolated { voice.setDictating(dictating) }
        }
        dictation.start()
        self.dictation = dictation
        let permissions = PermissionCenter()
        permissions.isEnabled = { preferences.asksForPermission }
        permissionSetting = preferences.$asksForPermission.dropFirst().filter { !$0 }.sink { _ in
            MainActor.assumeIsolated { permissions.handBackAll() }
        }
        permissions.start()
        self.permissions = permissions
        let sessions = SessionStore()
        sessions.start()
        self.sessions = sessions
        let talk = TalkController(sessions: sessions, voice: voice, preferences: preferences, dictation: dictation)
        self.talk = talk
        let questions = QuestionCenter()
        questions.isEnabled = { preferences.answersQuestions }
        questionSetting = preferences.$answersQuestions.dropFirst().filter { !$0 }.sink { _ in
            MainActor.assumeIsolated { questions.handBackAll() }
        }
        questions.start()
        self.questions = questions
        let settings = SettingsWindowController(voice: voice, preferences: preferences)
        self.settings = settings
        notch = NotchController(voice: voice, preferences: preferences, permissions: permissions, talk: talk, questions: questions,
                                sessions: sessions) { settings.show() }
        statusItem = StatusItemController(sessions: sessions, voice: voice, preferences: preferences) { settings.show() }
        NSApp.mainMenu = makeMainMenu()
        LoginItem.enableOnFirstLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Wispr Flow may still be about to paste a message's text, which would land in another app once NotchVoice
        // is gone, so quitting waits for that, a few seconds at most.
        let waits = talk?.prepareToQuit { NSApp.reply(toApplicationShouldTerminate: true) } ?? false
        return waits ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.stop()
    }

    @objc private func showSettings() {
        settings?.show()
    }

    private var isAlreadyRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0 != .current }
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit NotchVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
