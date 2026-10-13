import Foundation
import ServiceManagement

@MainActor
enum LoginItem {
    private static let configuredKey = "loginItemConfigured"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("NotchVoice: could not update the login item: \(error.localizedDescription)")
        }
    }

    static func enableOnFirstLaunch() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              !UserDefaults.standard.bool(forKey: configuredKey) else { return }
        setEnabled(true)
        UserDefaults.standard.set(true, forKey: configuredKey)
    }
}
