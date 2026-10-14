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

    @Test func stripsTheStopPhraseButKeepsTheMessage() {
        #expect(WakeWordListener.strippingStopPhrase("Tell the quote session to merge. That's it for now, send it.") == "Tell the quote session to merge. That's it for now")
        #expect(WakeWordListener.strippingStopPhrase("merge it send it") == "merge it")
        #expect(WakeWordListener.strippingStopPhrase("Send it") == "")
        #expect(WakeWordListener.strippingStopPhrase("send it to Bugbot first") == "send it to Bugbot first")
    }
}
