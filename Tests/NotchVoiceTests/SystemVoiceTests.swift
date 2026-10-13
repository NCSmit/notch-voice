import Testing
@testable import NotchVoice

struct SystemVoiceTests {
    private let selections: [Any] = [
        "en", ["_type": "Speech.VoiceSelection", "voiceId": "com.apple.siri.natural.Aaron"],
        "da", ["_type": "Speech.VoiceSelection", "voiceId": "com.apple.voice.compact.da-DK.Sara"],
    ]

    @Test func picksTheVoiceForTheUsersLanguage() {
        #expect(VoiceCatalog.selectedVoiceID(in: selections, language: "da") == "com.apple.voice.compact.da-DK.Sara")
        #expect(VoiceCatalog.selectedVoiceID(in: selections, language: "en") == "com.apple.siri.natural.Aaron")
    }

    @Test func fallsBackToTheFirstVoiceForOtherLanguages() {
        #expect(VoiceCatalog.selectedVoiceID(in: selections, language: "fr") == "com.apple.siri.natural.Aaron")
        #expect(VoiceCatalog.selectedVoiceID(in: [], language: "en") == nil)
    }

    @Test func siriVoicesGetTheNumberMacOSShows() {
        let voiceMap: [String: [[String: Any]]] = [
            "en-US": [["name": "simone", "order": 2], ["name": "aaron", "order": 1]],
            "en-GB": [["name": "martha", "order": 1]],
        ]
        #expect(VoiceCatalog.siriVoiceName("Aaron", voiceMap: voiceMap, preferredLocale: "en-US") == "Siri Voice 1")
        #expect(VoiceCatalog.siriVoiceName("simone", voiceMap: voiceMap, preferredLocale: "en-GB") == "Siri Voice 2")
        #expect(VoiceCatalog.siriVoiceName("Zed", voiceMap: voiceMap, preferredLocale: "en-US") == "Siri (Zed)")
    }
}
