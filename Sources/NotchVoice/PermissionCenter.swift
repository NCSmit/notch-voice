import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "permissions")

enum PermissionResponse: String {
    case allow
    case deny
    case dismiss = "ask"
}

struct PermissionPrompt: Identifiable, Equatable {
    let id: UUID
    let title: String
    let detail: String
    let symbol: String
    let project: String
    let note: String?
    /// The asking session's name (its title in the desktop app, or its Claude Code name), else its project folder.
    var sessionName: String = ""
}

@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var queue: [PermissionPrompt] = []
    var isEnabled: () -> Bool = { true }

    private var connections: [UUID: PermissionConnection] = [:]
    private lazy var server = PermissionServer(
        onRequest: { [weak self] connection, line in
            let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            let toolName = request["tool_name"] as? String ?? "a tool"
            let input = request["tool_input"] as? [String: Any] ?? [:]
            let cwd = request["cwd"] as? String
            var prompt = PermissionPrompt(id: connection.id, toolName: toolName, input: input, cwd: cwd)
            let session = request["session_id"] as? String
            prompt.sessionName = session.flatMap(SessionNavigator.name(of:)) ?? prompt.project
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.add(prompt, connection: connection) } }
        },
        onClose: { [weak self] connection in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.remove(connection.id) } }
        }
    )

    var current: PermissionPrompt? { queue.first }

    func start() {
        server.start()
    }

    func answer(_ id: UUID, _ response: PermissionResponse) {
        log.info("answered in the notch: \(response.rawValue, privacy: .public)")
        connections[id]?.reply(response.rawValue)
        remove(id)
    }

    func handBackAll() {
        for connection in connections.values { connection.reply(PermissionResponse.dismiss.rawValue) }
        connections.removeAll()
        queue.removeAll()
    }

    private func add(_ prompt: PermissionPrompt, connection: PermissionConnection) {
        guard isEnabled() else {
            log.info("request handed back: permission cards are off")
            return connection.reply(PermissionResponse.dismiss.rawValue)
        }
        connections[prompt.id] = connection
        queue.append(prompt)
        log.info("showing a request: \(prompt.title, privacy: .public) in \(prompt.project, privacy: .public)")
    }

    private func remove(_ id: UUID) {
        if connections[id] != nil { log.info("request withdrawn (answered in Claude or the hook ended)") }
        connections[id] = nil
        queue.removeAll { $0.id == id }
    }
}

extension PermissionPrompt {
    init(id: UUID, toolName: String, input: [String: Any], cwd: String?) {
        self.id = id
        project = cwd.map { URL(filePath: $0).lastPathComponent } ?? ""
        note = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let path = Self.displayPath(input["file_path"] ?? input["notebook_path"] ?? input["path"], cwd: cwd)
        switch toolName {
        case "Bash":
            (title, symbol, detail) = ("Run a command", "terminal", input["command"] as? String ?? "")
        case "Edit":
            let change = Self.lines(input["old_string"], prefix: "- ") + Self.lines(input["new_string"], prefix: "+ ")
            (title, symbol, detail) = ("Edit a file", "pencil", ([path] + change).joined(separator: "\n"))
        case "MultiEdit":
            let count = (input["edits"] as? [Any])?.count ?? 0
            (title, symbol, detail) = ("Edit a file", "pencil", "\(path)\n\(count) change\(count == 1 ? "" : "s")")
        case "Write":
            let count = (input["content"] as? String)?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
            (title, symbol, detail) = ("Write a file", "doc.badge.plus", "\(path)\n\(count) line\(count == 1 ? "" : "s")")
        case "NotebookEdit":
            (title, symbol, detail) = ("Edit a notebook", "book.pages", path)
        case "Read":
            (title, symbol, detail) = ("Read a file", "doc.text", path)
        case "WebFetch":
            (title, symbol, detail) = ("Open a web page", "globe", input["url"] as? String ?? "")
        case "WebSearch":
            (title, symbol, detail) = ("Search the web", "magnifyingglass", input["query"] as? String ?? "")
        case _ where toolName.hasPrefix("mcp__"):
            let parts = toolName.split(separator: "__", omittingEmptySubsequences: true)
            let tool = parts.count > 2 ? parts[2...].joined(separator: "__") : String(parts.last ?? "")
            (title, symbol, detail) = ("Use \(tool.replacingOccurrences(of: "_", with: " "))", "puzzlepiece.extension", Self.summary(of: input))
        default:
            (title, symbol, detail) = ("Use \(toolName)", "hand.raised", Self.summary(of: input))
        }
    }

    private static func displayPath(_ value: Any?, cwd: String?) -> String {
        guard let path = value as? String else { return "" }
        if let cwd, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func lines(_ value: Any?, prefix: String) -> [String] {
        guard let text = value as? String, !text.isEmpty else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(4).map { prefix + $0 }
        return lines.count > 4 ? shown + ["\(prefix)… \(lines.count - 4) more"] : shown
    }

    private static func summary(of input: [String: Any]) -> String {
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
