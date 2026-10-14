import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "sessions")

struct ClaudeSession: Identifiable, Equatable {
    enum State: String {
        case waiting, working, idle
    }

    let id: String
    let title: String
    let project: String
    let activity: String
    let state: State
    let updated: Date

    static let maxShown = 5
    // A finished session stays listed for a while; one that is working but silent this long has likely crashed.
    static let idleLifetime: TimeInterval = 15 * 60
    static let workingLifetime: TimeInterval = 2 * 60 * 60

    init?(id: String, json: [String: Any], now: Date) {
        guard let rawState = json["state"] as? String, let state = State(rawValue: rawState),
              let seconds = json["updated"] as? Double else { return nil }
        let updated = Date(timeIntervalSince1970: seconds)
        let age = now.timeIntervalSince(updated)
        guard age < (state == .idle ? Self.idleLifetime : Self.workingLifetime) else { return nil }
        let project = json["project"] as? String ?? ""
        self.id = id
        self.project = project
        self.title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (project.isEmpty ? "Claude Code" : project)
        self.activity = json["activity"] as? String ?? ""
        self.state = state
        self.updated = updated
    }

    static func sorted(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        let rank: [State: Int] = [.waiting: 0, .working: 1, .idle: 2]
        return sessions.sorted { a, b in
            rank[a.state]! != rank[b.state]! ? rank[a.state]! < rank[b.state]! : a.updated > b.updated
        }
    }
}

/// Lists the Claude Code sessions from the status files ~/.claude/hooks/notchvoice_sessions.py keeps.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var orchestratorID: String?

    static let directory = URL.homeDirectory.appending(path: ".claude/notchvoice/sessions")
    // Written by /orchestrator's snapshot.py claim; it sits next to the sessions folder, so a second watcher follows it.
    static let orchestratorFile = URL.homeDirectory.appending(path: ".claude/notchvoice/orchestrator.json")
    // Status files of sessions that ended or went quiet this long ago are deleted.
    private static let pruneAge: TimeInterval = 24 * 60 * 60

    private var watchers: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?

    func start() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        watch(Self.directory)
        watch(Self.orchestratorFile.deletingLastPathComponent())
        // Sessions age out of the list without any file changing, so look again now and then.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        reload()
    }

    func reload() {
        let now = Date()
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var found: [ClaudeSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let session = ClaudeSession(id: file.deletingPathExtension().lastPathComponent, json: json, now: now) {
                found.append(session)
            } else if let seconds = json["updated"] as? Double, now.timeIntervalSince1970 - seconds > Self.pruneAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let orchestrator = (try? Data(contentsOf: Self.orchestratorFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["session_id"] as? String
        let live = orchestrator.flatMap { id in found.contains { $0.id == id } ? id : nil }
        if orchestratorID != live { orchestratorID = live }
        let shown = Array(ClaudeSession.sorted(found).prefix(ClaudeSession.maxShown))
        if shown != sessions {
            sessions = shown
            log.info("sessions: \(shown.count)")
        }
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
