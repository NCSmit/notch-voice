import AVFoundation
import CoreAudio
import Speech
import os

private let log = Logger(subsystem: "local.notchvoice", category: "talk")

/// Turns what the microphone hears into text, on this Mac only.
///
/// One audio engine runs while listening. Each recognition request covers one stretch of speech: a new one starts
/// when a message starts, after a message is sent, and before Apple's limit of about a minute per request. The
/// built-in microphone is used when there is one, so Bluetooth headphones aren't switched into call mode, which would
/// lower the quality of everything they play.
@MainActor
final class SpeechInput {
    enum Problem: Error {
        case notAllowed, unavailable, microphone(String)
    }

    /// The transcript of the current request so far, and whether it is the final one.
    var onText: (String, Bool) -> Void = { _, _ in }
    /// The current request ended by itself, so a new one is needed to keep listening. True when it failed before
    /// hearing anything, which happens over and over while recognition can't work.
    var onEnded: (Bool) -> Void = { _ in }

    private(set) var isRunning = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let feed = RequestFeed()
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var transcript = RequestTranscript()
    private var configChanges: NSObjectProtocol?

    // These callbacks come on background threads, so none of them may be tied to the main actor; Swift stops the app
    // when a main-actor closure runs anywhere else.
    nonisolated static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && microphone
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start() throws {
        guard !isRunning else { return }
        guard Self.isAuthorized else { throw Problem.notAllowed }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw Problem.unavailable }
        useBuiltInMicrophone()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let feed = self.feed
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in feed.append(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Problem.microphone(error.localizedDescription)
        }
        isRunning = true
        configChanges = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // A microphone was plugged in or out, which stops the engine. Start again on whatever is there now.
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.stop()
                try? self.start()
                self.onEnded(false)
            }
        }
        log.info("listening")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        task?.cancel()
        task = nil
        feed.set(nil)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let configChanges { NotificationCenter.default.removeObserver(configChanges) }
        configChanges = nil
        log.info("stopped listening")
    }

    /// Starts a new request, so the transcript from here on holds only what is said from now. Listening starts with
    /// no request; whoever starts listening asks for the first one, so two never start back to back.
    func newRequest() {
        guard isRunning, let recognizer else { return }
        task?.cancel()
        generation += 1
        let current = generation
        transcript = RequestTranscript()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        feed.set(request)
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let timing = result.flatMap { RequestTranscript.timing(of: $0.bestTranscription.segments) }
            let isFinal = result?.isFinal ?? false
            let ended = isFinal || error != nil
            let failed = error != nil
            if let error { log.info("recognition request ended: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, current == self.generation else { return }
                    if let text {
                        self.transcript.add(text, timing: timing)
                        self.onText(self.transcript.text, isFinal)
                    }
                    // Handling the text may already have started the next request; this ending is then the old one's.
                    guard ended, current == self.generation else { return }
                    self.task = nil
                    self.onEnded(failed && !self.transcript.heardWords)
                }
            }
        }
    }

    /// Stops feeding the current request so the recognizer settles on its final transcript.
    func finishRequest() {
        feed.finish()
    }

    /// Points the engine at the built-in microphone, if this Mac has one.
    private func useBuiltInMicrophone() {
        guard var device = Self.builtInMicrophone(), let unit = engine.inputNode.audioUnit else { return }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { log.error("could not choose the built-in microphone: \(status)") }
    }

    private static func builtInMicrophone() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == noErr && streamsSize > 0
        }
    }
}

/// Everything a recognition request has heard so far. Recognition on this Mac reports one utterance at a time: after a
/// pause it starts a new transcript, and it marks the utterance that just ended by giving its words their times. So the
/// utterances that ended are kept here in order, with the one in progress after them, and "Hey Jarvis", a pause and
/// then the message still read as one.
struct RequestTranscript {
    private struct Utterance {
        let time: ClosedRange<TimeInterval>
        let text: String
    }

    private var ended: [Utterance] = []
    private var inProgress = ""
    private(set) var heardWords = false

    var text: String {
        (ended.map(\.text) + [inProgress]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// When the words of an ended utterance were said, from the start of the request. Nil while it is in progress,
    /// when its words have no times yet.
    static func timing(of segments: [SFTranscriptionSegment]) -> ClosedRange<TimeInterval>? {
        guard let first = segments.first, let last = segments.last, segments.contains(where: { $0.duration > 0 }) else { return nil }
        return first.timestamp...max(first.timestamp, last.timestamp + last.duration)
    }

    /// Takes in one result. A later result for the same stretch of speech, such as the final one, replaces what it covers.
    mutating func add(_ text: String, timing: ClosedRange<TimeInterval>?) {
        if !text.isEmpty { heardWords = true }
        guard let timing else {
            inProgress = text
            return
        }
        // Utterances that only touch at an end are separate ones.
        ended.removeAll { $0.time.lowerBound < timing.upperBound && timing.lowerBound < $0.time.upperBound }
        ended.append(Utterance(time: timing, text: text))
        ended.sort { $0.time.lowerBound < $1.time.lowerBound }
        inProgress = ""
    }
}

/// Hands audio from the engine's real-time thread to whichever request is current.
private final class RequestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock {
            self.request?.endAudio()
            self.request = request
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }

    func finish() {
        lock.withLock {
            request?.endAudio()
            request = nil
        }
    }
}
