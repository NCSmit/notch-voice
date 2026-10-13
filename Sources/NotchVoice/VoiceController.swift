import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "voice")

@MainActor
final class VoiceController: ObservableObject {
    @Published private(set) var isEnabled = true
    @Published private(set) var isSpeaking = false
    @Published private(set) var voiceID: String?
    @Published private(set) var voiceName = "System Voice"

    // The contract of ~/.claude/hooks/speak.py: it stays silent while the mute file exists, speaks with the
    // voice identifier in the voice file (or the system voice without one), and writes "<hook pid> <say pid>"
    // to the owner file for the reply it is reading out.
    private let muteFile = URL.homeDirectory.appending(path: ".claude/tts_off")
    private let voiceFile = URL.homeDirectory.appending(path: ".claude/tts_voice")
    private let ownerFile = URL(filePath: NSTemporaryDirectory()).appending(path: "claude_tts_owner")
    private let hookScript = URL.homeDirectory.appending(path: ".claude/hooks/speak.py")
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var preview: Process?

    init() {
        refresh()
        watchOwnerDirectory()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            try? FileManager.default.removeItem(at: muteFile)
        } else {
            FileManager.default.createFile(atPath: muteFile.path, contents: nil)
        }
        refresh()
    }

    func setVoice(_ id: String?) {
        if let id {
            try? id.write(to: voiceFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: voiceFile)
        }
        refresh()
        playPreview()
    }

    func refresh() {
        let enabled = !FileManager.default.fileExists(atPath: muteFile.path)
        let pids = ownerPids()
        let sayPid = pids.dropFirst().first.flatMap { Self.processName($0) == "say" ? $0 : nil }
        if let sayPid, !enabled {
            // Stopping only `say` lets the hook finish normally, and it restores the music volume itself.
            kill(sayPid, SIGTERM)
            log.info("stopped say \(sayPid) because voice replies are off")
        }
        if isEnabled != enabled { isEnabled = enabled }
        let speaking = enabled && sayPid != nil
        if isSpeaking != speaking {
            isSpeaking = speaking
            log.info("speaking: \(speaking)")
        }
        let voice = (try? String(contentsOf: voiceFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = voice?.isEmpty == false ? voice : nil
        if voiceID != id {
            voiceID = id
            voiceName = id.flatMap(VoiceMenu.displayName(of:)) ?? "System Voice"
        }
        setPolling(pids.contains { Self.isAlive($0) })
    }

    private func playPreview() {
        let name = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0)?.name }
        let text = name.map { "Hello! My name is \($0)." } ?? "This is the system voice."
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
            preview = process
        } catch {
            log.error("could not play the voice preview: \(error.localizedDescription)")
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
