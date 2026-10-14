import AVFoundation
import Foundation
import Speech
import os

private let log = Logger(subsystem: "local.notchvoice", category: "wakeword")

/// Listens on-device for "Hey orchestrator", then, while a message is being dictated, for "send it" or a pause.
///
/// Recognition runs with `requiresOnDeviceRecognition`, so no audio leaves the Mac. Each recognition request is
/// restarted every 50 seconds (Apple caps a request at about a minute) and after every wake word.
@MainActor
final class WakeWordListener {
    enum Mode {
        case wake, capture
    }

    enum StopReason {
        case stopWord, silence, nothingSaid, timeLimit
    }

    var onWake: () -> Void = {}
    var onStop: (StopReason, String) -> Void = { _, _ in }

    private(set) var isRunning = false
    private(set) var mode = Mode.wake
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let feed = RequestFeed()
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var silenceTimer: Timer?
    private var configObserver: NSObjectProtocol?
    // Capture bookkeeping
    private var captureStart = Date()
    private var lastWordAt: Date?
    private var heard = ""

    static let silenceToStop: TimeInterval = 2
    static let nothingSaidTimeout: TimeInterval = 8
    static let captureLimit: TimeInterval = 120

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && microphone
    }

    func start() {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            log.error("on-device speech recognition is not available")
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let feed = self.feed
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in feed.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            log.error("could not start the microphone: \(error.localizedDescription)")
            return
        }
        isRunning = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Another app (Wispr Flow) grabbing the mic or a device change stops the engine; start it again.
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.stop()
                self.start()
            }
        }
        startRequest()
        log.info("listening for the wake word")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        restartTimer?.invalidate()
        silenceTimer?.invalidate()
        task?.cancel()
        task = nil
        feed.set(nil)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        mode = .wake
    }

    /// Switch to listening for the end of a dictated message.
    func beginCapture() {
        mode = .capture
        captureStart = Date()
        lastWordAt = nil
        heard = ""
        startRequest()
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSilence() }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    func endCapture() {
        mode = .wake
        silenceTimer?.invalidate()
        silenceTimer = nil
        if isRunning { startRequest() }
    }

    private func startRequest() {
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Hey orchestrator", "orchestrator", "send it"]
        feed.set(request)
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let failed = error != nil || result?.isFinal == true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    if let text { self.heard(text) }
                    if failed, self.feed.isCurrent(request) { self.startRequest() }
                }
            }
        }
        restartTimer?.invalidate()
        let timer = Timer(timeInterval: 50, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.mode == .wake else { return }
                self.startRequest()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        restartTimer = timer
    }

    private func heard(_ text: String) {
        switch mode {
        case .wake:
            if Self.containsWakeWord(text) {
                log.info("wake word heard")
                onWake()
            }
        case .capture:
            if text != heard {
                heard = text
                lastWordAt = Date()
            }
            if Self.endsWithStopWord(text) { finishCapture(.stopWord) }
        }
    }

    private func checkSilence() {
        guard mode == .capture else { return }
        let now = Date()
        if now.timeIntervalSince(captureStart) > Self.captureLimit {
            finishCapture(.timeLimit)
        } else if let last = lastWordAt {
            if now.timeIntervalSince(last) >= Self.silenceToStop { finishCapture(.silence) }
        } else if now.timeIntervalSince(captureStart) > Self.nothingSaidTimeout {
            finishCapture(.nothingSaid)
        }
    }

    private func finishCapture(_ reason: StopReason) {
        guard mode == .capture else { return }
        let text = heard
        endCapture()
        log.info("capture ended")
        onStop(reason, text)
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z' ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func containsWakeWord(_ text: String) -> Bool {
        normalized(text).range(of: "\\b(hey|hi|hay|a|okay|ok) orchestra(tor|ter|te)?s?\\b", options: .regularExpression) != nil
    }

    nonisolated static func endsWithStopWord(_ text: String) -> Bool {
        normalized(text).range(of: "\\bsend it$", options: .regularExpression) != nil
    }

    /// The dictated message without the stop phrase, e.g. "…that's it for now, send it." → "…that's it for now".
    nonisolated static func strippingStopPhrase(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "[\\s,;:.!-]*\\bsend it[\\s.!]*$"
        while let range = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-").union(.whitespacesAndNewlines))
    }
}

/// Hands audio buffers from the realtime tap to whichever recognition request is current.
private final class RequestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request?.endAudio()
        self.request = request
        lock.unlock()
    }

    func isCurrent(_ request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.request === request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }
}
