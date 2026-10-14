import Foundation
import Testing
@testable import NotchVoice

struct SessionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ state: String, age: TimeInterval, title: String? = "Fix the bug") -> ClaudeSession? {
        var json: [String: Any] = ["state": state, "updated": now.timeIntervalSince1970 - age, "project": "demo", "activity": "Editing a.py"]
        if let title { json["title"] = title }
        return ClaudeSession(id: "\(state)-\(age)", json: json, now: now)
    }

    @Test func readsAStatusFile() throws {
        let session = try #require(session("working", age: 5))
        #expect(session.state == .working)
        #expect(session.title == "Fix the bug")
        #expect(session.activity == "Editing a.py")
    }

    @Test func finishedSessionsLeaveTheListAfterAWhile() {
        #expect(session("idle", age: 60) != nil)
        #expect(session("idle", age: ClaudeSession.idleLifetime + 1) == nil)
        #expect(session("working", age: ClaudeSession.idleLifetime + 1) != nil)
        #expect(session("working", age: ClaudeSession.workingLifetime + 1) == nil)
    }

    @Test func endedAndBrokenFilesAreSkipped() {
        #expect(session("ended", age: 1) == nil)
        #expect(ClaudeSession(id: "x", json: ["state": "working"], now: now) == nil)
    }

    @Test func aSessionWithoutAPromptIsNamedAfterItsFolder() {
        #expect(session("idle", age: 1, title: nil)?.title == "demo")
    }

    @Test func sessionsThatNeedYouComeFirstThenTheNewest() throws {
        let list = ClaudeSession.sorted([
            try #require(session("idle", age: 1)),
            try #require(session("working", age: 50)),
            try #require(session("waiting", age: 100)),
            try #require(session("working", age: 10)),
        ])
        #expect(list.map(\.id) == ["waiting-100.0", "working-10.0", "working-50.0", "idle-1.0"])
    }
}
