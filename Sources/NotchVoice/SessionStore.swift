import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "sessions")

struct ClaudeSession: Identifiable, Equatable {
    enum State: String {
        case waiting, working, idle
    }

    let id: String
    private(set) var title: String
    let project: String
    private(set) var activity: String
    private(set) var state: State
    /// The session that ran /orchestrator. While it is open, NotchVoice reads only its replies aloud.
    private(set) var isOrchestrator = false
    let started: Date
    let updated: Date
    let cwd: String?
    let transcript: URL?
    let pid: pid_t?
    let process: String?
    let app: String?
    let tty: String?
    /// The Claude desktop app's id for the session, when it runs there.
    private(set) var desktopID: String?

    // Used only when the hook couldn't find the session's process: a finished session stays listed for a while,
    // and one that is working but silent this long has likely crashed.
    static let idleLifetime: TimeInterval = 15 * 60
    static let workingLifetime: TimeInterval = 2 * 60 * 60

    init?(id: String, json: [String: Any]) {
        guard let rawState = json["state"] as? String, let state = State(rawValue: rawState),
              let updated = json["updated"] as? Double else { return nil }
        let project = json["project"] as? String ?? ""
        self.id = id
        self.project = project
        title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (project.isEmpty ? "Claude Code" : project)
        activity = json["activity"] as? String ?? ""
        self.state = state
        self.updated = Date(timeIntervalSince1970: updated)
        started = Date(timeIntervalSince1970: json["started"] as? Double ?? updated)
        cwd = json["cwd"] as? String
        transcript = (json["transcript_path"] as? String).map { URL(filePath: $0) }
        pid = (json["pid"] as? Int).map { pid_t($0) }
        process = json["process"] as? String
        app = json["app"] as? String
        tty = json["tty"] as? String
    }

    func isOpen(now: Date, isRunning: (pid_t, String) -> Bool) -> Bool {
        if let pid, let process { return isRunning(pid, process) }
        return now.timeIntervalSince(updated) < (state == .idle ? Self.idleLifetime : Self.workingLifetime)
    }

    var interrupted: ClaudeSession {
        var session = self
        session.state = .idle
        session.activity = "Interrupted"
        return session
    }

    /// Takes the session's name and desktop app id from Claude Code's own registry entry for its process. The entry
    /// isn't documented, so anything missing or for another session leaves the session as it was. A name Claude Code
    /// derived from the folder says less than the first prompt, so it is skipped.
    func naming(from registry: [String: Any]) -> ClaudeSession {
        guard registry["sessionId"] as? String == id else { return self }
        var session = self
        if let name = (registry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           registry["nameSource"] as? String != "derived" {
            session.title = name
        }
        if let host = registry["hostSessionId"] as? String, Self.isDesktopID(host) {
            session.desktopID = host
        }
        return session
    }

    /// The Claude desktop app's session ids look like local_<uuid>. Anything else isn't used, not even in a link.
    static func isDesktopID(_ id: String) -> Bool {
        id.wholeMatch(of: /local_[0-9a-f-]+/) != nil
    }

    var asOrchestrator: ClaudeSession {
        var session = self
        session.isOrchestrator = true
        return session
    }

    /// The orchestrator comes first, then sessions that need you. The rest keep the order they started in, so rows
    /// don't jump around.
    static func sorted(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        sessions.sorted { a, b in
            if a.isOrchestrator != b.isOrchestrator { return a.isOrchestrator }
            if (a.state == .waiting) != (b.state == .waiting) { return a.state == .waiting }
            return (a.started, a.id) < (b.started, b.id)
        }
    }
}

enum Transcript {
    private static let tailLength: UInt64 = 64 * 1024
    private static let interruptNote = "[Request interrupted by user"

    /// When you last interrupted Claude, from the note Claude Code writes into the transcript. No hook runs after an
    /// interrupt, so this is the only sign that a session stopped working.
    static func lastInterrupt(in url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > tailLength ? end - tailLength : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() where String(decoding: line, as: UTF8.self).contains(interruptNote) {
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  entry["type"] as? String == "user",
                  let message = entry["message"] as? [String: Any],
                  text(of: message["content"]).hasPrefix(interruptNote),
                  let timestamp = entry["timestamp"] as? String else { continue }
            return date(timestamp)
        }
        return nil
    }

    private static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
    }

    private static func date(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}

/// Lists the open Claude Code sessions from the status files ~/.claude/hooks/notchvoice_sessions.py keeps.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    static let directory = URL.homeDirectory.appending(path: ".claude/notchvoice/sessions")
    // Written by the orchestrator skill's claim; it sits next to the sessions folder, so that folder is watched too.
    static let orchestratorFile = URL.homeDirectory.appending(path: ".claude/notchvoice/orchestrator.json")
    // Claude Code's own record of each running session, one <pid>.json per process.
    static let registryDirectory = URL.homeDirectory.appending(path: ".claude/sessions")
    // Status files of sessions that ended or went quiet this long ago are deleted.
    private static let pruneAge: TimeInterval = 24 * 60 * 60
    // A session that stops without a hook saying so (closed, crashed or interrupted) leaves the list within this long.
    private static let busyCheckInterval: TimeInterval = 5
    private static let idleCheckInterval: TimeInterval = 30
    // Only a session this quiet is checked for an interrupt, so busy ones don't have their transcript read.
    private static let interruptDelay: TimeInterval = 2

    private var watchers: [DispatchSourceFileSystemObject] = []
    // Registry entries by pid, kept until the file changes, since reload runs on every status update.
    private var registryCache: [pid_t: (modified: Date, entry: [String: Any])] = [:]
    private var timer: Timer?

    func start() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        watch(Self.directory)
        watch(Self.orchestratorFile.deletingLastPathComponent())
        reload()
    }

    /// Lets every session speak again. The orchestrator keeps running, it just isn't the only voice any more.
    func releaseOrchestrator() {
        try? FileManager.default.removeItem(at: Self.orchestratorFile)
        reload()
    }

    func reload() {
        let now = Date()
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var found: [ClaudeSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let session = ClaudeSession(id: file.deletingPathExtension().lastPathComponent, json: json),
               session.isOpen(now: now, isRunning: Self.isRunning) {
                found.append(Self.wasInterrupted(session, now: now) ? session.interrupted : session)
            } else if let seconds = json["updated"] as? Double, now.timeIntervalSince1970 - seconds > Self.pruneAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let orchestrator = (try? Data(contentsOf: Self.orchestratorFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["session_id"] as? String
        registryCache = registryCache.filter { pid, _ in found.contains { $0.pid == pid } }
        let sorted = ClaudeSession.sorted(found.map { session in
            let named = session.pid.map { session.naming(from: registry(of: $0)) } ?? session
            return named.id == orchestrator ? named.asOrchestrator : named
        })
        if sorted.count != sessions.count { log.info("sessions: \(sorted.count)") }
        if sorted != sessions { sessions = sorted }
        schedule(every: sorted.contains { $0.state != .idle } ? Self.busyCheckInterval : Self.idleCheckInterval)
    }

    /// Whether you interrupted the session after its last hook ran. A prompt or slash command after the interrupt
    /// runs a hook too, so an older interrupt is ignored.
    private static func wasInterrupted(_ session: ClaudeSession, now: Date) -> Bool {
        guard session.state != .idle, now.timeIntervalSince(session.updated) > interruptDelay,
              let transcript = session.transcript, let interrupt = Transcript.lastInterrupt(in: transcript) else { return false }
        return interrupt > session.updated
    }

    private func registry(of pid: pid_t) -> [String: Any] {
        let file = Self.registryDirectory.appending(path: "\(pid).json")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else {
            registryCache[pid] = nil
            return [:]
        }
        if let cached = registryCache[pid], cached.modified == modified { return cached.entry }
        let entry = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        registryCache[pid] = (modified, entry)
        return entry
    }

    /// Whether the hook's process is still running. Comparing names guards against a reused pid.
    private static func isRunning(_ pid: pid_t, _ process: String) -> Bool {
        guard Processes.isAlive(pid), let name = Processes.name(of: pid), !name.isEmpty else { return false }
        // The kernel keeps only the first 15 or so characters of a long process name.
        return name == process || (name.count >= 15 && process.hasPrefix(name))
    }

    private func schedule(every interval: TimeInterval) {
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func watch(_ directory: URL) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers.append(source)
    }
}
