import Testing
@testable import NotchVoice

struct QuestionTests {
    private let single = Question(text: "Which database?", header: "DB", options: [
        QuestionOption(label: "Postgres", description: "", preview: nil),
        QuestionOption(label: "SQLite", description: "", preview: nil),
        QuestionOption(label: "Mongo", description: "", preview: nil),
    ], multiSelect: false)

    private var multi: Question { Question(text: "Which checks?", header: "", options: single.options, multiSelect: true) }

    @Test func spokenPicks() {
        #expect(QuestionVoice.parse("Option two", for: single) == .pick([1]))
        #expect(QuestionVoice.parse("option 2.", for: single) == .pick([1]))
        #expect(QuestionVoice.parse("the first one", for: single) == .pick([0]))
        #expect(QuestionVoice.parse("last one", for: single) == .pick([2]))
        #expect(QuestionVoice.parse("SQLite", for: single) == .pick([1]))
        #expect(QuestionVoice.parse("one and three", for: multi) == .pick([0, 2]))
        #expect(QuestionVoice.parse("option four", for: single) == nil)  // only three options
        #expect(QuestionVoice.parse("I think postgres is fine", for: single) == nil)
    }

    @Test func spokenOtherNextAndHandBack() {
        #expect(QuestionVoice.parse("Other, use DuckDB instead", for: single) == .other("use DuckDB instead"))
        #expect(QuestionVoice.parse("done", for: multi) == .next)
        #expect(QuestionVoice.parse("answer in Claude", for: single) == .handBack)
    }

    @Test func answersUseLabelsJoinedOrTheTypedText() {
        let answers = QuestionPrompt.answers(for: [single, multi], picks: [[1], [2, 0]], other: ["", ""])
        #expect(answers == ["Which database?": "SQLite", "Which checks?": "Postgres, Mongo"])
        let typed = QuestionPrompt.answers(for: [single], picks: [[1]], other: ["DuckDB"])
        #expect(typed == ["Which database?": "DuckDB"])
    }
}
