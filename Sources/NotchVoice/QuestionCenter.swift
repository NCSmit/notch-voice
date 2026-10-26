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

/// The questions a session asked with AskUserQuestion, waiting in the notch.
struct QuestionPrompt: Identifiable, Equatable {
    let id: UUID
    let sessionID: String?
    let cwd: String?
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
        self.init(id: id, sessionID: json["session_id"] as? String, cwd: json["cwd"] as? String, questions: questions)
    }

    /// The answers AskUserQuestion takes: each question's text maps to the chosen label, labels joined with ", " when
    /// several are chosen, or to the user's own words when they typed them.
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
    /// Whether questions come to the notch at all. When not, each goes straight back to Claude.
    var isEnabled: () -> Bool = { true }

    static let socketPath = URL(filePath: NSTemporaryDirectory()).appending(path: "notchvoice_question.sock").path
    private var connections: [UUID: PermissionConnection] = [:]

    private lazy var server = PermissionServer(
        path: Self.socketPath,
        label: "local.notchvoice.questions",
        onRequest: { [weak self] connection, line in
            let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.add(json, connection: connection) } }
        },
        onClose: { [weak self] connection in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.withdraw(connection.id) } }
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

    /// The setting was turned off: every question waiting goes back to Claude.
    func handBackAll() {
        for connection in connections.values { connection.reply("ask") }
        connections.removeAll()
        queue.removeAll()
    }

    /// "Answer in Claude": Claude shows its own question box instead.
    func handBack(_ id: UUID) {
        log.info("handed back to Claude")
        connections[id]?.reply("ask")
        remove(id)
    }

    private func add(_ json: [String: Any], connection: PermissionConnection) {
        guard isEnabled(), let prompt = QuestionPrompt(id: connection.id, json: json) else {
            log.info("question handed back: the setting is off, or it couldn't be read")
            return connection.reply("ask")
        }
        connections[prompt.id] = connection
        queue.append(prompt)
        log.info("showing \(prompt.questions.count) question(s)")
    }

    /// The hook went away first: Claude was interrupted, or the hook ended.
    private func withdraw(_ id: UUID) {
        if connections[id] != nil { log.info("question withdrawn: the hook ended") }
        remove(id)
    }

    private func remove(_ id: UUID) {
        connections[id] = nil
        queue.removeAll { $0.id == id }
    }
}
