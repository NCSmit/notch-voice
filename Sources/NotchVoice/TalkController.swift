import AppKit
import Combine
import os

private let log = Logger(subsystem: "local.notchvoice", category: "talk")

/// Lets the user talk to the orchestrator without its window: by saying "Hey Jarvis", or with the talk shortcut,
/// held down or pressed. The words are recognised on this Mac and sent through the orchestrator's inbox with
/// `notchvoice_snapshot.py tell`, so the orchestrator answers out loud.
@MainActor
final class TalkController: ObservableObject {
    /// What the notch shows while the user talks, and just after.
    enum Card: Equatable {
        case listening(words: String, hint: String)
        case sending(words: String)
        case sent
        case done(message: String, isError: Bool)
    }

    @Published private(set) var card: Card?

    private enum Phase: Equatable {
        case off, waitingForPhrase, capturing(TalkPolicy.Trigger), finishing
    }

    private static let helper = URL.homeDirectory.appending(path: ".claude/hooks/notchvoice_snapshot.py")
    // A request that waits for the wake phrase is replaced well before Apple's limit of about a minute.
    private static let freshRequestAfter: TimeInterval = 45

    private let speech = SpeechInput()
    private let preferences: Preferences
    private let dictation: DictationMonitor
    private var phase = Phase.off
    private var hasOrchestrator = false
    private var isShortcutHeld = false
    // A capture is on its way (waiting for permission or the microphone), so presses don't start a second one.
    private var isStarting = false
    private var heard = ""
    // Words from earlier requests in the same message, when the recognizer ended one while the user kept talking.
    private var carried = ""
    private var requestStarted = Date()
    private var retryDelay: TimeInterval = 0
    private var retry: Timer?
    private var captureStarted = Date()
    private var lastWords = Date()
    private var ticker: Timer?
    private var freshening: Timer?
    private var cardTimer: Timer?
    private var finalText: ((String) -> Void)?
    private var changes: AnyCancellable?

    init(sessions: SessionStore, preferences: Preferences, dictation: DictationMonitor) {
        self.preferences = preferences
        self.dictation = dictation
        speech.onText = { [weak self] text, isFinal in self?.heard(text, isFinal: isFinal) }
        speech.onEnded = { [weak self] failed in self?.requestEnded(failed: failed) }
        changes = preferences.$listensForWakePhrase
            .combineLatest(sessions.$sessions.map { $0.contains(where: \.isOrchestrator) }.removeDuplicates())
            .sink { [weak self] listens, hasOrchestrator in
                MainActor.assumeIsolated { self?.update(listens: listens, hasOrchestrator: hasOrchestrator) }
            }
    }

    // MARK: Starting

    func shortcutPressed() {
        isShortcutHeld = true
        guard !isStarting else { return }
        switch (preferences.talkMode, phase) {
        case (.press, .capturing(.press)):
            finish()
        case (_, .capturing), (_, .finishing):
            break
        default:
            start(preferences.talkMode == .hold ? .hold : .press)
        }
    }

    func shortcutReleased() {
        isShortcutHeld = false
        if phase == .capturing(.hold) { finish() }
    }

    func cancel() {
        guard case .capturing = phase else { return }
        log.info("message not sent: closed with the button")
        endCapture()
        show(.done(message: "Cancelled", isError: false), for: 1.5)
        NSSound(named: "Pop")?.play()
    }

    /// Listening for the wake phrase only runs while it is turned on and there is an orchestrator to talk to, so the
    /// microphone isn't on for nothing.
    private func update(listens: Bool, hasOrchestrator: Bool) {
        self.hasOrchestrator = hasOrchestrator
        let wanted = listens && hasOrchestrator
        switch phase {
        case .off where wanted:
            Task { await self.beginWaiting() }
        case .waitingForPhrase where !wanted:
            phase = .off
            freshening?.invalidate()
            freshening = nil
            speech.stop()
        default:
            break
        }
    }

    private func beginWaiting() async {
        // Nobody asked just now, so a missing permission is only logged rather than shown each time this runs.
        guard await ensureListening(quietly: true) else { return }
        guard phase == .off else { return }
        phase = .waitingForPhrase
        freshRequest()
        log.info("waiting for \(TalkPhrases.wakePhrase(self.preferences.wakeName), privacy: .public)")
    }

    private func start(_ trigger: TalkPolicy.Trigger) {
        guard hasOrchestrator else {
            show(.done(message: "No orchestrator is open. Type /orchestrator in a Claude Code session first.", isError: true), for: 4)
            NSSound(named: "Basso")?.play()
            return
        }
        isStarting = true
        Task {
            defer { isStarting = false }
            guard await ensureListening(quietly: false) else { return }
            if trigger != .phrase { freshRequest() }
            beginCapture(trigger)
            // The keys may have been let go while the microphone was starting.
            if trigger == .hold, !isShortcutHeld { finish() }
        }
    }

    /// Starts the microphone if it isn't running, asking for permission the first time.
    private func ensureListening(quietly: Bool) async -> Bool {
        if speech.isRunning { return true }
        var problem: String
        if !SpeechInput.isAuthorized, !(await SpeechInput.authorize()) {
            problem = "Allow NotchVoice the microphone and speech recognition in System Settings › Privacy & Security."
        } else {
            do {
                try speech.start()
                return true
            } catch SpeechInput.Problem.unavailable {
                problem = "On-device speech recognition isn't available. Turn on Dictation in Keyboard settings."
            } catch {
                problem = "Couldn't use the microphone."
                log.error("could not start listening: \(String(describing: error))")
            }
        }
        log.info("not listening: \(problem, privacy: .public)")
        if !quietly { show(.done(message: problem, isError: true), for: 5) }
        return false
    }

    // MARK: Capturing

    private func beginCapture(_ trigger: TalkPolicy.Trigger, words: String = "") {
        phase = .capturing(trigger)
        heard = words
        carried = ""
        captureStarted = Date()
        lastWords = Date()
        // Replies wait while the user speaks, the same way they do for dictation apps.
        dictation.hold(true)
        NSSound(named: "Tink")?.play()
        showListening()
        ticker?.invalidate()
        let ticker = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        log.info("listening for a message (\(String(describing: trigger)))")
    }

    private func heard(_ text: String, isFinal: Bool) {
        // Recognition is working, so a later failure starts the retry delay afresh.
        if !text.isEmpty { retryDelay = 0 }
        switch phase {
        case .waitingForPhrase:
            if let words = TalkPhrases.afterWakePhrase(in: text, name: preferences.wakeName) { beginCapture(.phrase, words: words) }
        case .capturing(let trigger):
            let latest = trigger == .phrase && carried.isEmpty ? TalkPhrases.afterWakePhrase(in: text, name: preferences.wakeName) : text
            guard let latest else { break }
            let words = Self.joined(carried, latest)
            if words != heard {
                heard = words
                lastWords = Date()
                showListening()
            }
        case .finishing:
            let latest = carried.isEmpty ? TalkPhrases.afterWakePhrase(in: text, name: preferences.wakeName) ?? text : text
            let words = Self.joined(carried, latest)
            if isFinal, let finalText {
                self.finalText = nil
                finalText(words)
            } else {
                heard = words
            }
        case .off:
            break
        }
    }

    private func tick() {
        guard case .capturing(let trigger) = phase else { return }
        let now = Date()
        switch TalkPolicy.decide(trigger, heard: heard, sinceStart: now.timeIntervalSince(captureStarted),
                                 sinceLastWords: now.timeIntervalSince(lastWords)) {
        case .keepListening:
            break
        case .send:
            finish()
        case .nothingSaid:
            log.info("message not sent: nothing was said")
            endCapture()
            show(.done(message: "Didn't hear anything", isError: false), for: 1.5)
            NSSound(named: "Pop")?.play()
        }
    }

    /// Lets the recognizer settle on its final transcript, then sends it. The partial transcript stands in if the
    /// final one is slow.
    private func finish() {
        guard case .capturing = phase else { return }
        phase = .finishing
        ticker?.invalidate()
        ticker = nil
        var delivered = false
        let deliver: (String) -> Void = { [weak self] words in
            guard let self, !delivered else { return }
            delivered = true
            self.send(words)
        }
        finalText = deliver
        speech.finishRequest()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .finishing else { return }
                self.finalText = nil
                deliver(self.heard)
            }
        }
    }

    private func send(_ words: String) {
        endCapture()
        guard let message = TalkPhrases.message(from: words) else {
            log.info("message not sent: \(words.isEmpty ? "nothing was heard" : "it was cancelled", privacy: .public)")
            show(.done(message: words.isEmpty ? "Didn't hear anything" : "Cancelled", isError: false), for: 1.5)
            NSSound(named: "Pop")?.play()
            return
        }
        show(.sending(words: message))
        Task {
            let failure = await Self.tell(message)
            if let failure {
                log.info("message not sent: \(failure, privacy: .public)")
                show(.done(message: failure, isError: true), for: 4)
                NSSound(named: "Basso")?.play()
            } else {
                log.info("message sent (\(message.count) characters)")
                show(.sent, for: 1.5)
                NSSound(named: "Pop")?.play()
            }
        }
    }

    /// Back to waiting for the wake phrase, or to not listening at all.
    private func endCapture() {
        ticker?.invalidate()
        ticker = nil
        finalText = nil
        heard = ""
        carried = ""
        dictation.hold(false)
        if preferences.listensForWakePhrase && hasOrchestrator {
            phase = .waitingForPhrase
            freshRequest()
        } else {
            phase = .off
            freshening?.invalidate()
            freshening = nil
            speech.stop()
        }
    }

    private func freshRequest() {
        retry?.invalidate()
        retry = nil
        requestStarted = Date()
        speech.newRequest()
        freshening?.invalidate()
        freshening = nil
        guard phase == .waitingForPhrase else { return }
        let timer = Timer(timeInterval: Self.freshRequestAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .waitingForPhrase else { return }
                self.freshRequest()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        freshening = timer
    }

    private func requestEnded(failed: Bool) {
        switch phase {
        case .waitingForPhrase:
            // A request that fails straight away without hearing anything will keep failing, so wait longer before
            // each new one.
            if failed, Date().timeIntervalSince(requestStarted) < 2 {
                retryDelay = min(max(retryDelay * 2, 1), 30)
                log.info("speech recognition stopped at once; trying again in \(self.retryDelay) s")
                retry?.invalidate()
                let timer = Timer(timeInterval: retryDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.phase == .waitingForPhrase else { return }
                        self.freshRequest()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                retry = timer
            } else {
                retryDelay = 0
                freshRequest()
            }
        case .capturing:
            // The recognizer ended this request while the user is still talking, so carry on in a new one.
            carried = heard
            requestStarted = Date()
            speech.newRequest()
        case .finishing:
            if let finalText {
                self.finalText = nil
                finalText(heard)
            }
        case .off:
            break
        }
    }

    // MARK: Sending

    /// Runs `notchvoice_snapshot.py tell`, which checks there is an orchestrator and drops the message in its inbox.
    /// Returns what went wrong, or nil when the message was sent.
    private static func tell(_ message: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            // The message goes in as an argument, not through a pipe, which would end the app if the helper quit
            // before reading it.
            process.arguments = ["python3", "-I", helper.path, "tell", "--source", "voice", "--", message]
            let errors = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            process.terminationHandler = { process in
                let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: process.terminationStatus == 0 ? nil : output.isEmpty ? "Couldn't reach the orchestrator" : output)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: "Couldn't reach the orchestrator")
            }
        }
    }

    private static func joined(_ earlier: String, _ latest: String) -> String {
        [earlier, latest].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: The notch card

    private func showListening() {
        guard case .capturing(let trigger) = phase else { return }
        let shortcut = preferences.talkShortcut?.displayName ?? "the shortcut"
        let hint = switch trigger {
        case .hold: "Let go of \(shortcut) to send"
        case .press: "Pause or press \(shortcut) to send"
        case .phrase: "Pause to send. Say \u{201C}cancel\u{201D} to stop."
        }
        show(.listening(words: heard.trimmingCharacters(in: .whitespacesAndNewlines), hint: hint))
    }

    private func show(_ card: Card, for seconds: TimeInterval? = nil) {
        cardTimer?.invalidate()
        cardTimer = nil
        self.card = card
        guard let seconds else { return }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.card == card else { return }
                self.card = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cardTimer = timer
    }
}
