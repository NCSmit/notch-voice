import AVFoundation
import Combine
import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "voice")

@MainActor
final class VoiceController: ObservableObject {
    static let baseRate = 180.0

    @Published private(set) var isEnabled = true
    @Published private(set) var isSpeaking = false
    @Published private(set) var speakingSession: String?
    @Published private(set) var voiceID: String?
    @Published private(set) var voiceName = "System Voice"
    @Published private(set) var systemVoiceLabel = "System Voice"
    @Published private(set) var speed = 1.0
    @Published private(set) var musicVolume = 0.5
    @Published private(set) var keepsRepliesShort = true
    /// Only the session that ran /orchestrator speaks; it reports on the others.
    @Published private(set) var isOrchestratorMode = false

    // The contract of ~/.claude/hooks/speak.py: it stays silent while the mute file exists, takes its voice, rate
    // and music level from the settings file, and writes "<hook pid> <say pid>" to the owner file while it speaks.
    private let muteFile = URL.homeDirectory.appending(path: ".claude/tts_off")
    private let settingsFile = URL.homeDirectory.appending(path: ".claude/tts_settings.json")
    private let ownerFile = URL(filePath: NSTemporaryDirectory()).appending(path: "claude_tts_owner")
    // The session_id of the reply being spoken, written by the hook next to the owner file.
    private let sessionFile = URL(filePath: NSTemporaryDirectory()).appending(path: "claude_tts_session")
    // "Skip all": replies queued before this time (nanoseconds since 1970) are not spoken.
    private let skipMarker = URL(filePath: NSTemporaryDirectory()).appending(path: "notchvoice_skip_before")
    private let hookScript = URL.homeDirectory.appending(path: ".claude/hooks/speak.py")
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var sample: Process?
    private var isDictating = false
    private var pausedSay: pid_t?
    private var playerChanges: AnyCancellable?
    /// Replies normally play here; a `say` process only plays them when NotchVoice wasn't reachable.
    private(set) var player: SpeechPlayer?

    func attach(_ player: SpeechPlayer) {
        self.player = player
        playerChanges = player.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
    }

    init() {
        loadSettings()
        refresh()
        watchOwnerDirectory()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            try? FileManager.default.removeItem(at: muteFile)
        } else {
            FileManager.default.createFile(atPath: muteFile.path, contents: nil)
            player?.stop()
        }
        refresh()
    }

    /// Skip the rest of the reply being spoken. With `all`, replies already waiting in the queue are dropped too:
    /// speak.py skips any reply whose queue ticket is older than the marker written here.
    func skip(all: Bool = false) {
        if all {
            let nanoseconds = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            try? String(nanoseconds).write(to: skipMarker, atomically: true, encoding: .utf8)
        }
        player?.skip()
        // A reply played by a plain `say` process (NotchVoice wasn't reachable when it started).
        if let sayPid = ownerPids().dropFirst().first, Self.processName(sayPid) == "say" {
            kill(sayPid, SIGTERM)
            kill(sayPid, SIGCONT)
            if pausedSay == sayPid { pausedSay = nil }
        }
        log.info("skipped \(all ? "all replies" : "the current reply", privacy: .public)")
        refresh()
    }

    /// Never talk over the user: a reply already speaking is paused (SIGSTOP) while they dictate and picks up
    /// where it left off afterwards. Replies that haven't started yet wait in speak.py for the dictation flag file.
    func setDictating(_ dictating: Bool) {
        isDictating = dictating
        if dictating { player?.pause() } else { player?.resume() }
        if !dictating, let pid = pausedSay {
            kill(pid, SIGCONT)
            pausedSay = nil
            log.info("resumed say \(pid) after dictation")
        }
        refresh()
    }

    /// Read something aloud through the normal reply queue (respects mute and dictation), e.g. a question card.
    func announce(_ text: String) {
        guard let payload = try? JSONSerialization.data(withJSONObject: ["last_assistant_message": text]) else { return }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["python3", hookScript.path]
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
            input.fileHandleForWriting.write(payload)
            try input.fileHandleForWriting.close()
        } catch {
            log.error("could not read the text aloud: \(error.localizedDescription)")
        }
    }

    func setVoice(_ id: String?) {
        voiceID = id
        voiceName = id.flatMap(VoiceCatalog.displayName(of:)) ?? systemVoiceLabel
        saveSettings()
        playSample()
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        saveSettings()
    }

    func setMusicVolume(_ volume: Double) {
        musicVolume = volume
        saveSettings()
    }

    func setKeepsRepliesShort(_ enabled: Bool) {
        keepsRepliesShort = enabled
        saveSettings()
    }

    func setOrchestratorMode(_ enabled: Bool) {
        isOrchestratorMode = enabled
        saveSettings()
    }

    func loadSettings() {
        let settings = (try? Data(contentsOf: settingsFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let id = (settings["voice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        systemVoiceLabel = VoiceCatalog.systemVoiceLabel
        voiceID = id
        voiceName = id.flatMap(VoiceCatalog.displayName(of:)) ?? systemVoiceLabel
        speed = (settings["rate"] as? Double).map { ($0 / Self.baseRate * 10).rounded() / 10 } ?? 1
        musicVolume = settings["duck"] as? Double ?? 0.5
        keepsRepliesShort = settings["brief"] as? Bool ?? true
        isOrchestratorMode = settings["orchestrator"] as? Bool ?? false
    }

    func playSample() {
        let name = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0)?.name }
        let text = (name.map { "Hi, I'm \($0). " } ?? "Hi! ") + "This is how Claude's replies will sound."
        guard let payload = try? JSONSerialization.data(withJSONObject: ["last_assistant_message": text]) else { return }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["python3", hookScript.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["NOTCHVOICE_SAMPLE": "1"]) { $1 }
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
            input.fileHandleForWriting.write(payload)
            try input.fileHandleForWriting.close()
            sample = process
        } catch {
            log.error("could not play a voice sample: \(error.localizedDescription)")
        }
    }

    func refresh() {
        let enabled = !FileManager.default.fileExists(atPath: muteFile.path)
        let pids = ownerPids()
        let sayPid = pids.dropFirst().first.flatMap { Self.processName($0) == "say" ? $0 : nil }
        let isSample = sample?.isRunning == true && pids.first == sample?.processIdentifier
        if let sayPid, !enabled, !isSample {
            // Stopping only `say` lets the hook finish normally, and it restores the music volume itself.
            // A paused `say` only acts on SIGTERM once it is continued.
            kill(sayPid, SIGTERM)
            kill(sayPid, SIGCONT)
            if pausedSay == sayPid { pausedSay = nil }
            log.info("stopped say \(sayPid) because voice replies are off")
        } else if let sayPid, isDictating, pausedSay != sayPid, !isSample {
            kill(sayPid, SIGSTOP)
            pausedSay = sayPid
            log.info("paused say \(sayPid) while the user dictates")
        }
        if isEnabled != enabled { isEnabled = enabled }
        let playerSpeaking = player.map { $0.isSpeaking && !$0.isPaused } ?? false
        let speaking = (sayPid != nil && (enabled || isSample) && pausedSay != sayPid) || playerSpeaking
        if isSpeaking != speaking {
            isSpeaking = speaking
            log.info("speaking: \(speaking)")
        }
        let session = !speaking ? nil
            : playerSpeaking ? player?.session
            : (try? String(contentsOf: sessionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if speakingSession != session { speakingSession = session }
        setPolling(pids.contains { Self.isAlive($0) })
    }

    private func saveSettings() {
        var settings: [String: Any] = ["duck": NSDecimalNumber(string: String(format: "%.2f", musicVolume)), "brief": keepsRepliesShort, "orchestrator": isOrchestratorMode]
        if let voiceID { settings["voice"] = voiceID }
        if abs(speed - 1) > 0.01 { settings["rate"] = Int((Self.baseRate * speed).rounded()) }
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try data.write(to: settingsFile, options: .atomic)
        } catch {
            log.error("could not save settings: \(error.localizedDescription)")
        }
    }

    private func ownerPids() -> [pid_t] {
        guard let text = try? String(contentsOf: ownerFile, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
    }

    private func setPolling(_ on: Bool) {
        if on, pollTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !on, let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
        }
    }

    private func watchOwnerDirectory() {
        let descriptor = open(ownerFile.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directoryWatcher = source
    }

    private nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private nonisolated static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
