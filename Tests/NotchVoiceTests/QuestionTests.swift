import Foundation
import Testing
@testable import NotchVoice

struct QuestionTests {
    private let json: [String: Any] = [
        "session_id": "s1",
        "cwd": "/Users/me/code/shop",
        "questions": [
            ["question": "Which database?", "header": "Database", "multiSelect": false,
             "options": [["label": "Postgres", "description": "Relational"], ["label": "SQLite", "description": "A file", "preview": "schema.sql"]]],
            ["question": "Which extras?", "header": "Extras", "multiSelect": true,
             "options": [["label": "Auth"], ["label": "Search"], ["label": "Billing"]]],
        ],
    ]

    @Test func readsTheQuestionsAClaudeSessionAsked() throws {
        let prompt = try #require(QuestionPrompt(id: UUID(), json: json))
        #expect(prompt.sessionID == "s1")
        #expect(prompt.questions.map(\.text) == ["Which database?", "Which extras?"])
        #expect(prompt.questions[0].options.map(\.label) == ["Postgres", "SQLite"])
        #expect(prompt.questions[0].options[1].preview == "schema.sql")
        #expect(prompt.questions[1].multiSelect)
        #expect(QuestionPrompt(id: UUID(), json: ["questions": [["header": "No text"]]]) == nil)
        #expect(QuestionPrompt(id: UUID(), json: [:]) == nil)
    }

    @Test func answersMapEachQuestionToItsLabelsOrTypedWords() throws {
        let questions = try #require(QuestionPrompt(id: UUID(), json: json)).questions
        #expect(QuestionPrompt.answers(for: questions, picks: [[1], [2, 0]], other: ["", ""])
            == ["Which database?": "SQLite", "Which extras?": "Auth, Billing"])
        #expect(QuestionPrompt.answers(for: questions, picks: [[1], []], other: ["  MySQL  ", ""]) == ["Which database?": "MySQL"])
        #expect(QuestionPrompt.answers(for: questions, picks: [[7], []], other: ["", ""]).isEmpty)
    }
}
