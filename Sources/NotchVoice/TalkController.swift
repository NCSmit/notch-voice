import AppKit
import Combine
import os

private let log = Logger(subsystem: "local.notchvoice", category: "talk")

/// Lets the user talk to the orchestrator without its window: by saying "Hey Jarvis", or with the talk shortcut,
/// held down or pressed. The words are recognised on this Mac, or written out by Wispr Flow when that is chosen, and
/// sent through the orchestrator's inbox with `notchvoice_snapshot.py tell`, so the orchestrator answers out loud. None
/// of it works while NotchVoice is off.
@MainActor
final class TalkController: ObservableObject {
    /// What the notch shows while the user talks, and just after.
    enum Card: Equatable {
        case listening(words: String, hint: String)
        case writing(words: String)
        case sending(words: String)
        case sent
        case done(message: String, isError: Bool)
    }

    @Published private(set) var card: Card?

    private enum Phase: Equatable {
        case off, waitingForPhrase, capturing(TalkPolicy.Trigger), finishing(TalkPolicy.Trigger)
    }

    private static let helper = URL.homeDirectory.appending(path: ".claude/hooks/notchvoice_snapshot.py")
    // A request that waits for the wake phrase is replaced well before Apple's limit of about a minute.
    private static let freshRequestAfter: TimeInterval = 45
    // A request that ends this soon without hearing anything has failed, and the next one probably will too.
    private static let quickFailure: TimeInterval = 2
    // How long to wait before trying again to listen for the wake phrase, after the microphone couldn't start.
    private static let restartAfter: TimeInterval = 15

    private let speech = SpeechInput()
    private let wispr = WisprFlow()
    private let preferences: Preferences
    private let dictation: DictationMonitor
    private var phase = Phase.off
    // Published values arrive before the properties change, so the latest of each is kept here.
    private var listens = false
    private var hasOrchestrator = false
    private var isOn = true
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
    private var fallback: Timer?
    private var changes: AnyCancellable?
    // Wispr Flow writes out the message being captured: it was asked to listen, or is listening.
    private var usesWispr = false
    // When the message being captured began, by Apple's word times, once the utterance with its first word has ended.
    private var messageStart: Date?
    // While a message is finishing: Apple's final transcript is in, and what Wispr Flow wrote, "" for nothing.
    private var appleIsDone = false
    private var wisprWrote: String?

    init(sessions: SessionStore, voice: VoiceController, preferences: Preferences, dictation: DictationMonitor) {
        self.preferences = preferences
        self.dictation = dictation
        speech.onText = { [weak self] text, isFinal in self?.heard(text, isFinal: isFinal) }
        speech.onEnded = { [weak self] failed in self?.requestEnded(failed: failed) }
        wispr.onStart = { [weak self] listening in self?.wisprStarted(listening) }
        changes = Publishers.CombineLatest3(
            preferences.$listensForWakePhrase,
            sessions.$sessions.map { $0.contains(where: \.isOrchestrator) }.removeDuplicates(),
            voice.$isEnabled.removeDuplicates()
        )
        .sink { [weak self] listens, hasOrchestrator, isOn in
            MainActor.assumeIsolated { self?.update(listens: listens, hasOrchestrator: hasOrchestrator, isOn: isOn) }
        }
    }

    /// Listening for the wake phrase only runs while it is turned on, NotchVoice is on, and there is an orchestrator
    /// to talk to, so the microphone isn't on for nothing.
    private var isWanted: Bool { listens && hasOrchestrator && isOn }

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

    private func update(listens: Bool, hasOrchestrator: Bool, isOn: Bool) {
        self.listens = listens
        self.hasOrchestrator = hasOrchestrator
        self.isOn = isOn
        switch phase {
        case .off where isWanted:
            Task { await self.beginWaiting() }
        case .off:
            retry?.invalidate()
            retry = nil
        case .waitingForPhrase where !isWanted:
            stopListening()
        case .capturing, .finishing:
            guard !isOn else { break }
            log.info("message not sent: NotchVoice was turned off")
            endCapture()
            show(.done(message: "NotchVoice is off", isError: false), for: 1.5)
        default:
            break
        }
    }

    private func beginWaiting() async {
        // Nobody asked just now, so a missing permission is only logged rather than shown each time this runs.
        let listening = await ensureListening(quietly: true)
        guard phase == .off else { return }
        guard isWanted else {
            // Turned off, or the orchestrator closed, while permission was being asked for.
            if listening, !isStarting { speech.stop() }
            return
        }
        guard listening else { return startWaitingLater() }
        phase = .waitingForPhrase
        freshRequest()
        log.info("waiting for \(TalkPhrases.wakePhrase(self.preferences.wakeName), privacy: .public)")
    }

    /// Tries again later to listen for the wake phrase: the recognizer may not be ready yet at login, permission may
    /// be given later in System Settings, or a microphone that was plugged in may be ready by then.
    private func startWaitingLater() {
        retryLater(after: Self.restartAfter) { controller in
            guard controller.phase == .off, controller.isWanted else { return }
            Task { await controller.beginWaiting() }
        }
    }

    private func stopListening() {
        phase = .off
        retry?.invalidate()
        retry = nil
        freshening?.invalidate()
        freshening = nil
        speech.stop()
    }

    private func start(_ trigger: TalkPolicy.Trigger) {
        let problem = !isOn ? "NotchVoice is off. Turn it on to talk."
            : !hasOrchestrator ? "No orchestrator is open. Type /orchestrator in a Claude Code session first." : nil
        if let problem {
            show(.done(message: problem, isError: true), for: 4)
            NSSound(named: "Basso")?.play()
            return
        }
        isStarting = true
        Task {
            defer { isStarting = false }
            guard await ensureListening(quietly: false) else { return }
            // A "Hey Jarvis" message may have started, or NotchVoice been turned off, while the microphone started.
            guard isOn, phase == .off || phase == .waitingForPhrase else {
                if phase == .off { speech.stop() }
                return
            }
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
        usesWispr = startWispr(saidAlready: words)
        // Words said before Wispr Flow listens would be lost, so with it the sound waits until then.
        if !usesWispr { NSSound(named: "Tink")?.play() }
        showListening()
        ticker?.invalidate()
        let ticker = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        log.info("listening for a message (\(String(describing: trigger)))")
    }

    /// Asks Wispr Flow to write out the message, when it's chosen. False when Apple's recognizer writes it instead.
    private func startWispr(saidAlready words: String) -> Bool {
        guard preferences.transcriber == .wisprFlow, preferences.hasWisprFlow else { return false }
        let problem: String?
        if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problem = "the message began before Wispr Flow was asked to listen"
        } else {
            problem = wispr.start()
        }
        if let problem { log.info("written out on this Mac: \(problem, privacy: .public)") }
        return problem == nil
    }

    private func wisprStarted(_ listening: Bool) {
        guard usesWispr, case .capturing = phase else { return }
        NSSound(named: "Tink")?.play()
        if !listening {
            usesWispr = false
            log.info("written out on this Mac: Wispr Flow didn't start listening")
        } else if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            usesWispr = false
            wispr.cancel(heardWords: true)
            log.info("written out on this Mac: the message began before Wispr Flow was listening")
        } else {
            log.info("Wispr Flow is listening")
        }
    }

    /// Keeps when the message began, by Apple's word times, to tell later whether Wispr Flow heard all of it.
    private func noteMessageStart(_ trigger: TalkPolicy.Trigger) {
        guard usesWispr, messageStart == nil else { return }
        // After the recognizer ended a request mid-message, the next one holds only the message.
        let name = trigger == .phrase && carried.isEmpty ? preferences.wakeName : nil
        messageStart = TalkPhrases.messageStart(in: speech.words, afterWakePhrase: name)
    }

    private func heard(_ text: String, isFinal: Bool) {
        // Recognition is working, so a later failure starts the retry delay afresh.
        if !text.isEmpty { retryDelay = 0 }
        switch phase {
        case .waitingForPhrase:
            if let words = TalkPhrases.afterWakePhrase(in: text, name: preferences.wakeName) { beginCapture(.phrase, words: words) }
        case .capturing(let trigger):
            noteMessageStart(trigger)
            guard let words = messageWords(in: text, trigger), words != heard else { break }
            heard = words
            lastWords = Date()
            showListening()
        case .finishing(let trigger):
            noteMessageStart(trigger)
            heard = messageWords(in: text, trigger) ?? heard
            if isFinal { appleFinished() }
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

    /// The message so far, from the current request's transcript. A "Hey Jarvis" message starts in a request that
    /// also heard what was said before the phrase, so only what follows it counts, and nil means the phrase is gone
    /// from the transcript.
    private func messageWords(in text: String, _ trigger: TalkPolicy.Trigger) -> String? {
        guard trigger == .phrase, carried.isEmpty else { return Self.joined(carried, text) }
        return TalkPhrases.afterWakePhrase(in: text, name: preferences.wakeName)
    }

    /// Lets the recognizer settle on its final transcript, and Wispr Flow write out the message when it is listening,
    /// then sends it. The partial transcript stands in if the final one is slow.
    private func finish() {
        guard case .capturing(let trigger) = phase else { return }
        phase = .finishing(trigger)
        ticker?.invalidate()
        ticker = nil
        speech.finishRequest()
        appleIsDone = false
        wisprWrote = nil
        if usesWispr {
            if wispr.isListening { show(.writing(words: heard.trimmingCharacters(in: .whitespacesAndNewlines))) }
            wispr.finish { [weak self] text in self?.wisprFinished(text) }
        }
        let fallback = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.appleFinished() }
        }
        RunLoop.main.add(fallback, forMode: .common)
        self.fallback = fallback
    }

    private func appleFinished() {
        guard case .finishing = phase else { return }
        appleIsDone = true
        deliverIfReady()
    }

    private func wisprFinished(_ text: String?) {
        guard case .finishing = phase else { return }
        wisprWrote = text ?? ""
        deliverIfReady()
    }

    /// Sends the message being finished, once Apple's transcript is in and, when Wispr Flow writes the message, its
    /// text too.
    private func deliverIfReady() {
        guard case .finishing(let trigger) = phase, appleIsDone else { return }
        guard usesWispr else { return send(heard) }
        guard let wrote = wisprWrote else { return }
        // How long the message had been going when Wispr Flow started listening.
        let headStart = messageStart.flatMap { start in wispr.listeningSince.map { $0.timeIntervalSince(start) } } ?? 0
        if messageStart != nil { log.info("Wispr Flow started listening \(headStart, format: .fixed(precision: 2)) s into the message") }
        let choice = TalkPolicy.wisprMessage(wrote, apple: heard, headStart: headStart,
                                             wakeName: trigger == .phrase ? preferences.wakeName : nil)
        if let reason = choice.appleBecause { log.info("written out on this Mac: \(reason, privacy: .public)") }
        send(choice.words, byWispr: choice.appleBecause == nil)
    }

    /// Ends any message and lets Wispr Flow finish its paste, so it can't land in another app once NotchVoice has
    /// quit. Calls `done` when that's over; false when there was nothing to wait for.
    func prepareToQuit(then done: @escaping @MainActor () -> Void) -> Bool {
        switch phase {
        case .capturing, .finishing:
            log.info("message not sent: NotchVoice is quitting")
            endCapture()
        case .off, .waitingForPhrase:
            break
        }
        return wispr.whenIdle(done)
    }

    private func send(_ words: String, byWispr: Bool = false) {
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
                log.info("message sent (\(message.count) characters, written out \(byWispr ? "by Wispr Flow" : "on this Mac", privacy: .public))")
                show(.sent, for: 1.5)
                NSSound(named: "Pop")?.play()
            }
        }
    }

    /// Back to waiting for the wake phrase, or to not listening at all.
    private func endCapture() {
        ticker?.invalidate()
        ticker = nil
        fallback?.invalidate()
        fallback = nil
        if usesWispr { wispr.cancel(heardWords: !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        usesWispr = false
        messageStart = nil
        appleIsDone = false
        wisprWrote = nil
        heard = ""
        carried = ""
        dictation.hold(false)
        if isWanted {
            phase = .waitingForPhrase
            freshRequest()
        } else {
            stopListening()
        }
    }

    private func freshRequest() {
        retry?.invalidate()
        retry = nil
        freshening?.invalidate()
        freshening = nil
        if phase == .waitingForPhrase, !speech.isRunning {
            // The microphone stopped and couldn't start again, as can happen when one is plugged in or out.
            log.info("the microphone stopped; trying again in \(Self.restartAfter) s")
            phase = .off
            return startWaitingLater()
        }
        requestStarted = Date()
        speech.newRequest()
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
            if failed, Date().timeIntervalSince(requestStarted) < Self.quickFailure {
                retryDelay = min(max(retryDelay * 2, 1), 30)
                log.info("speech recognition stopped at once; trying again in \(self.retryDelay) s")
                retryLater(after: retryDelay) { controller in
                    guard controller.phase == .waitingForPhrase else { return }
                    controller.freshRequest()
                }
            } else {
                retryDelay = 0
                freshRequest()
            }
        case .capturing:
            // Recognition isn't working, so the message ends with what was heard rather than starting request after
            // request that fails.
            if failed, Date().timeIntervalSince(requestStarted) < Self.quickFailure { return usesWispr ? finish() : send(heard) }
            // The recognizer ended this request while the user is still talking, so carry on in a new one.
            carried = heard
            requestStarted = Date()
            speech.newRequest()
        case .finishing:
            appleFinished()
        case .off:
            break
        }
    }

    private func retryLater(after delay: TimeInterval, _ action: @escaping @MainActor (TalkController) -> Void) {
        retry?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
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
            // NotchVoice inherits the environment of whatever opened it, and the helper refuses Claude Code sessions.
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "CLAUDECODE")
            process.environment = environment
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
