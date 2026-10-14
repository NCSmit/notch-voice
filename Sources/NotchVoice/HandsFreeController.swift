import AppKit
import Combine
import os

private let log = Logger(subsystem: "local.notchvoice", category: "handsfree")

/// "Hey orchestrator" → Wispr Flow dictates into a box under the notch → "send it" (or a pause) → the text is typed
/// into the orchestrator session as the user's own message.
@MainActor
final class HandsFreeController: ObservableObject {
    enum Phase: Equatable {
        case off, listening, capturing, sending
        case failed(String)
    }

    @Published private(set) var phase = Phase.off

    private let listener = WakeWordListener()
    private let dictation: DictationMonitor
    private let window = CaptureWindow()
    private var previousApp: NSRunningApplication?
    private var enabledChanges: AnyCancellable?
    private var retryTimer: Timer?
    private var isEnabled = false

    private static let startWispr = URL(string: "wispr-flow://start-hands-free")!
    private static let stopWispr = URL(string: "wispr-flow://stop-hands-free")!
    private static let wisprTextWait: TimeInterval = 8

    init(dictation: DictationMonitor, preferences: Preferences) {
        self.dictation = dictation
        listener.onWake = { [weak self] in self?.wake() }
        listener.onStop = { [weak self] reason, heard in self?.captureEnded(reason, heard: heard) }
        listener.onUnavailable = { [weak self] reason in self?.listenerStopped(reason) }
        window.onCancel = { [weak self] in self?.cancel() }
        window.onSend = { [weak self] in self?.sendNow() }
        enabledChanges = preferences.$listensForWakeWord.sink { [weak self] on in
            MainActor.assumeIsolated { self?.setEnabled(on) }
        }
    }

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

    /// Start listening, or say why not and try again shortly: a permission granted in System Settings, or a speech
    /// model that finishes downloading, is picked up without restarting NotchVoice.
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
                listener.start()
                reason = listener.isRunning ? nil : (listener.unavailableReason() ?? "The microphone couldn't be started; retrying.")
            }
            guard isEnabled else { return }
            if let reason {
                log.error("hands-free not armed: \(reason, privacy: .public)")
                phase = .failed(reason)
                retryTimer?.invalidate()
                let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.arm() }
                }
                RunLoop.main.add(timer, forMode: .common)
                retryTimer = timer
            } else {
                log.info("hands-free armed")
                phase = .listening
            }
        }
    }

    private func listenerStopped(_ reason: String) {
        log.error("hands-free stopped: \(reason, privacy: .public)")
        if phase == .capturing { cancel() }
        phase = .failed(reason)
        retryTimer?.invalidate()
        // Slow retry: a setting changed in System Settings is picked up without restarting NotchVoice.
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.arm() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func wake() {
        guard phase == .listening || phaseIsFailure else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        dictation.hold(true)  // pauses or holds back any reply until the message is sent
        phase = .capturing
        window.show(status: "Listening… say \u{201C}send it\u{201D} when you're done. Esc cancels.")
        listener.beginCapture()
        openQuietly(Self.startWispr)
    }

    private func captureEnded(_ reason: WakeWordListener.StopReason, heard: String) {
        guard phase == .capturing else { return }
        if listener.mode == .capture { listener.endCapture() }
        openQuietly(Self.stopWispr)
        if reason == .nothingSaid {
            cancel()
            return
        }
        phase = .sending
        window.setStatus("Sending…")
        Task { await finish(fallback: heard) }
    }

    /// Cmd-Return in the box: end dictation now, or retry a message that failed to send.
    private func sendNow() {
        if phase == .capturing {
            captureEnded(.stopWord, heard: "")
        } else if phaseIsFailure {
            dictation.hold(true)
            phase = .sending
            window.setStatus("Sending…")
            Task { await finish(fallback: "") }
        }
    }

    private func finish(fallback: String) async {
        // Wispr pastes its transcript into the box a moment after it stops; wait until the text settles.
        var text = "", stableSince = Date()
        let deadline = Date().addingTimeInterval(Self.wisprTextWait)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            let current = window.text
            if current != text {
                text = current
                stableSince = Date()
            } else if !text.isEmpty, Date().timeIntervalSince(stableSince) > 1 {
                break
            }
        }
        // Wispr is the better transcriber; Apple's on-device transcript is the backup.
        let message = WakeWordListener.strippingStopPhrase(text.isEmpty ? fallback : text)
        guard !message.isEmpty else {
            cancel()
            return
        }
        window.hide()
        do {
            try await OrchestratorDelivery.deliver(message, returnTo: previousApp)
            dictation.hold(false)
            phase = .listening
        } catch {
            log.error("delivery failed: \(String(describing: error))")
            dictation.hold(false)
            phase = .failed(String(describing: error))
            // Keep the words: show them again so nothing is lost.
            window.show(status: "\(error) Cmd-Return retries, Esc closes.", text: message, activate: false)
        }
    }

    private func cancel() {
        if listener.mode == .capture { listener.endCapture() }
        if phase == .capturing { openQuietly(Self.stopWispr) }
        window.hide()
        dictation.hold(false)
        previousApp?.activate()
        previousApp = nil
        phase = listener.isRunning ? .listening : .off
    }

    private var phaseIsFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func openQuietly(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
    }
}

/// A small text box under the notch for Wispr Flow to type into. It takes focus while dictating, then gives it back.
@MainActor
final class CaptureWindow: NSObject, NSWindowDelegate {
    var onCancel: () -> Void = {}
    var onSend: () -> Void = {}

    private let panel: KeyablePanel
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    private let status = NSTextField(labelWithString: "")

    var text: String { textView.string }

    override init() {
        panel = KeyablePanel(contentRect: CGRect(x: 0, y: 0, width: 520, height: 150),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.onEscape = { [weak self] in self?.onCancel() }
        panel.onCommandReturn = { [weak self] in self?.onSend() }

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        panel.contentView = background

        status.font = .systemFont(ofSize: 11, weight: .semibold)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .systemFont(ofSize: 14)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true

        background.addSubview(status)
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            status.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])
    }

    func show(status message: String, text: String = "", activate: Bool = true) {
        textView.string = text
        status.stringValue = message
        if let screen = NotchMetrics.target() {
            let frame = screen.screen.frame
            let top = frame.maxY - screen.metrics.notch.height - 10
            panel.setFrameTopLeftPoint(CGPoint(x: frame.midX - panel.frame.width / 2, y: top))
        }
        if activate { NSApp.activate() }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func setStatus(_ message: String) {
        status.stringValue = message
    }

    func hide() {
        panel.orderOut(nil)
    }
}

final class KeyablePanel: NSPanel {
    var onEscape: () -> Void = {}
    var onCommandReturn: () -> Void = {}

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
