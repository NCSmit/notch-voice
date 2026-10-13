import Foundation
import Testing
@testable import NotchVoice

struct PermissionPromptTests {
    private let cwd = "/Users/someone/projects/demo"

    private func prompt(_ toolName: String, _ input: [String: Any]) -> PermissionPrompt {
        PermissionPrompt(id: UUID(), toolName: toolName, input: input, cwd: cwd)
    }

    @Test func commandShowsTheCommandItsDescriptionAndTheProject() {
        let prompt = prompt("Bash", ["command": "npm test", "description": "Run the tests"])
        #expect(prompt.title == "Run a command")
        #expect(prompt.detail == "npm test")
        #expect(prompt.note == "Run the tests")
        #expect(prompt.project == "demo")
    }

    @Test func editShowsTheRelativePathAndTheChangedLines() {
        let prompt = prompt("Edit", ["file_path": "\(cwd)/Sources/App.swift", "old_string": "let a = 1", "new_string": "let a = 2"])
        #expect(prompt.detail == "Sources/App.swift\n- let a = 1\n+ let a = 2")
    }

    @Test func longEditsAreShortened() {
        let old = (1...6).map { "line \($0)" }.joined(separator: "\n")
        let prompt = prompt("Edit", ["file_path": "\(cwd)/notes.txt", "old_string": old, "new_string": "done"])
        #expect(prompt.detail.contains("- … 2 more"))
        #expect(!prompt.detail.contains("line 5"))
    }

    @Test func writeCountsTheLines() {
        let prompt = prompt("Write", ["file_path": "\(cwd)/new.md", "content": "a\nb\nc"])
        #expect(prompt.title == "Write a file")
        #expect(prompt.detail == "new.md\n3 lines")
    }

    @Test func mcpToolsAreNamedAfterTheTool() {
        let prompt = prompt("mcp__github__create_issue", ["title": "Bug"])
        #expect(prompt.title == "Use create issue")
        #expect(prompt.detail == #"{"title":"Bug"}"#)
    }

    @Test func pathsOutsideTheProjectAreShortenedToTheHomeFolder() {
        let prompt = prompt("Read", ["file_path": NSHomeDirectory() + "/notes.txt"])
        #expect(prompt.detail == "~/notes.txt")
    }
}
