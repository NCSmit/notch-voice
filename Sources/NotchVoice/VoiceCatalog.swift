import AVFoundation

struct VoiceCatalog {
    struct Voice: Identifiable {
        let id: String
        let name: String
    }

    struct LocaleGroup: Identifiable {
        let id: String
        let title: String
        let voices: [Voice]
    }

    struct Language: Identifiable {
        let id: String
        let name: String
        let groups: [LocaleGroup]
    }

    let preferred: [LocaleGroup]
    let novelty: [Voice]
    let others: [Language]

    static func load() -> VoiceCatalog {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isPersonalVoice) }
        let novelty = voices.filter { $0.voiceTraits.contains(.isNoveltyVoice) }
        let byLanguage = Dictionary(grouping: voices.filter { !$0.voiceTraits.contains(.isNoveltyVoice) }) {
            languageCode($0.language)
        }
        var seen = Set<String>()
        let preferred = Locale.preferredLanguages.map(languageCode).filter { byLanguage[$0] != nil && seen.insert($0).inserted }
        let others = byLanguage.keys
            .filter { !preferred.contains($0) }
            .sorted { languageName($0) < languageName($1) }
        return VoiceCatalog(
            preferred: preferred.flatMap { groups(byLanguage[$0]!) },
            novelty: sorted(novelty).map(voice),
            others: others.map { Language(id: $0, name: languageName($0), groups: groups(byLanguage[$0]!)) }
        )
    }

    static func displayName(of identifier: String) -> String? {
        AVSpeechSynthesisVoice(identifier: identifier).map(displayName)
    }

    private static func groups(_ voices: [AVSpeechSynthesisVoice]) -> [LocaleGroup] {
        let byLocale = Dictionary(grouping: voices, by: \.language)
        return byLocale.keys
            .sorted { rank($0) != rank($1) ? rank($0) < rank($1) : localeName($0) < localeName($1) }
            .map { LocaleGroup(id: $0, title: localeName($0), voices: sorted(byLocale[$0]!).map(voice)) }
    }

    private static func voice(_ voice: AVSpeechSynthesisVoice) -> Voice {
        Voice(id: voice.identifier, name: displayName(voice))
    }

    private static func displayName(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "\(voice.name) (Premium)"
        case .enhanced: "\(voice.name) (Enhanced)"
        default: voice.name
        }
    }

    private static func sorted(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        voices.sorted { a, b in
            a.quality != b.quality ? a.quality.rawValue > b.quality.rawValue : a.name < b.name
        }
    }

    private static func rank(_ locale: String) -> Int {
        Locale.preferredLanguages.firstIndex(of: locale) ?? .max
    }

    private static func languageCode(_ identifier: String) -> String {
        String(identifier.prefix { $0 != "-" && $0 != "_" })
    }

    private static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private static func localeName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
