import Foundation

/// How a spoken message to the orchestrator starts and ends.
enum TalkPhrases {
    private static let cancelWords: Set<String> = ["cancel", "never mind", "nevermind", "forget it"]

    static func wakePhrase(_ name: String) -> String {
        "Hey \(name)"
    }

    /// A name for the wake phrase: one to three words of letters, tidied up. Nil for anything else.
    static func cleanName(_ name: String) -> String? {
        let words = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (1...3).contains(words.count), words.allSatisfy({ $0.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" } }),
              words.joined().count <= 30 else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The words after the last "Hey <name>" in a transcript, or nil when it doesn't contain one. Recognition writes
    /// the phrase with or without a comma, and sometimes as "Hi".
    static func afterWakePhrase(in transcript: String, name: String) -> String? {
        let words = name.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty,
              let wake = try? NSRegularExpression(pattern: "\\b(hey|hi)[\\s,.!]+" + words.joined(separator: "[\\s,.-]+") + "\\b[\\s,.!?]*",
                                                  options: [.caseInsensitive]),
              let last = wake.matches(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)).last,
              let end = Range(last.range, in: transcript)?.upperBound else { return nil }
        return String(transcript[end...])
    }

    /// The message to send, or nil when there is nothing to send: nothing was said, or it ended with a cancel word.
    /// A comma left over from "Hey Jarvis," goes, but the end keeps its punctuation, so a question stays one.
    static func message(from words: String) -> String? {
        let text = words.drop(while: { $0.isWhitespace || $0.isPunctuation }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let plain = text.lowercased().replacing(/[^\w\s]/, with: "")
        if cancelWords.contains(where: { plain == $0 || plain.hasSuffix(" " + $0) }) { return nil }
        return text
    }
}

/// When a message being spoken is done.
enum TalkPolicy {
    enum Trigger: Equatable {
        /// Said "Hey Jarvis": the message ends at a pause.
        case phrase
        /// Holding the talk shortcut: the message ends when the keys are let go.
        case hold
        /// Pressed the talk shortcut: the message ends at a pause or a second press.
        case press
    }

    enum Decision: Equatable {
        case keepListening, send, nothingSaid
    }

    static let pause: TimeInterval = 1.8
    static let waitForWords: TimeInterval = 7
    static let longest: TimeInterval = 90

    static func decide(_ trigger: Trigger, heard: String, sinceStart: TimeInterval, sinceLastWords: TimeInterval) -> Decision {
        let saidSomething = !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if sinceStart >= longest { return saidSomething ? .send : .nothingSaid }
        if trigger == .hold { return .keepListening }
        if !saidSomething { return sinceStart >= waitForWords ? .nothingSaid : .keepListening }
        return sinceLastWords >= pause ? .send : .keepListening
    }
}
