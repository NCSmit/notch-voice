import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "dictation")

/// Knows when the user is dictating, so Claude never talks over them.
///
/// Core Audio says which processes are capturing the microphone (macOS 14.2 and later). It doesn't announce when a
/// process starts capturing, but it does announce when an audio device or a process starts or stops running, so
/// NotchVoice checks again on each of those, and nothing is polled. Only dictation apps count: Wispr Flow and Apple's own dictation. While one captures,
/// and for a moment after, the flag file $TMPDIR/notchvoice_dictating is kept fresh. speak.py holds a reply back while
/// it is fresh and pauses one already speaking. If NotchVoice quits, the flag goes stale within seconds, so speech is
/// never left stuck.
@MainActor
final class DictationMonitor: ObservableObject {
    @Published private(set) var isDictating = false

    nonisolated static let flagFile = URL(filePath: NSTemporaryDirectory()).appending(path: "notchvoice_dictating")
    /// Bundle ids of dictation apps. Their helper processes, such as Wispr Flow's, have ids that start with these.
    nonisolated static let dictationApps = ["com.electron.wispr-flow", "com.apple.SpeechRecognitionCore", "com.apple.assistant"]
    // How long dictation counts as going on after the microphone is released, so a pause between phrases isn't a gap.
    private static let grace: TimeInterval = 1.5
    // speak.py treats a flag older than 5 s as gone, so it is refreshed well within that.
    private static let refresh: TimeInterval = 2

    private struct Listened: Hashable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
    }

    private var listeners: [Listened: AudioObjectPropertyListenerBlock] = [:]
    private var isCapturing = false
    private var graceTimer: Timer?
    private var refreshTimer: Timer?

    nonisolated static func isDictationApp(_ bundleID: String) -> Bool {
        dictationApps.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    func start() {
        try? FileManager.default.removeItem(at: Self.flagFile)
        guard #available(macOS 14.2, *) else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        listen(to: system, selector: kAudioHardwarePropertyProcessObjectList) { $0.follow(kAudioProcessPropertyIsRunning, on: Self.audioProcesses()) }
        listen(to: system, selector: kAudioHardwarePropertyDevices) { $0.follow(kAudioDevicePropertyDeviceIsRunningSomewhere, on: Self.devices()) }
        follow(kAudioProcessPropertyIsRunning, on: Self.audioProcesses())
        follow(kAudioDevicePropertyDeviceIsRunningSomewhere, on: Self.devices())
    }

    func stop() {
        try? FileManager.default.removeItem(at: Self.flagFile)
    }

    /// Listens for `selector` on each of `objects`, afresh each time their list changes, since Core Audio can give a new
    /// process the id of one that just went away. Then checks again who is capturing.
    @available(macOS 14.2, *)
    private func follow(_ selector: AudioObjectPropertySelector, on objects: [AudioObjectID]) {
        for key in listeners.keys where key.selector == selector {
            unlisten(key)
        }
        for object in objects {
            listen(to: object, selector: selector) { $0.check() }
        }
        check()
    }

    @available(macOS 14.2, *)
    private func check() {
        setCapturing(Self.audioProcesses().contains(where: Self.isDictating))
    }

    private func setCapturing(_ capturing: Bool) {
        guard capturing != isCapturing else { return }
        isCapturing = capturing
        graceTimer?.invalidate()
        graceTimer = nil
        if capturing {
            setDictating(true)
        } else {
            let timer = Timer(timeInterval: Self.grace, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setDictating(false) }
            }
            RunLoop.main.add(timer, forMode: .common)
            graceTimer = timer
        }
    }

    private func setDictating(_ dictating: Bool) {
        guard dictating != isDictating else { return }
        isDictating = dictating
        log.info("dictating: \(dictating)")
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard dictating else { return stop() }
        FileManager.default.createFile(atPath: Self.flagFile.path, contents: nil)
        let timer = Timer(timeInterval: Self.refresh, repeats: true) { _ in
            FileManager.default.createFile(atPath: Self.flagFile.path, contents: nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    @available(macOS 14.2, *)
    private func listen(to object: AudioObjectID, selector: AudioObjectPropertySelector,
                        then react: @escaping @MainActor (DictationMonitor) -> Void) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                react(self)
            }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return }
        listeners[Listened(object: object, selector: selector)] = block
    }

    private func unlisten(_ key: Listened) {
        guard let block = listeners.removeValue(forKey: key) else { return }
        var address = Self.address(key.selector)
        // The object may already be gone, in which case there is nothing left to remove.
        _ = AudioObjectRemovePropertyListenerBlock(key.object, &address, DispatchQueue.main, block)
    }

    private nonisolated static func isDictating(_ process: AudioObjectID) -> Bool {
        guard let pid: pid_t = property(process, kAudioProcessPropertyPID), pid != getpid(),
              let running: UInt32 = property(process, kAudioProcessPropertyIsRunningInput), running != 0,
              let bundle = bundleID(process) else { return false }
        return isDictationApp(bundle)
    }

    @available(macOS 14.2, *)
    private nonisolated static func audioProcesses() -> [AudioObjectID] {
        objects(kAudioHardwarePropertyProcessObjectList)
    }

    private nonisolated static func devices() -> [AudioObjectID] {
        objects(kAudioHardwarePropertyDevices)
    }

    private nonisolated static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private nonisolated static func bundleID(_ object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
