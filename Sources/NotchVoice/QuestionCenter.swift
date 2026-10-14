import AppKit
import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "questions")

struct QuestionOption: Equatable {
    let label: String
    let description: String
    let preview: String?
}

struct Question: Equatable {
    let text: String
    let header: String
    let options: [QuestionOption]
    let multiSelect: Bool
}

/// A question a session asked with AskUserQuestion, waiting in the notch.
struct QuestionPrompt: Identifiable, Equatable {
    let id: UUID
    let sessionID: String?
    let sessionName: String
    let questions: [Question]
}

extension QuestionPrompt {
    init?(id: UUID, json: [String: Any]) {
        let raw = json["questions"] as? [[String: Any]] ?? []
        let questions = raw.compactMap { item -> Question? in
            guard let text = item["question"] as? String else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> QuestionOption? in
                guard let label = option["label"] as? String else { return nil }
                return QuestionOption(label: label, description: option["description"] as? String ?? "", preview: option["preview"] as? String)
            }
            return Question(text: text, header: item["header"] as? String ?? "", options: options, multiSelect: item["multiSelect"] as? Bool ?? false)
        }
        guard !questions.isEmpty else { return nil }
        let session = json["session_id"] as? String
        let cwd = json["cwd"] as? String
        self.init(
            id: id,
            sessionID: session,
            sessionName: session.flatMap(SessionNavigator.name(of:)) ?? cwd.map { URL(filePath: $0).lastPathComponent } ?? "A session",
            questions: questions
        )
    }

    /// The answers map AskUserQuestion expects: question text → chosen label, labels joined with ", " for
    /// multi-select, or the user's own words for "Other".
    static func answers(for questions: [Question], picks: [Set<Int>], other: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            let typed = index < other.count ? other[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !typed.isEmpty {
                result[question.text] = typed
                continue
            }
            let chosen = (index < picks.count ? picks[index] : []).sorted().compactMap {
                $0 < question.options.count ? question.options[$0].label : nil
            }
            if !chosen.isEmpty { result[question.text] = chosen.joined(separator: ", ") }
        }
        return result
    }
}

/// Receives AskUserQuestion from notchvoice_question.py and sends the answers back.
@MainActor
final class QuestionCenter: ObservableObject {
    @Published private(set) var queue: [QuestionPrompt] = []

    static let socketPath = URL(filePath: NSTemporaryDirectory()).appending(path: "notchvoice_question.sock").path
    private var connections: [UUID: PermissionConnection] = [:]

    private lazy var server = PermissionServer(
        path: Self.socketPath,
        label: "local.notchvoice.questions",
        onRequest: { [weak self] connection, line in
            let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let prompt = QuestionPrompt(id: connection.id, json: json) else {
                        return connection.reply("ask")
                    }
                    self.connections[prompt.id] = connection
                    self.queue.append(prompt)
                    log.info("question from \(prompt.sessionName, privacy: .public): \(prompt.questions.count, privacy: .public) question(s)")
                }
            }
        },
        onClose: { [weak self] connection in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.remove(connection.id) }
            }
        }
    )

    var current: QuestionPrompt? { queue.first }

    func start() {
        server.start()
    }

    func answer(_ id: UUID, answers: [String: String]) {
        log.info("answered in the notch")
        connections[id]?.reply(json: ["decision": "answer", "answers": answers])
        remove(id)
    }

    /// "Answer in Claude": Claude shows its own question box instead.
    func handBack(_ id: UUID) {
        log.info("handed back to Claude")
        connections[id]?.reply("ask")
        remove(id)
    }

    private func remove(_ id: UUID) {
        connections[id] = nil
        queue.removeAll { $0.id == id }
    }
}

/// A brief "auto mode blocked …" notice, from the files notchvoice_sessions.py writes.
struct BlockedNotice: Identifiable, Equatable {
    let id: String
    let sessionID: String?
    let project: String
    let title: String
    let detail: String
}

@MainActor
final class NoticeCenter: ObservableObject {
    @Published private(set) var current: BlockedNotice?

    static let directory = URL.homeDirectory.appending(path: ".claude/notchvoice/notices")
    private var watcher: DispatchSourceFileSystemObject?
    private var shown: Set<String> = []
    private var hideWork: DispatchWorkItem?

    func start() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        // Old notices are history, not news.
        for file in (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        let descriptor = open(Self.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.load() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    func dismiss() {
        hideWork?.cancel()
        current = nil
    }

    private func load() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files where !shown.contains(file.lastPathComponent) {
            shown.insert(file.lastPathComponent)
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            try? FileManager.default.removeItem(at: file)
            current = BlockedNotice(
                id: file.lastPathComponent,
                sessionID: json["session_id"] as? String,
                project: json["project"] as? String ?? "",
                title: json["title"] as? String ?? "An action",
                detail: json["detail"] as? String ?? ""
            )
            log.info("auto mode blocked: \(self.current?.title ?? "", privacy: .public)")
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.current = nil }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
}

/// Finds a session by its Claude Code id and brings it to the front.
@MainActor
enum SessionNavigator {
    private nonisolated static func info(of session: String) -> [String: Any]? {
        let directory = URL.homeDirectory.appending(path: ".claude/sessions")
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  json["sessionId"] as? String == session else { continue }
            return json
        }
        return nil
    }

    nonisolated static func name(of session: String) -> String? {
        info(of: session)?["name"] as? String
    }

    static func go(to session: String?) {
        guard let session, let info = info(of: session) else { return }
        if info["entrypoint"] as? String == "claude-desktop", let desktop = info["hostSessionId"] as? String,
           let link = URL(string: "claude://claude.ai/epitaxy/\(desktop)") {
            NSWorkspace.shared.open(link)
            return
        }
        guard let pid = info["pid"] as? Int else { return }
        let tty = OrchestratorDelivery.tty(of: pid_t(pid)) ?? ""
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}
