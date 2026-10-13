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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAlreadyRunning {
            NSApp.terminate(nil)
            return
        }
        notch = NotchController(voice: VoiceController())
        LoginItem.enableOnFirstLaunch()
    }

    private var isAlreadyRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0 != .current }
    }
}
