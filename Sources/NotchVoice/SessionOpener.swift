import AppKit
import os

private let log = Logger(subsystem: "local.notchvoice", category: "sessions")

/// Brings a session forward: the session itself in the Claude desktop app, its own tab in Terminal or iTerm2, otherwise
/// the app it runs in.
@MainActor
enum SessionOpener {
    static let terminal = "com.apple.Terminal"
    static let iTerm = "com.googlecode.iterm2"
    // Kept until it exits, so its termination handler runs.
    private static var runningScript: Process?

    static func canOpen(_ session: ClaudeSession) -> Bool {
        runningApp(of: session) != nil
    }

    static func open(_ session: ClaudeSession) {
        guard let app = runningApp(of: session), let appURL = app.bundleURL else { return }
        if let desktopID = session.desktopID, let link = desktopLink(desktopID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(link, configuration: configuration) { _, error in
                guard let error else { return }
                log.error("could not open the session in the Claude app: \(error.localizedDescription)")
                DispatchQueue.main.async { MainActor.assumeIsolated { activate(appURL) } }
            }
            return
        }
        guard let tty = session.tty, tty.hasPrefix("/dev/tty"), let script = tabScript(for: app.bundleIdentifier) else {
            return activate(appURL)
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        // The tty goes in as an argument rather than into the script, so nothing in a status file can change the script.
        process.arguments = ["-e", script, tty]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            let found = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "found"
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if SessionOpener.runningScript === process { SessionOpener.runningScript = nil }
                    guard !found else { return }
                    // Not found, or not allowed to control the terminal: bringing the app forward still helps.
                    log.info("no tab for the session (osascript exit \(status))")
                    activate(appURL)
                }
            }
        }
        do {
            try process.run()
            runningScript = process
        } catch {
            log.error("could not run osascript: \(error.localizedDescription)")
            activate(appURL)
        }
    }

    /// The link the Claude desktop app opens a session with, the same one its own session list hands out.
    static func desktopLink(_ desktopID: String) -> URL? {
        guard ClaudeSession.isDesktopID(desktopID) else { return nil }
        return URL(string: "claude://claude.ai/epitaxy/\(desktopID)")
    }

    static func tabScript(for bundleID: String?) -> String? {
        switch bundleID {
        case terminal:
            """
            on run argv
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is item 1 of argv then
                                set miniaturized of w to false
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                end tell
                return "missing"
            end run
            """
        case iTerm:
            """
            on run argv
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is item 1 of argv then
                                    select w
                                    select t
                                    select s
                                    activate
                                    return "found"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "missing"
            end run
            """
        default:
            nil
        }
    }

    private static func runningApp(of session: ClaudeSession) -> NSRunningApplication? {
        guard let app = session.app else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: app).first
    }

    private static func activate(_ appURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}
