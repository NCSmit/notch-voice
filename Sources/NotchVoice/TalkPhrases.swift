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
        guard text.contains(where: { $0.isLetter || $0.isNumber }), !endsWithCancelWord(text) else { return nil }
        return text
    }

    static func endsWithCancelWord(_ words: String) -> Bool {
        let plain = words.lowercased().replacing(/[^\w\s]/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cancelWords.contains(where: { plain == $0 || plain.hasSuffix(" " + $0) })
    }

    /// When a message began, from words with the times they were said: the first word after the last "Hey <name>", or
    /// the first word when there is no name to look for. Nil when no such word has a time yet.
    static func messageStart(in words: [(text: String, at: Date)], afterWakePhrase name: String?) -> Date? {
        guard let name else { return words.first?.at }
        let plain = words.map { $0.text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" } }
        let nameWords = name.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let ends = plain.indices.filter { start in
            ["hey", "hi"].contains(plain[start]) && Array(plain.dropFirst(start + 1).prefix(nameWords.count)) == nameWords
        }
        guard let last = ends.last, last + 1 + nameWords.count < words.count else { return nil }
        return words[last + 1 + nameWords.count].at
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

    /// How long a pause must last to send a message, unless the user sets another length within `pauses`.
    static let defaultPause: TimeInterval = 2.5
    static let pauses: ClosedRange<TimeInterval> = 1...5
    /// A message that began more than this before Wispr Flow was listening has lost its first words there.
    static let wisprHeadStart: TimeInterval = 0.15
    static let waitForWords: TimeInterval = 7
    static let longest: TimeInterval = 90

    static func decide(_ trigger: Trigger, heard: String, sinceStart: TimeInterval, sinceLastWords: TimeInterval,
                       pause: TimeInterval) -> Decision {
        let saidSomething = !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if sinceStart >= longest { return saidSomething ? .send : .nothingSaid }
        if trigger == .hold { return .keepListening }
        if !saidSomething { return sinceStart >= waitForWords ? .nothingSaid : .keepListening }
        return sinceLastWords >= pause ? .send : .keepListening
    }

    /// A pause length the user can set: within `pauses`, in steps of half a second.
    static func pause(_ seconds: TimeInterval) -> TimeInterval {
        min(max((seconds * 2).rounded() / 2, pauses.lowerBound), pauses.upperBound)
    }

    /// The words to send for a message Wispr Flow wrote out, and why Apple's transcript is sent instead, when it is:
    /// Wispr Flow wrote nothing, or started listening `headStart` seconds into the message and so missed its start.
    /// Either transcript ending with a cancel word sends nothing. With a wake name, only what follows the last
    /// "Hey <name>" in Wispr Flow's text counts, the same as in Apple's.
    static func wisprMessage(_ written: String, apple: String, headStart: TimeInterval, wakeName: String?) -> (words: String, appleBecause: String?) {
        if written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (apple, "Wispr Flow wrote nothing") }
        if headStart > wisprHeadStart {
            return (apple, "the message began \(String(format: "%.2f", headStart)) s before Wispr Flow was listening")
        }
        if TalkPhrases.endsWithCancelWord(apple) { return (apple, "it ends with a cancel word") }
        return (wakeName.flatMap { TalkPhrases.afterWakePhrase(in: written, name: $0) } ?? written, nil)
    }
}
