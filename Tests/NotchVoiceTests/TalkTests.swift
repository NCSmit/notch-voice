import Testing
@testable import NotchVoice

struct TalkPhraseTests {
    @Test func findsTheWakePhraseHoweverItIsWritten() {
        #expect(TalkPhrases.afterWakePhrase(in: "Hey Jarvis, which session needs me?", name: "Jarvis") == "which session needs me?")
        #expect(TalkPhrases.afterWakePhrase(in: "hey jarvis what's running", name: "Jarvis") == "what's running")
        #expect(TalkPhrases.afterWakePhrase(in: "Hi, Jarvis.", name: "Jarvis") == "")
        #expect(TalkPhrases.afterWakePhrase(in: "Jarvis is a name I like", name: "Jarvis") == nil)
        #expect(TalkPhrases.afterWakePhrase(in: "they jarvised it", name: "Jarvis") == nil)
    }

    @Test func usesTheLastWakePhraseInALongTranscript() {
        let transcript = "Hey Jarvis, never mind. Talking to someone else now. Hey Jarvis, run the tests"
        #expect(TalkPhrases.afterWakePhrase(in: transcript, name: "Jarvis") == "run the tests")
    }

    @Test func anyNameCanBeTheWakeWord() {
        #expect(TalkPhrases.afterWakePhrase(in: "Hey Friday, status?", name: "Friday") == "status?")
        #expect(TalkPhrases.afterWakePhrase(in: "hey mister robot, go", name: "Mister Robot") == "go")
        #expect(TalkPhrases.afterWakePhrase(in: "Hey Jarvis, go", name: "Friday") == nil)
        #expect(TalkPhrases.afterWakePhrase(in: "Hey a.b, go", name: "a.b") == "go")
        #expect(TalkPhrases.afterWakePhrase(in: "Hey axb, go", name: "a.b") == nil)
    }

    @Test func namesAreTidiedOrRefused() {
        #expect(TalkPhrases.cleanName("  jarvis ") == "Jarvis")
        #expect(TalkPhrases.cleanName("mister   robot") == "Mister Robot")
        #expect(TalkPhrases.cleanName("O'Brien") == "O'Brien")
        #expect(TalkPhrases.cleanName("") == nil)
        #expect(TalkPhrases.cleanName("R2D2") == nil)
        #expect(TalkPhrases.cleanName("one two three four") == nil)
    }

    @Test func aMessageCanBeCancelledOrEmpty() {
        #expect(TalkPhrases.message(from: ", which session needs me? ") == "which session needs me?")
        #expect(TalkPhrases.message(from: " .!") == nil)
        #expect(TalkPhrases.message(from: "Cancel.") == nil)
        #expect(TalkPhrases.message(from: "run the tests, never mind") == nil)
        #expect(TalkPhrases.message(from: "   ") == nil)
        #expect(TalkPhrases.message(from: "cancel the deploy and run the tests") == "cancel the deploy and run the tests")
    }
}

struct TalkPolicyTests {
    @Test func aPauseSendsWhatWasSaid() {
        #expect(TalkPolicy.decide(.phrase, heard: "run the tests", sinceStart: 4, sinceLastWords: 0.5) == .keepListening)
        #expect(TalkPolicy.decide(.phrase, heard: "run the tests", sinceStart: 4, sinceLastWords: TalkPolicy.pause) == .send)
        #expect(TalkPolicy.decide(.press, heard: "run the tests", sinceStart: 4, sinceLastWords: TalkPolicy.pause) == .send)
    }

    @Test func holdingWaitsForTheKeysToBeLetGo() {
        #expect(TalkPolicy.decide(.hold, heard: "run the tests", sinceStart: 30, sinceLastWords: 10) == .keepListening)
        #expect(TalkPolicy.decide(.hold, heard: "", sinceStart: 30, sinceLastWords: 30) == .keepListening)
    }

    @Test func silenceAndVeryLongMessagesEndIt() {
        #expect(TalkPolicy.decide(.phrase, heard: "", sinceStart: 3, sinceLastWords: 3) == .keepListening)
        #expect(TalkPolicy.decide(.phrase, heard: "", sinceStart: TalkPolicy.waitForWords, sinceLastWords: 7) == .nothingSaid)
        #expect(TalkPolicy.decide(.hold, heard: "a long one", sinceStart: TalkPolicy.longest, sinceLastWords: 0) == .send)
        #expect(TalkPolicy.decide(.hold, heard: "", sinceStart: TalkPolicy.longest, sinceLastWords: 0) == .nothingSaid)
    }
}
