import Foundation

/// The spoken commands hands-free listens for. Users can change them in Settings.
struct VoicePhrases: Codable, Equatable, Sendable {
    var wake = "hey orchestrator"
    var send = "send it"
    var cancel = "cancel that"
    var skip = "skip"
    var skipAll = "skip all"

    static let defaults = VoicePhrases()

    /// The phrases in use, set from the main actor when Settings change and read by the matchers below.
    nonisolated(unsafe) static var current = VoicePhrases.defaults

    private static let greetings = ["hey", "hi", "hay", "a", "okay", "ok"]

    // MARK: Validation

    /// nil when the phrases are usable, otherwise what is wrong, in plain words.
    var problem: String? {
        let named = [("Wake", wake), ("Send", send), ("Cancel", cancel), ("Skip", skip), ("Skip all", skipAll)]
        for (name, phrase) in named where Self.words(phrase).isEmpty {
            return "\(name) phrase can't be empty."
        }
        var seen: [String: String] = [:]
        for (name, phrase) in named {
            let key = Self.words(phrase).joined(separator: " ")
            if let other = seen[key] { return "\(other) and \(name.lowercased()) phrases are the same." }
            seen[key] = name
        }
        return nil
    }

    // MARK: Matching

    static func words(_ text: String) -> [String] {
        WakeWordListener.normalized(text).split(separator: " ").map(String.init)
    }

    /// A phrase as a regex over normalized text. "orchestrator" also matches how Apple's recognizer often hears
    /// it ("orchestra").
    static func pattern(_ phrase: String) -> String {
        words(phrase).map { word in
            word == "orchestrator" ? "orchestra(tor|ter|te)?s?" : NSRegularExpression.escapedPattern(for: word)
        }.joined(separator: " ")
    }

    /// The wake phrase without a leading greeting ("hey orchestrator" → "orchestrator"), as a pattern, or nil when
    /// the phrase doesn't start with one.
    var wakeWithoutGreeting: String? {
        let parts = Self.words(wake)
        guard parts.count > 1, Self.greetings.contains(parts[0]) else { return nil }
        return Self.pattern(parts.dropFirst().joined(separator: " "))
    }

    func isWake(_ text: String) -> Bool {
        let heard = WakeWordListener.normalized(text)
        if heard.range(of: "\\b\(Self.pattern(wake))\\b", options: .regularExpression) != nil { return true }
        // Apple's recognizer often drops the "hey" at the start of a phrase, so the rest on its own as a whole
        // phrase counts too; a mention mid-sentence doesn't.
        guard let rest = wakeWithoutGreeting else { return false }
        let greeting = Self.greetings.joined(separator: "|")
        return heard.range(of: "^((\(greeting)) )?\(rest)$", options: .regularExpression) != nil
    }

    func endsWithSend(_ text: String) -> Bool {
        WakeWordListener.normalized(text).range(of: "\\b\(Self.pattern(send))$", options: .regularExpression) != nil
    }

    func endsWithCancel(_ text: String) -> Bool {
        WakeWordListener.normalized(text).range(of: "\\b\(Self.pattern(cancel))$", options: .regularExpression) != nil
    }

    /// A spoken skip, only as a whole phrase (optionally after the wake word): nil = not a skip, true = skip all.
    func skipCommand(_ text: String) -> Bool? {
        let heard = WakeWordListener.normalized(text)
        let prefix = "^((hey )?\(wakeWithoutGreeting ?? Self.pattern(wake)) )?"
        var all = [Self.pattern(skipAll)]
        var one = [Self.pattern(skip), Self.pattern(skip) + " it", Self.pattern(skip) + " that"]
        if skipAll == Self.defaults.skipAll { all.append("stop (all|everything)") }
        if skip == Self.defaults.skip { one.append("next") }
        if heard.range(of: prefix + "(\(all.joined(separator: "|")))$", options: .regularExpression) != nil { return true }
        if heard.range(of: prefix + "(\(one.joined(separator: "|")))$", options: .regularExpression) != nil { return false }
        return nil
    }

    /// The dictated message without the send phrase: "…that's it for now, send it." → "…that's it for now".
    func strippingSend(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = Self.words(send).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "[\\s,]+")
        let pattern = "[\\s,;:.!-]*\\b\(spoken)[\\s.!]*$"
        while let range = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-").union(.whitespacesAndNewlines))
    }

    /// Hints for the recognizer, so it favours these words.
    var recognizerHints: [String] {
        [wake, Self.words(wake).last ?? wake, send, cancel, skip, skipAll]
    }
}
