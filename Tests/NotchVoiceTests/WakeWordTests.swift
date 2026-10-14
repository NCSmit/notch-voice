import Testing
@testable import NotchVoice

struct WakeWordTests {
    @Test func hearsTheWakeWordInTheWaysItGetsTranscribed() {
        #expect(WakeWordListener.containsWakeWord("Hey orchestrator"))
        #expect(WakeWordListener.containsWakeWord("so yeah. Hey, Orchestrator!"))
        #expect(WakeWordListener.containsWakeWord("hey orchestra"))
        #expect(WakeWordListener.containsWakeWord("OK orchestrator"))
        #expect(WakeWordListener.containsWakeWord("Orchestra"))
        #expect(WakeWordListener.containsWakeWord("Orchestrator."))
        #expect(!WakeWordListener.containsWakeWord("the orchestrator said the build passed"))
        #expect(!WakeWordListener.containsWakeWord("Microphone Orchestra literally that's how I sent this"))
        #expect(!WakeWordListener.containsWakeWord("hey there"))
    }

    @Test func notices_sendIt_onlyAtTheEnd() {
        #expect(WakeWordListener.endsWithStopWord("ship the fix, send it"))
        #expect(WakeWordListener.endsWithStopWord("Send it."))
        #expect(!WakeWordListener.endsWithStopWord("send it to the team and then wait"))
    }

    @Test func cancelThatAtTheEndAbortsButNotMidSentence() {
        #expect(WakeWordListener.endsWithAbortWord("no wait, cancel that"))
        #expect(WakeWordListener.endsWithAbortWord("Cancel that."))
        #expect(!WakeWordListener.endsWithAbortWord("cancel that meeting and send it"))
    }

    @Test func spokenSkipOnlyAsAWholePhrase() {
        #expect(WakeWordListener.skipCommand("Skip") == false)
        #expect(WakeWordListener.skipCommand("Orchestrator, skip.") == false)
        #expect(WakeWordListener.skipCommand("next") == false)
        #expect(WakeWordListener.skipCommand("Skip all") == true)
        #expect(WakeWordListener.skipCommand("hey orchestrator stop everything") == true)
        #expect(WakeWordListener.skipCommand("we can skip the tests for now") == nil)
    }

    @Test func stripsTheStopPhraseButKeepsTheMessage() {
        #expect(WakeWordListener.strippingStopPhrase("Tell the quote session to merge. That's it for now, send it.") == "Tell the quote session to merge. That's it for now")
        #expect(WakeWordListener.strippingStopPhrase("merge it send it") == "merge it")
        #expect(WakeWordListener.strippingStopPhrase("Send it") == "")
        #expect(WakeWordListener.strippingStopPhrase("send it to Bugbot first") == "send it to Bugbot first")
    }
}

struct VoicePhraseTests {
    @Test func customPhrasesAreHeard() {
        var phrases = VoicePhrases.defaults
        phrases.wake = "hey jarvis"
        phrases.send = "over and out"
        phrases.cancel = "never mind"
        #expect(phrases.isWake("hey Jarvis"))
        #expect(phrases.isWake("Jarvis"))  // the recognizer dropped the "hey"
        #expect(!phrases.isWake("ask jarvis about it later"))
        #expect(phrases.endsWithSend("ship it. Over and out."))
        #expect(phrases.strippingSend("ship it. Over and out.") == "ship it")
        #expect(phrases.endsWithCancel("oh never mind"))
        #expect(phrases.skipCommand("jarvis skip") == false)
    }

    @Test func theAssistantIsNamedAfterTheWakePhrase() {
        var phrases = VoicePhrases.defaults
        #expect(phrases.assistantName == "Orchestrator")
        phrases.wake = "hey computer"
        #expect(phrases.assistantName == "Computer")
        phrases.wake = "computer mainframe"
        #expect(phrases.assistantName == "Computer Mainframe")
    }

    @Test func emptyOrDuplicatePhrasesAreRejected() {
        var phrases = VoicePhrases.defaults
        #expect(phrases.problem == nil)
        phrases.send = "  "
        #expect(phrases.problem == "Send phrase can't be empty.")
        phrases.send = "Cancel that!"
        #expect(phrases.problem == "Send and cancel phrases are the same.")
    }
}
