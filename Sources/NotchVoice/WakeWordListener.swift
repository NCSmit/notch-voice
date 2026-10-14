import AppKit
import AVFoundation
import CoreAudio
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
        case stopWord, silence, nothingSaid, timeLimit, aborted
    }

    var onWake: () -> Void = {}
    var onStop: (StopReason, String) -> Void = { _, _ in }
    /// Listening stopped by itself (for example Dictation is off); the controller shows why and retries later.
    var onUnavailable: (String) -> Void = { _ in }
    /// The live transcript of the message being dictated, for the notch to show.
    var onTranscript: (String) -> Void = { _ in }
    /// "Skip" (true = "skip all") said as a whole phrase while a reply is being read aloud.
    var onSkip: (Bool) -> Void = { _ in }
    /// Whether a reply is being read aloud right now; spoken skips only count then.
    var isSpeaking: () -> Bool = { false }
    /// A whole phrase that may answer the question card on screen; returns true when it did.
    var answerQuestion: (String) -> Bool = { _ in false }

    private(set) var isRunning = false
    private(set) var mode = Mode.wake
    /// The latest transcript, so the notch can show what it hears.
    private(set) var lastHeard = ""
    /// Transcript updates since start, for the diagnostics heartbeat.
    private var heardCount = 0
    private var heartbeat: Timer?
    private var unavailableNote: String?
    private var recentFailures: [Date] = []
    private var pendingWake: DispatchWorkItem?
    private var startedAt = Date.distantPast
    private var restartWork: DispatchWorkItem?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var captureSession: AVCaptureSession?
    private let audioQueue = DispatchQueue(label: "local.notchvoice.wakeword.audio")
    private let feed = RequestFeed()
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var silenceTimer: Timer?
    private var runtimeObserver: NSObjectProtocol?
    // Capture bookkeeping
    private var captureStart = Date()
    private var lastWordAt: Date?
    private var heard = ""
    // Apple's recognizer ends a segment at every pause; finished segments of the message are kept here.
    private var committed = ""
    private var transcript: String { [committed, heard].filter { !$0.isEmpty }.joined(separator: " ") }

    static let silenceToStop: TimeInterval = 2
    static let nothingSaidTimeout: TimeInterval = 8
    static let captureLimit: TimeInterval = 120

    /// Why listening can't start, in words the user can act on; nil when it can.
    static func requestPermissions() async -> String? {
        log.info("checking permissions: speech=\(SFSpeechRecognizer.authorizationStatus().rawValue, privacy: .public) microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue, privacy: .public) (3 = allowed)")
        // An accessory app's permission prompt can open behind other windows; come forward so the user sees it.
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            NSApp.activate()
        }
        let speechStatus = SFSpeechRecognizer.authorizationStatus() == .notDetermined
            ? await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            : SFSpeechRecognizer.authorizationStatus()
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            ? await AVCaptureDevice.requestAccess(for: .audio)
            : AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        log.info("permissions: speech=\(speechStatus.rawValue, privacy: .public) (3 = allowed), microphone=\(microphone, privacy: .public)")
        if speechStatus != .authorized {
            return "Speech Recognition is off for NotchVoice. Turn it on in System Settings › Privacy & Security › Speech Recognition."
        }
        if !microphone {
            return "The microphone is off for NotchVoice. Turn it on in System Settings › Privacy & Security › Microphone."
        }
        return nil
    }

    /// Why the recognizer can't run on this Mac right now, or nil.
    /// macOS keeps Apple's recognizer off while Dictation is off (System Settings › Keyboard › Dictation).
    nonisolated static var isDictationEnabled: Bool {
        UserDefaults(suiteName: "com.apple.assistant.support")?.object(forKey: "Dictation Enabled") as? Bool ?? true
    }

    func unavailableReason() -> String? {
        if !Self.isDictationEnabled {
            return "Apple's speech recognizer only runs while Dictation is on. Turn it on in System Settings › Keyboard › Dictation (you can set its shortcut to Off)."
        }
        if let unavailableNote { return unavailableNote }
        guard let recognizer else { return "Speech recognition doesn't support English (US) here." }
        log.info("recognizer: available=\(recognizer.isAvailable, privacy: .public) onDevice=\(recognizer.supportsOnDeviceRecognition, privacy: .public)")
        if !recognizer.supportsOnDeviceRecognition {
            return "On-device English recognition isn't installed. Add English (US) under System Settings › Keyboard › Dictation, then wait for the download."
        }
        if !recognizer.isAvailable { return "Speech recognition is busy or unavailable right now; retrying." }
        return nil
    }

    /// The microphone in use, so the controller can tell when it should switch.
    private(set) var device: AVCaptureDevice?

    /// Start listening on `device`, or by default on the built-in (or another wired) mic.
    func start(on chosen: AVCaptureDevice? = nil) {
        guard !isRunning else { return }
        unavailableNote = nil
        if let reason = unavailableReason() {
            log.error("not listening: \(reason, privacy: .public)")
            return
        }
        // Listen on a wired or built-in mic. Holding a Bluetooth headset's mic open (AirPods) forces it into call mode,
        // which turns all its audio, spoken replies and music included, into crackly low-quality sound.
        guard let device = chosen ?? Self.nonBluetoothMicrophone() else {
            log.error("not listening: only Bluetooth microphones are available")
            unavailableNote = "Only a Bluetooth microphone is available, and listening on it would make your headphones sound like a phone call. Open the MacBook lid or connect a wired mic."
            return
        }
        // AVCaptureSession records from one chosen device without touching the system default. (Switching an
        // AVAudioEngine's input device left it with a stale format and threw exceptions Swift can't catch.)
        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
            session.addInput(input)
        } catch {
            log.error("could not open \(device.localizedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(feed, queue: audioQueue)
        guard session.canAddOutput(output) else {
            log.error("could not read audio from \(device.localizedName, privacy: .public)")
            return
        }
        session.addOutput(output)
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] _ in
            // The mic went away or another app took it exclusively; start again once things settle.
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.restartWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.isRunning, self.mode == .wake else { return }
                        self.stop()
                        self.start()
                    }
                }
                self.restartWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            }
        }
        captureSession = session
        self.device = device
        session.startRunning()
        log.info("listening on \(device.localizedName, privacy: .public)")
        isRunning = true
        startedAt = Date()
        startRequest()
        log.info("listening for the wake word")
        heartbeat?.invalidate()
        let beat = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                log.info("still listening: \(self.feed.buffers, privacy: .public) audio buffers, \(self.heardCount, privacy: .public) transcript updates; last heard: \(self.lastHeard.suffix(60), privacy: .public)")
            }
        }
        RunLoop.main.add(beat, forMode: .common)
        heartbeat = beat
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        restartWork?.cancel()
        restartTimer?.invalidate()
        silenceTimer?.invalidate()
        heartbeat?.invalidate()
        task?.cancel()
        task = nil
        feed.set(nil)
        captureSession?.stopRunning()
        captureSession = nil
        device = nil
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        runtimeObserver = nil
        mode = .wake
    }

    /// Switch to listening for the end of a dictated message.
    func beginCapture() {
        pendingWake?.cancel()
        pendingWake = nil
        mode = .capture
        captureStart = Date()
        lastWordAt = nil
        heard = ""
        committed = ""
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
        request.contextualStrings = VoicePhrases.current.recognizerHints
        feed.set(request)
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            let nsError = error.map { $0 as NSError }
            let text = result?.bestTranscription.formattedString
            let failed = error != nil || result?.isFinal == true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A cancelled request can still deliver a late result; it belongs to the previous phase (a
                    // trailing "hey orchestrator" once capture began), so drop it.
                    guard let self, self.isRunning, self.feed.isCurrent(request) else { return }
                    if let text { self.heard(text) }
                    guard failed else { return }
                    if self.mode == .capture, !self.heard.isEmpty {
                        self.committed = self.transcript
                        self.heard = ""
                    }
                    if let nsError, self.giveUp(on: nsError) { return }
                    self.startRequest()
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

    /// Stop instead of restarting in a tight loop when recognition keeps failing; say why.
    private func giveUp(on error: NSError) -> Bool {
        log.info("recognition ended: \(error.domain, privacy: .public) \(error.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
        let now = Date()
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 5 } + [now]
        let dictationOff = error.domain == "kLSRErrorDomain" && error.code == 201
        guard dictationOff || recentFailures.count >= 5 else { return false }
        stop()
        unavailableNote = dictationOff
            ? "Apple's speech recognizer only runs while Dictation is on. Turn it on in System Settings › Keyboard › Dictation (you can set its shortcut to Off)."
            : "Speech recognition keeps failing (\(error.localizedDescription)); retrying shortly."
        onUnavailable(unavailableNote!)
        return true
    }

    private func heard(_ text: String) {
        lastHeard = text
        if mode == .capture || Self.containsWakeWord(text) || Self.normalized(text).contains("orches") {
            log.info("heard: \(text, privacy: .public)")
        }
        heardCount += 1
        switch mode {
        case .wake:
            if answerQuestion(text) {
                startRequest()  // clear the phrase so it isn't acted on twice
                return
            }
            if isSpeaking(), let all = Self.skipCommand(text) {
                pendingWake?.cancel()
                pendingWake = nil
                log.info("spoken skip\(all ? " all" : "", privacy: .public)")
                onSkip(all)
                startRequest()  // clear the phrase so it isn't acted on twice
            } else if Self.containsWakeWord(text) {
                if isSpeaking() {
                    // "Hey orchestrator" arrives a moment before a following "skip", so while a reply plays, give
                    // it a second to become "hey orchestrator, skip" before starting a dictation.
                    guard pendingWake == nil else { return }
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.pendingWake != nil, self.mode == .wake else { return }
                            self.pendingWake = nil
                            log.info("wake word heard")
                            self.onWake()
                        }
                    }
                    pendingWake = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
                } else {
                    log.info("wake word heard")
                    onWake()
                }
            }
        case .capture:
            if text != heard {
                heard = text
                lastWordAt = Date()
                onTranscript(transcript)
            }
            if Self.endsWithAbortWord(text) {
                finishCapture(.aborted)
            } else if Self.endsWithStopWord(text) {
                finishCapture(.stopWord)
            }
        }
    }

    private func checkSilence() {
        guard mode == .capture else { return }
        let now = Date()
        if now.timeIntervalSince(captureStart) > Self.captureLimit {
            finishCapture(.timeLimit)
        } else if let last = lastWordAt, !transcript.isEmpty {
            // Only a pause after real words ends the message, never the pause before the user starts talking.
            if now.timeIntervalSince(last) >= Self.silenceToStop { finishCapture(.silence) }
        } else if now.timeIntervalSince(captureStart) > Self.nothingSaidTimeout {
            finishCapture(.nothingSaid)
        }
    }

    private func finishCapture(_ reason: StopReason) {
        guard mode == .capture else { return }
        let text = transcript
        endCapture()
        log.info("capture ended")
        onStop(reason, text)
    }

    /// The Bluetooth headset mic (AirPods), preferring the one that is the system's default input.
    nonisolated static func headphoneMicrophone() -> AVCaptureDevice? {
        let bluetooth = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
            .filter { [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(UInt32(bitPattern: $0.transportType)) }
        let preferred = AVCaptureDevice.default(for: .audio)?.uniqueID
        return bluetooth.first { $0.uniqueID == preferred } ?? bluetooth.first
    }

    nonisolated static func isBluetooth(_ device: AVCaptureDevice) -> Bool {
        [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(UInt32(bitPattern: device.transportType))
    }

    /// Whether the sound goes to headphones (anything but the built-in speakers), so the mic can't hear it.
    nonisolated static func outputIsHeadphones() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport)
        return transport != kAudioDeviceTransportTypeBuiltIn
    }

    /// The built-in mic, or else another wired (non-Bluetooth, non-virtual) one.
    nonisolated static func nonBluetoothMicrophone() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        let wired = devices.filter {
            ![kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate]
                .contains(UInt32(bitPattern: $0.transportType))
        }
        return wired.first { UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn } ?? wired.first
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z' ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // The phrases come from Settings (VoicePhrases.current); these keep the call sites short.
    nonisolated static func containsWakeWord(_ text: String) -> Bool { VoicePhrases.current.isWake(text) }
    nonisolated static func skipCommand(_ text: String) -> Bool? { VoicePhrases.current.skipCommand(text) }
    nonisolated static func endsWithAbortWord(_ text: String) -> Bool { VoicePhrases.current.endsWithCancel(text) }
    nonisolated static func endsWithStopWord(_ text: String) -> Bool { VoicePhrases.current.endsWithSend(text) }
    nonisolated static func strippingStopPhrase(_ text: String) -> String { VoicePhrases.current.strippingSend(text) }
}

/// Hands audio buffers from the realtime tap to whichever recognition request is current.
private final class RequestFeed: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
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

    private(set) var buffers = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let request = self.request
        buffers += 1
        lock.unlock()
        request?.appendAudioSampleBuffer(sampleBuffer)
    }
}
