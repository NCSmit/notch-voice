import Combine
import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "tracker")

struct TrackedPR: Identifiable, Equatable {
    enum Check: String {
        case passing, failing, pending, none
    }

    enum Bugbot: String {
        case clean, findings, running, missing
    }

    var id: String { "\(repo)#\(number)" }
    let repo: String
    let number: Int
    let title: String
    let url: URL?
    let isMerged: Bool
    let ci: Check
    let bugbot: Bugbot
    let sessionID: String?
    let sessionName: String?

    static let maxShown = 5

    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    init?(json: [String: Any]) {
        guard let repo = json["repo"] as? String, let number = json["number"] as? Int else { return nil }
        self.repo = repo
        self.number = number
        title = json["title"] as? String ?? ""
        url = (json["url"] as? String).flatMap(URL.init(string:))
        isMerged = json["state"] as? String == "MERGED"
        ci = (json["ci"] as? String).flatMap(Check.init(rawValue:)) ?? .none
        bugbot = (json["bugbot"] as? String).flatMap(Bugbot.init(rawValue:)) ?? .missing
        sessionID = json["session_id"] as? String
        sessionName = json["session_name"] as? String
    }
}

/// Keeps ~/.claude/notchvoice/tracker.json fresh by running the orchestrator's `snapshot.py tracker --write`, and
/// publishes the pull requests in it. The file is shared: the orchestrator reads the same overview.
@MainActor
final class TrackerStore: ObservableObject {
    @Published private(set) var prs: [TrackedPR] = []

    static let file = URL.homeDirectory.appending(path: ".claude/notchvoice/tracker.json")
    private static let script = URL.homeDirectory.appending(path: ".claude/skills/orchestrator/snapshot.py")
    private static let interval: TimeInterval = 120

    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var running: Process?
    private var pending = false
    private var debounce: DispatchWorkItem?
    private var sessionChanges: AnyCancellable?
    private var hasLiveSessions = false
    private var lastStates: [String: ClaudeSession.State] = [:]

    func start(sessions: SessionStore) {
        watch()
        load()
        // A session changing state is the moment a PR is likely to have moved, so refresh then (debounced),
        // plus every couple of minutes while any session is around to catch CI and Bugbot finishing.
        sessionChanges = sessions.$sessions.sink { [weak self] list in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hasLiveSessions = !list.isEmpty
                // Activity text changes on every tool call; only a change of state is worth a GitHub round trip.
                let states = Dictionary(list.map { ($0.id, $0.state) }) { a, _ in a }
                if states != self.lastStates {
                    self.lastStates = states
                    self.scheduleRefresh()
                }
            }
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.hasLiveSessions == true { self?.refresh() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func refresh() {
        guard FileManager.default.fileExists(atPath: Self.script.path) else { return }
        if running?.isRunning == true {
            pending = true
            return
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["python3", "-I", Self.script.path, "tracker", "--write"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.load()
                    if self.pending {
                        self.pending = false
                        self.refresh()
                    }
                }
            }
        }
        do {
            try process.run()
            running = process
        } catch {
            log.error("could not refresh the tracker: \(error.localizedDescription)")
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let list = Array(((json["prs"] as? [[String: Any]]) ?? []).compactMap(TrackedPR.init(json:)).prefix(TrackedPR.maxShown))
        if list != prs {
            prs = list
            log.info("pull requests: \(list.count)")
        }
    }

    func prs(for session: String) -> [TrackedPR] {
        prs.filter { $0.sessionID == session }
    }

    private func watch() {
        let directory = Self.file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.load() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}
