import Foundation
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

    @Test func aCancelWordAtTheEndIsFoundHoweverItIsWritten() {
        #expect(TalkPhrases.endsWithCancelWord("Please check the tests, and then please cancel."))
        #expect(TalkPhrases.endsWithCancelWord("Never mind!"))
        #expect(!TalkPhrases.endsWithCancelWord("Cancel the deploy."))
        #expect(!TalkPhrases.endsWithCancelWord(""))
    }

    @Test func theMessageStartsAfterTheLastWakePhrase() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let words = ["So", "hey", "Jarvis,", "never", "mind.", "Hey,", "Jarvis.", "Run", "the", "tests."].enumerated().map {
            (text: $1, at: start.addingTimeInterval(Double($0)))
        }
        #expect(TalkPhrases.messageStart(in: words, afterWakePhrase: "Jarvis") == start.addingTimeInterval(7))
        #expect(TalkPhrases.messageStart(in: words, afterWakePhrase: nil) == start)
        #expect(TalkPhrases.messageStart(in: Array(words.prefix(7)), afterWakePhrase: "Jarvis") == nil)
        #expect(TalkPhrases.messageStart(in: words, afterWakePhrase: "Friday") == nil)
        let named = [(text: "hey", at: start), (text: "Mister", at: start), (text: "Robot", at: start), (text: "go", at: start.addingTimeInterval(1))]
        #expect(TalkPhrases.messageStart(in: named, afterWakePhrase: "Mister Robot") == start.addingTimeInterval(1))
    }
}

struct TalkPolicyTests {
    @Test func aPauseSendsWhatWasSaid() {
        #expect(TalkPolicy.decide(.phrase, heard: "run the tests", sinceStart: 4, sinceLastWords: 0.5, pause: 2.5) == .keepListening)
        #expect(TalkPolicy.decide(.phrase, heard: "run the tests", sinceStart: 4, sinceLastWords: 2.5, pause: 2.5) == .send)
        #expect(TalkPolicy.decide(.press, heard: "run the tests", sinceStart: 4, sinceLastWords: 2.5, pause: 2.5) == .send)
    }

    @Test func theLengthOfThePauseIsTheUsers() {
        #expect(TalkPolicy.decide(.phrase, heard: "run the tests", sinceStart: 6, sinceLastWords: 3, pause: 4) == .keepListening)
        #expect(TalkPolicy.decide(.phrase, heard: "run the tests", sinceStart: 6, sinceLastWords: 1, pause: 1) == .send)
        #expect(TalkPolicy.pause(TalkPolicy.defaultPause) == 2.5)
        #expect(TalkPolicy.pause(1.74) == 1.5)
        #expect(TalkPolicy.pause(0.2) == TalkPolicy.pauses.lowerBound)
        #expect(TalkPolicy.pause(60) == TalkPolicy.pauses.upperBound)
    }

    @Test func holdingWaitsForTheKeysToBeLetGo() {
        #expect(TalkPolicy.decide(.hold, heard: "run the tests", sinceStart: 30, sinceLastWords: 10, pause: TalkPolicy.defaultPause) == .keepListening)
        #expect(TalkPolicy.decide(.hold, heard: "", sinceStart: 30, sinceLastWords: 30, pause: TalkPolicy.defaultPause) == .keepListening)
    }

    @Test func silenceAndVeryLongMessagesEndIt() {
        #expect(TalkPolicy.decide(.phrase, heard: "", sinceStart: 3, sinceLastWords: 3, pause: TalkPolicy.defaultPause) == .keepListening)
        #expect(TalkPolicy.decide(.phrase, heard: "", sinceStart: TalkPolicy.waitForWords, sinceLastWords: 7, pause: TalkPolicy.defaultPause) == .nothingSaid)
        #expect(TalkPolicy.decide(.hold, heard: "a long one", sinceStart: TalkPolicy.longest, sinceLastWords: 0, pause: TalkPolicy.defaultPause) == .send)
        #expect(TalkPolicy.decide(.hold, heard: "", sinceStart: TalkPolicy.longest, sinceLastWords: 0, pause: TalkPolicy.defaultPause) == .nothingSaid)
    }

    @Test func wisprFlowsTextIsSentWhenItHeardTheWholeMessage() {
        let choice = TalkPolicy.wisprMessage("Run the tests.", apple: "run the test", headStart: -0.6, wakeName: "Jarvis")
        #expect(choice.words == "Run the tests.")
        #expect(choice.appleBecause == nil)
        let small = TalkPolicy.wisprMessage("Run the tests.", apple: "run the test", headStart: TalkPolicy.wisprHeadStart, wakeName: nil)
        #expect(small.appleBecause == nil)
    }

    @Test func applesTranscriptIsSentWhenWisprFlowMissedSomething() {
        let late = TalkPolicy.wisprMessage("the tests.", apple: "run the tests", headStart: 0.4, wakeName: "Jarvis")
        #expect(late.words == "run the tests")
        #expect(late.appleBecause?.contains("0.40 s before") == true)
        let nothing = TalkPolicy.wisprMessage(" ", apple: "run the tests", headStart: -1, wakeName: nil)
        #expect(nothing.words == "run the tests")
        #expect(nothing.appleBecause == "Wispr Flow wrote nothing")
    }

    @Test func eitherTranscriptCanCancel() {
        let byApple = TalkPolicy.wisprMessage("Run the tests and then cancel the deploy.", apple: "run the tests and then cancel", headStart: -1, wakeName: nil)
        #expect(TalkPhrases.message(from: byApple.words) == nil)
        let byWispr = TalkPolicy.wisprMessage("Run the tests. Never mind.", apple: "run the tests never", headStart: -1, wakeName: nil)
        #expect(byWispr.appleBecause == nil)
        #expect(TalkPhrases.message(from: byWispr.words) == nil)
    }

    @Test func wisprFlowsTextKeepsOnlyWhatFollowsTheWakePhrase() {
        let choice = TalkPolicy.wisprMessage("Hey Jarvis, never mind. Hey Jarvis, run the tests.", apple: "run the tests", headStart: -1, wakeName: "Jarvis")
        #expect(choice.words == "run the tests.")
        #expect(TalkPolicy.wisprMessage("Hey Jarvis, go.", apple: "go", headStart: -1, wakeName: nil).words == "Hey Jarvis, go.")
    }
}

struct RequestTranscriptTests {
    @Test func aPauseAfterTheWakePhraseKeepsWhatFollows() {
        var transcript = RequestTranscript()
        transcript.add("Hey", timing: nil)
        transcript.add("Hey Jarvis", timing: nil)
        transcript.add("Hey Jarvis.", timing: 8.3...8.9)
        transcript.add("What", timing: nil)
        transcript.add("What is the status?", timing: nil)
        #expect(transcript.text == "Hey Jarvis. What is the status?")
        #expect(TalkPhrases.afterWakePhrase(in: transcript.text, name: "Jarvis") == "What is the status?")
    }

    @Test func laterResultsForTheSameSpeechReplaceIt() {
        var transcript = RequestTranscript()
        transcript.add("Hey Jarvis.", timing: 8.3...8.9)
        transcript.add("Hey Jarvis.", timing: 8.3...8.9)
        transcript.add("What is the status?", timing: 10...11.5)
        #expect(transcript.text == "Hey Jarvis. What is the status?")
        transcript.add("Hey Jarvis, what is the status?", timing: 8.3...11.5)
        #expect(transcript.text == "Hey Jarvis, what is the status?")
    }

    @Test func utterancesThatOnlyTouchAreBothKept() {
        var transcript = RequestTranscript()
        transcript.add("Hey Jarvis.", timing: 8.34...8.97)
        transcript.add("Run the tests.", timing: 8.97...10.2)
        #expect(transcript.text == "Hey Jarvis. Run the tests.")
        #expect(transcript.heardWords)
        transcript.add("", timing: nil)
        #expect(transcript.heardWords)
    }

    @Test func wordTimesFollowTheUtterancesThatEnded() {
        var transcript = RequestTranscript()
        transcript.add("Run the tests.", timing: 10...11.5, words: [.init(text: "Run", start: 10), .init(text: "the", start: 10.4), .init(text: "tests.", start: 10.7)])
        transcript.add("Hey Jarvis.", timing: 8.3...8.9, words: [.init(text: "Hey", start: 8.3), .init(text: "Jarvis.", start: 8.5)])
        transcript.add("And", timing: nil)
        #expect(transcript.words.map(\.text) == ["Hey", "Jarvis.", "Run", "the", "tests."])
        transcript.add("Hey Jarvis, run the tests.", timing: 8.3...11.5, words: [.init(text: "Hey", start: 8.3), .init(text: "Jarvis,", start: 8.5)])
        #expect(transcript.words.map(\.start) == [8.3, 8.5])
    }
}

struct ShortcutClashTests {
    @Test func twoShortcutsCantShareKeys() {
        let mute = Shortcut(keyCode: 46, modifiers: 2048 | 256)
        let skip = Shortcut(keyCode: 1, modifiers: 2048 | 256)
        let all: [Shortcut?] = [mute, nil, skip]
        #expect(Preferences.isTaken(mute, besides: skip, among: all))
        #expect(!Preferences.isTaken(mute, besides: mute, among: all))
        #expect(!Preferences.isTaken(Shortcut(keyCode: 2, modifiers: 2048), besides: nil, among: all))
        #expect(!Preferences.isTaken(nil, besides: skip, among: all))
    }
}
