import AppKit
import Foundation
import Testing
@testable import NotchVoice

struct SessionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeSession(_ state: String, age: TimeInterval = 5, started: TimeInterval? = nil, extra: [String: Any] = [:]) -> ClaudeSession? {
        var json: [String: Any] = ["state": state, "updated": now.timeIntervalSince1970 - age, "project": "demo", "title": "Fix the bug"]
        if let started { json["started"] = started }
        return ClaudeSession(id: "\(state)-\(age)-\(started ?? 0)", json: json.merging(extra) { $1 })
    }

    @Test func readsAStatusFile() throws {
        let session = try #require(makeSession("working", extra: [
            "activity": "Editing a.py", "cwd": "/Users/someone/demo", "pid": 4242, "process": "claude",
            "app": "com.apple.Terminal", "tty": "/dev/ttys003", "transcript_path": "/tmp/abc.jsonl",
        ]))
        #expect(session.state == .working)
        #expect(session.title == "Fix the bug")
        #expect(session.activity == "Editing a.py")
        #expect(session.pid == 4242 && session.process == "claude")
        #expect(session.app == "com.apple.Terminal" && session.tty == "/dev/ttys003")
        #expect(session.transcript?.path == "/tmp/abc.jsonl")
    }

    @Test func endedAndBrokenFilesAreSkipped() {
        #expect(makeSession("ended") == nil)
        #expect(ClaudeSession(id: "x", json: ["state": "working"]) == nil)
    }

    @Test func aSessionWithoutAPromptIsNamedAfterItsFolder() {
        #expect(makeSession("idle", extra: ["title": ""])?.title == "demo")
    }

    @Test func aSessionStaysListedForAsLongAsItsProcessRuns() throws {
        let session = try #require(makeSession("idle", age: 24 * 60 * 60, extra: ["pid": 4242, "process": "claude"]))
        #expect(session.isOpen(now: now) { pid, name in pid == 4242 && name == "claude" })
        #expect(!session.isOpen(now: now) { _, _ in false })
    }

    @Test func withoutAProcessFinishedSessionsLeaveTheListAfterAWhile() {
        let isRunning: (pid_t, String) -> Bool = { _, _ in Issue.record("there is no process to check"); return true }
        #expect(makeSession("idle", age: 60)?.isOpen(now: now, isRunning: isRunning) == true)
        #expect(makeSession("idle", age: ClaudeSession.idleLifetime + 1)?.isOpen(now: now, isRunning: isRunning) == false)
        #expect(makeSession("working", age: ClaudeSession.idleLifetime + 1)?.isOpen(now: now, isRunning: isRunning) == true)
        #expect(makeSession("working", age: ClaudeSession.workingLifetime + 1)?.isOpen(now: now, isRunning: isRunning) == false)
    }

    @Test func sessionsThatNeedYouComeFirstThenTheOrderTheyStarted() throws {
        let list = ClaudeSession.sorted([
            try #require(makeSession("idle", age: 1, started: 30)),
            try #require(makeSession("working", age: 1, started: 20)),
            try #require(makeSession("waiting", age: 1, started: 40)),
            try #require(makeSession("working", age: 50, started: 10)),
        ])
        #expect(list.map(\.started.timeIntervalSince1970) == [40, 10, 20, 30])
    }

    @Test func theOrchestratorComesFirst() throws {
        let list = ClaudeSession.sorted([
            try #require(makeSession("waiting", age: 1, started: 10)),
            try #require(makeSession("idle", age: 1, started: 20)).asOrchestrator,
            try #require(makeSession("working", age: 1, started: 5)),
        ])
        #expect(list.map(\.isOrchestrator) == [true, false, false])
        #expect(list.map(\.state) == [.idle, .waiting, .working])
    }

    @Test func anInterruptedSessionIsIdle() throws {
        let session = try #require(makeSession("working", extra: ["activity": "Thinking"])).interrupted
        #expect(session.state == .idle)
        #expect(session.activity == "Interrupted")
    }
}

struct TranscriptTests {
    private func transcript(_ entries: [[String: Any]], padding: Int = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "notchvoice-\(UUID().uuidString).jsonl")
        var lines = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        if padding > 0 { lines.insert("{\"type\":\"user\",\"message\":{\"content\":\"\(String(repeating: "x", count: padding))\"}}", at: 0) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func user(_ content: Any, at timestamp: String = "2026-10-26T10:00:00.000Z") -> [String: Any] {
        ["type": "user", "timestamp": timestamp, "message": ["role": "user", "content": content]]
    }

    private let assistant: [String: Any] = ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "t1", "name": "Bash"]]]]
    private let queued: [String: Any] = ["type": "queue-operation", "operation": "enqueue", "content": "next"]
    private let tenOClock = Date(timeIntervalSince1970: 1_793_008_800)

    @Test func findsWhenYouLastInterrupted() throws {
        let url = try transcript([
            user("[Request interrupted by user]", at: "2026-10-26T09:00:00.000Z"),
            assistant,
            user([["type": "text", "text": "[Request interrupted by user for tool use]"]], at: "2026-10-26T10:00:00.250Z"),
            queued,
            user("<command-name>/cost</command-name>", at: "2026-10-26T10:00:05.000Z"),
        ])
        #expect(Transcript.lastInterrupt(in: url) == tenOClock.addingTimeInterval(0.25))
        #expect(Transcript.lastInterrupt(in: try transcript([user("[Request interrupted by user]", at: "2026-10-26T10:00:00Z")])) == tenOClock)
    }

    @Test func aTranscriptWithoutAnInterruptHasNone() throws {
        #expect(Transcript.lastInterrupt(in: try transcript([user("Fix the bug"), assistant])) == nil)
        #expect(Transcript.lastInterrupt(in: try transcript([assistant, user([["type": "tool_result", "tool_use_id": "t1"]])])) == nil)
        #expect(Transcript.lastInterrupt(in: try transcript([user("Why did it say [Request interrupted by user]?")])) == nil)
        #expect(Transcript.lastInterrupt(in: URL(filePath: "/nonexistent/notchvoice.jsonl")) == nil)
    }

    @Test func readsOnlyTheEndOfALongTranscript() throws {
        let url = try transcript([assistant, user("[Request interrupted by user]")], padding: 200_000)
        #expect(Transcript.lastInterrupt(in: url) == tenOClock)
    }
}

@MainActor
struct SessionMenuTests {
    private func makeSession(_ state: String, title: String = "Fix the login bug", activity: String = "") -> ClaudeSession {
        let json: [String: Any] = [
            "state": state, "updated": 1_000_000.0, "project": "demo", "title": title,
            "activity": activity, "cwd": NSHomeDirectory() + "/code/demo",
        ]
        return ClaudeSession(id: "abc-123", json: json)!
    }

    @Test func showsTheProjectAndWhatTheSessionIsDoing() {
        #expect(StatusItemController.detail(for: makeSession("working", activity: "Editing login.py"), isSpeaking: false) == "demo · Editing login.py")
        #expect(StatusItemController.detail(for: makeSession("working"), isSpeaking: false) == "demo · Working")
        #expect(StatusItemController.detail(for: makeSession("idle"), isSpeaking: false) == "demo · Done")
        #expect(StatusItemController.detail(for: makeSession("idle", activity: "Fixed it."), isSpeaking: true) == "demo · Speaking…")
    }

    @Test func doesNotRepeatTheProjectWhenItIsAlsoTheTitle() {
        #expect(StatusItemController.detail(for: makeSession("idle", title: "demo", activity: "Ready"), isSpeaking: false) == "Ready")
    }

    @Test func aRowCarriesTheSessionAndOnlyOpensWhenItsAppIsRunning() {
        let item = StatusItemController.item(for: makeSession("waiting", activity: "Needs you: Running the tests"), isSpeaking: false, canOpen: false)
        #expect(item.title == "Fix the login bug")
        if #available(macOS 14.4, *) {
            #expect(item.subtitle == "demo · Needs you: Running the tests")
        }
        #expect(item.representedObject as? String == "abc-123")
        #expect(item.toolTip == "~/code/demo")
        #expect(!item.isEnabled)
        #expect(item.image != nil)
    }

    @Test func theMenuSaysSoWhenNoSessionIsOpen() {
        let items = StatusItemController.menuItems(for: [], speakingSession: nil, canOpen: { _ in true }, target: nil)
        #expect(items.map(\.title) == ["Claude Code Sessions", "No sessions open", "", "Settings…", "Quit NotchVoice"])
        #expect(!items[1].isEnabled)
    }

    @Test func theMenuListsEachSessionAndMarksTheOneSpeaking() {
        let speaking = makeSession("idle", title: "Ship it")
        let items = StatusItemController.menuItems(for: [speaking], speakingSession: speaking.id, canOpen: { _ in true }, target: nil)
        #expect(items.map(\.title) == ["Claude Code Sessions", "Ship it", "", "Settings…", "Quit NotchVoice"])
        #expect(items[1].isEnabled)
        #expect(items[1].image?.accessibilityDescription == "Speaking")
        if #available(macOS 14.4, *) {
            #expect(items[1].subtitle == "demo · Speaking…")
        }
    }

    @Test func theOrchestratorIsMarkedAndCanBeToldToShareTheVoice() {
        let orchestrator = makeSession("working", title: "/orchestrator", activity: "Briefing").asOrchestrator
        let items = StatusItemController.menuItems(for: [orchestrator], speakingSession: nil, canOpen: { _ in true }, target: nil)
        #expect(items.map(\.title) == ["Claude Code Sessions", "Orchestrator", "", "Let Every Session Speak", "Settings…", "Quit NotchVoice"])
        #expect(items[1].image?.accessibilityDescription == "Orchestrator")
        let plain = StatusItemController.menuItems(for: [makeSession("working")], speakingSession: nil, canOpen: { _ in true }, target: nil)
        #expect(!plain.map(\.title).contains("Let Every Session Speak"))
    }

    @Test func onlyTerminalAndITermHaveATabToSelect() {
        #expect(SessionOpener.tabScript(for: SessionOpener.terminal)?.contains("tty of t is item 1 of argv") == true)
        #expect(SessionOpener.tabScript(for: SessionOpener.iTerm)?.contains("tty of s is item 1 of argv") == true)
        #expect(SessionOpener.tabScript(for: "com.anthropic.claudefordesktop") == nil)
        #expect(SessionOpener.tabScript(for: nil) == nil)
    }
}
