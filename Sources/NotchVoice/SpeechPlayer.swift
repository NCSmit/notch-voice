import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "player")

/// Plays spoken replies that speak.py rendered to a file, and keeps them clean when the audio route changes.
///
/// `say` playing straight to the device keeps the output format it started with. When AirPods switch between their
/// music mode (48 kHz stereo) and call mode (16–24 kHz mono) mid-reply, for example because Wispr or the wake word
/// opened their mic, that produced slow, deep, garbled speech. Here every route or format change rebuilds the audio
/// engine against the new output and carries on from the same spot, and pausing for dictation is a real pause.
@MainActor
final class SpeechPlayer: ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var session: String?

    static let socketPath = URL(filePath: NSTemporaryDirectory()).appending(path: "notchvoice_player.sock").path

    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    @Published private(set) var isPaused = false
    private var generation = 0
    private var connection: PermissionConnection?
    private var configObserver: NSObjectProtocol?
    private var rebuildWork: DispatchWorkItem?

    private lazy var server = PermissionServer(
        path: Self.socketPath,
        label: "local.notchvoice.player",
        onRequest: { [weak self] connection, line in
            let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            let path = request["path"] as? String
            let session = request["session_id"] as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let path else { return connection.reply("error") }
                    self.play(URL(filePath: path), session: session, connection: connection)
                }
            }
        },
        onClose: { [weak self] connection in
            // The hook went away (its Stop hook timed out or was killed): stop its reply too.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.connection?.id == connection.id else { return }
                    self.finish(reply: nil)
                }
            }
        }
    )

    func start() {
        server.start()
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        isPaused = true
        node?.pause()
        log.info("paused")
    }

    func resume() {
        guard isSpeaking, isPaused else { return }
        isPaused = false
        node?.play()
        log.info("resumed")
    }

    /// Stop the current reply (voice replies switched off).
    func stop() {
        guard isSpeaking else { return }
        finish(reply: "stopped")
    }

    private func play(_ url: URL, session: String?, connection: PermissionConnection) {
        if isSpeaking { finish(reply: "stopped") }
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            log.error("could not open the reply audio: \(error.localizedDescription, privacy: .public)")
            return connection.reply("error")
        }
        self.connection = connection
        self.session = session
        startFrame = 0
        isSpeaking = true
        build()
        observeRouteChanges()
    }

    private func build() {
        guard let file else { return }
        let remaining = AVAudioFrameCount(max(0, file.length - startFrame))
        guard remaining > 0 else { return finish(reply: "done") }
        generation += 1
        let current = generation
        // A fresh engine each time, so it picks up the output's current format; the mixer converts to it.
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: remaining, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.finish(reply: "done")
                }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            log.error("could not start playback: \(error.localizedDescription, privacy: .public)")
            return finish(reply: "error")
        }
        if !isPaused { node.play() }
        self.engine = engine
        self.node = node
        log.info("playing from frame \(self.startFrame, privacy: .public) at \(engine.outputNode.outputFormat(forBus: 0).sampleRate, privacy: .public) Hz output")
    }

    private func observeRouteChanges() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        // Posted when the output device or its format changes (AirPods into or out of call mode, a new default
        // device). Any engine posts it; rebuild once things settle.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            let changed = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.isSpeaking, let engine = self.engine, changed == ObjectIdentifier(engine) else { return }
                self.rebuildWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.rebuild() }
                }
                self.rebuildWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }
    }

    private func rebuild() {
        guard isSpeaking else { return }
        let position = currentFrame()
        log.info("audio route changed; picking up again at frame \(position, privacy: .public)")
        teardown()
        startFrame = position
        build()
    }

    private func currentFrame() -> AVAudioFramePosition {
        guard let node, let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime > 0 else { return startFrame }
        return startFrame + playerTime.sampleTime
    }

    private func teardown() {
        generation += 1
        rebuildWork?.cancel()
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
    }

    private func finish(reply: String?) {
        teardown()
        if let reply { connection?.reply(reply) }
        connection = nil
        file = nil
        isPaused = false
        isSpeaking = false
        session = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
    }
}
