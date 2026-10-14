import AppKit
import AVFoundation
import Combine
import os

private let log = Logger(subsystem: "local.notchvoice", category: "handsfree")

/// "Hey orchestrator" → Wispr Flow dictates into a box under the notch → "send it" (or a pause) → the text is typed
/// into the orchestrator session as the user's own message.
/// Where the dictated message is shown and typed: the capture field in the notch.
@MainActor
protocol CaptureSurface: AnyObject {
    var captureText: String { get }
    func showCapture(status: String, text: String?)
    func setCaptureStatus(_ status: String)
    func setCaptureTranscript(_ transcript: String)
    func hideCapture()
}

/// "Hey orchestrator" → Wispr Flow dictates into a field in the notch → "send it" (or a pause) → the text is typed
/// into the orchestrator session as the user's own message.
@MainActor
final class HandsFreeController: ObservableObject {
    enum Phase: Equatable {
        case off, listening, capturing, sending
        case failed(String)
    }

    @Published private(set) var phase = Phase.off
    /// Listening through the AirPods (the user is away), for the indicator.
    @Published private(set) var onHeadphones = false
    weak var surface: CaptureSurface?
    private let preferences: Preferences
    private var micTimer: Timer?
    private var headphoneChanges: AnyCancellable?
    /// Away = no keyboard, mouse or trackpad use for this long.
    private static let awayAfter: TimeInterval = 120

    private let listener = WakeWordListener()
    private let dictation: DictationMonitor
    private var previousApp: NSRunningApplication?
    private var enabledChanges: AnyCancellable?
    private var retryTimer: Timer?
    private var isEnabled = false
    private var pasteboardCount = 0

    private static let startWispr = URL(string: "wispr-flow://start-hands-free")!
    private static let stopWispr = URL(string: "wispr-flow://stop-hands-free")!
    /// How long to wait for Wispr's transcript before using Apple's on-device one.
    private static let wisprTextWait: TimeInterval = 4

    init(dictation: DictationMonitor, preferences: Preferences, voice: VoiceController) {
        self.dictation = dictation
        self.preferences = preferences
        listener.isSpeaking = { [weak voice] in voice?.isSpeaking ?? false }
        listener.onSkip = { [weak voice] all in voice?.skip(all: all) }
        listener.onWake = { [weak self] in self?.wake() }
        listener.onStop = { [weak self] reason, heard in self?.captureEnded(reason, heard: heard) }
        listener.onUnavailable = { [weak self] reason in self?.listenerStopped(reason) }
        listener.onTranscript = { [weak self] text in self?.surface?.setCaptureTranscript(text) }
        enabledChanges = preferences.$listensForWakeWord.sink { [weak self] on in
            MainActor.assumeIsolated { self?.setEnabled(on) }
        }
        headphoneChanges = preferences.$listensThroughHeadphones.combineLatest(preferences.$skipsHeadphonesDuringMusic)
            .dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.followUser() } }
            }
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followUser() }
        }
        RunLoop.main.add(timer, forMode: .common)
        micTimer = timer
    }

    // MARK: Arming

    private func setEnabled(_ on: Bool) {
        isEnabled = on
        retryTimer?.invalidate()
        retryTimer = nil
        if on {
            arm()
        } else {
            cancel()
            listener.stop()
            phase = .off
        }
    }

    /// Start listening, or say why not and try again shortly: a permission granted in System Settings, or Dictation
    /// switched on, is picked up without restarting NotchVoice.
    private func arm() {
        log.info("arming hands-free (enabled: \(self.isEnabled, privacy: .public), running: \(self.listener.isRunning, privacy: .public))")
        guard isEnabled, !listener.isRunning else { return }
        Task {
            let reason: String?
            if let permission = await WakeWordListener.requestPermissions() {
                reason = permission
            } else if !WakeWordListener.isDictationEnabled {
                // Don't open the microphone just to fail again; wait for the setting to change.
                reason = listener.unavailableReason()
            } else {
                listener.start(on: chosenMicrophone())
                onHeadphones = listener.device.map(WakeWordListener.isBluetooth) ?? false
                reason = listener.isRunning ? nil : (listener.unavailableReason() ?? "The microphone couldn't be started; retrying.")
            }
            guard isEnabled else { return }
            if let reason {
                log.error("hands-free not armed: \(reason, privacy: .public)")
                phase = .failed(reason)
                scheduleRetry(after: 10)
            } else {
                log.info("hands-free armed")
                phase = .listening
            }
        }
    }

    // MARK: Which microphone

    /// Near the Mac: the built-in mic, so the AirPods stay in full-quality audio. Away (no input for two minutes),
    /// with "Listen through AirPods" on: the AirPods mic, unless music is playing and the music rule is on.
    private func chosenMicrophone() -> AVCaptureDevice? {
        let builtIn = WakeWordListener.nonBluetoothMicrophone()
        guard preferences.listensThroughHeadphones, let headphones = WakeWordListener.headphoneMicrophone() else { return builtIn }
        let away = Self.secondsSinceInput() > Self.awayAfter
        let musicBlocks = preferences.skipsHeadphonesDuringMusic && DictationMonitor.musicIsPlaying()
        if builtIn == nil { return musicBlocks ? nil : headphones }  // lid closed: AirPods are the only mic
        return away && !musicBlocks ? headphones : builtIn
    }

    /// Switch microphones when the user comes and goes. Only between messages, never mid-dictation.
    private func followUser() {
        guard isEnabled, phase == .listening, listener.isRunning, listener.mode == .wake else { return }
        let wanted = chosenMicrophone()
        guard wanted?.uniqueID != listener.device?.uniqueID else { return }
        log.info("switching wake-word mic to \(wanted?.localizedName ?? "none", privacy: .public)")
        listener.stop()
        if let wanted {
            listener.start(on: wanted)
            onHeadphones = WakeWordListener.isBluetooth(wanted)
            if !listener.isRunning { arm() }
        } else {
            onHeadphones = false
            phase = .failed("Paused while music plays: the only mic is your AirPods, and listening would drop the music to call quality.")
            scheduleRetry(after: 10)
        }
    }

    private static func secondsSinceInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.arm() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func listenerStopped(_ reason: String) {
        log.error("hands-free stopped: \(reason, privacy: .public)")
        if phase == .capturing { cancel(reason: "listener stopped") }
        phase = .failed(reason)
        scheduleRetry(after: 30)
    }

    // MARK: Capturing

    private func wake() {
        guard phase == .listening || canRetryFromFailure else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        dictation.hold(true)  // pauses or holds back any reply until the message is sent
        phase = .capturing
        Sound.play(.start)
        surface?.showCapture(status: "Listening \u{2014} \u{201C}send it\u{201D} sends, \u{201C}cancel that\u{201D} throws it away", text: nil)
        listener.beginCapture()
        openQuietly(Self.startWispr)
        log.info("capturing; front app was \(self.previousApp?.localizedName ?? "none", privacy: .public)")
    }

    private var canRetryFromFailure: Bool {
        if case .failed = phase { return listener.isRunning }
        return false
    }

    private func captureEnded(_ reason: WakeWordListener.StopReason, heard: String) {
        guard phase == .capturing else { return }
        if listener.mode == .capture { listener.endCapture() }
        pasteboardCount = NSPasteboard.general.changeCount
        openQuietly(Self.stopWispr)
        if reason == .nothingSaid {
            cancel(reason: "nothing said")
            return
        }
        if reason == .aborted {
            Sound.play(.cancelled)
            cancel(reason: "user said cancel that")
            return
        }
        phase = .sending
        surface?.setCaptureStatus("Sending\u{2026}")
        Task { await finish(fallback: heard) }
    }

    /// The field's Enter: end dictation now, or retry a message that failed to send.
    func sendNow() {
        if phase == .capturing {
            captureEnded(.stopWord, heard: "")
        } else if case .failed = phase, surface?.captureText.isEmpty == false {
            dictation.hold(true)
            phase = .sending
            surface?.setCaptureStatus("Sending\u{2026}")
            Task { await finish(fallback: "") }
        }
    }

    /// The field's Escape.
    func cancelFromField() {
        cancel(reason: "cancelled")
    }

    private func finish(fallback: String) async {
        let (raw, source) = await transcript(fallback: fallback)
        let message = WakeWordListener.strippingStopPhrase(raw)
        log.info("message from \(source, privacy: .public): \(message.count, privacy: .public) characters")
        guard !message.isEmpty else {
            Sound.play(.failed)
            cancel(reason: "empty message")
            return
        }
        do {
            try await OrchestratorDelivery.deliver(message, returnTo: previousApp)
            Sound.play(.sent)
            surface?.hideCapture()
            dictation.hold(false)
            previousApp = nil
            phase = .listening
        } catch {
            log.error("delivery failed: \(String(describing: error), privacy: .public)")
            Sound.play(.failed)
            dictation.hold(false)
            phase = .failed(String(describing: error))
            // Keep the words in the field so nothing is lost: Enter retries, Esc closes.
            surface?.showCapture(status: "\(error) Enter retries, Esc closes.", text: message)
        }
    }

    /// Wispr's transcript lands in the notch field, or on the clipboard when the field didn't have focus. Take
    /// whichever arrives first; if neither does in time, use Apple's on-device transcript.
    private func transcript(fallback: String) async -> (String, String) {
        let deadline = Date().addingTimeInterval(Self.wisprTextWait)
        var last = "", stableSince = Date()
        while Date() < deadline {
            let field = surface?.captureText ?? ""
            if !field.isEmpty {
                // Wispr inserts the whole transcript at once; ending in the stop phrase means it's complete.
                if WakeWordListener.endsWithStopWord(field) { return (field, "Wispr (field)") }
                if field != last {
                    last = field
                    stableSince = Date()
                } else if Date().timeIntervalSince(stableSince) > 0.3 {
                    return (field, "Wispr (field)")
                }
            }
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount != pasteboardCount, let copied = pasteboard.string(forType: .string), !copied.isEmpty {
                return (copied, "Wispr (clipboard)")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return (fallback, "Apple on-device")
    }

    private func cancel(reason: String = "stopped") {
        log.info("capture cancelled: \(reason, privacy: .public)")
        if listener.mode == .capture { listener.endCapture() }
        if phase == .capturing { openQuietly(Self.stopWispr) }
        surface?.hideCapture()
        dictation.hold(false)
        previousApp?.activate()
        previousApp = nil
        if phase != .off { phase = listener.isRunning ? .listening : phase }
    }

    private func openQuietly(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
    }
}

/// Short system sounds, so the user knows what happened without looking.
enum Sound {
    case start, sent, failed, cancelled

    @MainActor
    static func play(_ sound: Sound) {
        let name: String
        switch sound {
        case .start: name = "Tink"
        case .sent: name = "Glass"
        case .failed: name = "Basso"
        case .cancelled: name = "Funk"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
