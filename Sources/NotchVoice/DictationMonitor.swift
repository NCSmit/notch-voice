import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "dictation")

/// Knows when the user is dictating, so Claude never talks over them.
///
/// It asks Core Audio which processes are capturing the microphone (macOS 14.2+ exposes this per process) and
/// watches for dictation apps: Wispr Flow in its hotkey and hands-free modes, and Apple's own dictation.
/// NotchVoice's own wake-word listener is ignored. While dictation runs, plus a short grace period, the flag file
/// $TMPDIR/notchvoice_dictating exists: speak.py waits for it to go before it starts a reply, and a reply already
/// speaking is paused and resumed.
@MainActor
final class DictationMonitor: ObservableObject {
    @Published private(set) var isDictating = false

    static let flagFile = URL(filePath: NSTemporaryDirectory()).appending(path: "notchvoice_dictating")
    nonisolated static let dictationApps = ["com.electron.wispr-flow", "com.apple.SpeechRecognitionCore", "com.apple.assistant"]
    private static let grace: TimeInterval = 1.5

    private var timer: Timer?
    private var captureEnded: Date?
    private var extraHold = false

    func start() {
        try? FileManager.default.removeItem(at: Self.flagFile)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// NotchVoice's own capture (the wake-word flow) holds dictation open while its box is up, even in silences.
    func hold(_ on: Bool) {
        extraHold = on
        poll()
    }

    private func poll() {
        let capturing = extraHold || Self.dictationAppIsCapturing()
        let now = Date()
        if capturing {
            captureEnded = nil
        } else if isDictating, captureEnded == nil {
            captureEnded = now
        }
        let dictating = capturing || (captureEnded.map { now.timeIntervalSince($0) < Self.grace } ?? false)
        guard dictating != isDictating else { return }
        isDictating = dictating
        if dictating {
            FileManager.default.createFile(atPath: Self.flagFile.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: Self.flagFile)
            captureEnded = nil
        }
        log.info("dictating: \(dictating)")
    }

    private nonisolated static func dictationAppIsCapturing() -> Bool {
        let me = getpid()
        for process in audioProcesses() {
            guard let pid: pid_t = property(process, kAudioProcessPropertyPID), pid != me,
                  let running: UInt32 = property(process, kAudioProcessPropertyIsRunningInput), running != 0,
                  let bundle = bundleID(process) else { continue }
            if dictationApps.contains(where: { bundle.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// Whether Spotify or Apple Music is playing audio right now (Core Audio's per-process output state).
    nonisolated static func musicIsPlaying() -> Bool {
        audioProcesses().contains { process in
            guard let running: UInt32 = property(process, kAudioProcessPropertyIsRunningOutput), running != 0,
                  let bundle = bundleID(process) else { return false }
            return bundle.hasPrefix("com.spotify.client") || bundle == "com.apple.Music"
        }
    }

    private nonisolated static func audioProcesses() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private nonisolated static func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
