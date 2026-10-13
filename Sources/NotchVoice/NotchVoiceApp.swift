import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAlreadyRunning {
            NSApp.terminate(nil)
            return
        }
        let voice = VoiceController()
        let preferences = Preferences()
        let settings = SettingsWindowController(voice: voice, preferences: preferences)
        self.settings = settings
        notch = NotchController(voice: voice, preferences: preferences) { settings.show() }
        NSApp.mainMenu = makeMainMenu()
        LoginItem.enableOnFirstLaunch()
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
