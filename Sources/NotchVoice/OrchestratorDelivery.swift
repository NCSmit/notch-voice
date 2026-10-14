import AppKit
import ApplicationServices
import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "delivery")

/// Types a dictated message into the orchestrator session as a real user turn.
///
/// There is no supported way to inject a user message into a running session, so this does what a person would:
/// - Terminal.app / iTerm2: their AppleScript writes into the session's tab by tty, without changing focus.
/// - Claude desktop app: open the session by its link (focuses its message box), paste, press Return, then put the
///   clipboard and the previously active app back.
@MainActor
enum OrchestratorDelivery {
    enum Failure: Error, CustomStringConvertible {
        case noOrchestrator, sessionGone, needsAccessibility, unsupportedTerminal(String), scriptFailed(String)

        var description: String {
            switch self {
            case .noOrchestrator: "No orchestrator yet. Run /orchestrator in a session."
            case .sessionGone: "The orchestrator session isn't running any more."
            case .needsAccessibility: "Allow NotchVoice in System Settings › Privacy & Security › Accessibility, then try again."
            case .unsupportedTerminal(let app): "Can't type into \(app) from outside. Copy the text in by hand."
            case .scriptFailed(let message): "Couldn't reach the orchestrator's terminal: \(message)"
            }
        }
    }

    struct Target {
        let pid: pid_t
        let isDesktop: Bool
        let desktopSessionID: String?
    }

    static let orchestratorFile = URL.homeDirectory.appending(path: ".claude/notchvoice/orchestrator.json")
    static let sessionMap = URL.homeDirectory.appending(path: ".claude/sessions")
    private static let claudeBundleID = "com.anthropic.claudefordesktop"

    static func target() throws -> Target {
        guard let data = try? Data(contentsOf: orchestratorFile),
              let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["session_id"] as? String
        else { throw Failure.noOrchestrator }
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionMap, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  json["sessionId"] as? String == id, let pid = json["pid"] as? Int,
                  kill(pid_t(pid), 0) == 0 || errno == EPERM else { continue }
            return Target(
                pid: pid_t(pid),
                isDesktop: json["entrypoint"] as? String == "claude-desktop",
                desktopSessionID: json["hostSessionId"] as? String
            )
        }
        throw Failure.sessionGone
    }

    static func deliver(_ text: String, returnTo previous: NSRunningApplication?) async throws {
        let target = try target()
        if target.isDesktop, let session = target.desktopSessionID {
            try await pasteIntoDesktop(text, session: session, returnTo: previous)
        } else {
            try typeIntoTerminal(text, pid: target.pid)
            previous?.activate()
        }
        log.info("delivered a dictated message to the orchestrator")
    }

    // MARK: Desktop app

    private static func pasteIntoDesktop(_ text: String, session: String, returnTo previous: NSRunningApplication?) async throws {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // kAXTrustedCheckOptionPrompt
        guard AXIsProcessTrustedWithOptions(options) else { throw Failure.needsAccessibility }
        guard let link = URL(string: "claude://claude.ai/epitaxy/\(session)") else { throw Failure.sessionGone }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        NSWorkspace.shared.open(link)
        // Wait for the app to come forward with the session's message box focused.
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != claudeBundleID {
            try await Task.sleep(for: .milliseconds(50))
        }
        // The session view needs a moment to focus its message box after coming forward.
        try await Task.sleep(for: .milliseconds(250))
        press(key: 9, flags: .maskCommand)  // V
        try await Task.sleep(for: .milliseconds(120))
        press(key: 36, flags: [])  // Return
        try await Task.sleep(for: .milliseconds(200))

        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        if let previous, previous.bundleIdentifier != claudeBundleID { previous.activate() }
    }

    private static func press(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Terminal

    private static func typeIntoTerminal(_ text: String, pid: pid_t) throws {
        guard let tty = ttyOf(pid) else { throw Failure.sessionGone }
        let host = hostApp(of: pid)
        // Return sends in Claude Code, so a multi-line dictation goes in as one line.
        let line = text.replacingOccurrences(of: "\\s*\\n+\\s*", with: " ", options: .regularExpression)
        let quoted = "\"" + line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let script: String
        switch host {
        case "Terminal":
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            do script \(quoted) in t
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        case "iTerm2":
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                tell s to write text \(quoted)
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        default:
            throw Failure.unsupportedTerminal(host ?? "this terminal")
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            throw Failure.scriptFailed(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error")
        }
        if result?.stringValue != "ok" { throw Failure.scriptFailed("its tab wasn't found") }
    }

    static func tty(of pid: pid_t) -> String? { ttyOf(pid) }

    private static func ttyOf(_ pid: pid_t) -> String? {
        let output = run("/bin/ps", ["-o", "tty=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty || output == "??" ? nil : "/dev/" + output
    }

    /// The GUI app hosting a terminal process: walk up the parents until one is a regular app.
    private static func hostApp(of pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<12 {
            guard let parent = Int32(run("/bin/ps", ["-o", "ppid=", "-p", String(current)]).trimmingCharacters(in: .whitespaces)),
                  parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                return app.localizedName
            }
            current = parent
        }
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
