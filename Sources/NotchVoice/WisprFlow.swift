import AppKit
import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "local.notchvoice", category: "talk")

/// Lets Wispr Flow write out a message to the orchestrator, through its hands-free links. NotchVoice still hears
/// "Hey Jarvis" and decides when a message ends; Wispr Flow only listens in between.
///
/// Wispr Flow pastes what it wrote into the text field that had the keyboard when it started listening, so NotchVoice
/// gives it one of its own: an invisible field in a panel that takes the keyboard without making NotchVoice the active
/// app, and gives it back when it closes. Only a paste sent by Wispr Flow counts. Anything else typed or pasted there is
/// dropped, so nothing the user copied can end up in a message. The field stays until Wispr Flow has pasted or has had
/// plenty of time to, because a paste that comes after it closed lands in whatever app the user is in.
@MainActor
final class WisprFlow {
    static let bundleID = "com.electron.wispr-flow"
    private static let startLink = URL(string: "wispr-flow://start-hands-free")!
    private static let stopLink = URL(string: "wispr-flow://stop-hands-free")!
    // Wispr Flow starts listening about 0.2 s after it's asked to.
    private static let startTimeout: TimeInterval = 2
    // Its text usually comes within a second of the end of a message. After this, the message goes without it.
    private static let writeTimeout: TimeInterval = 5
    // How long the field waits for a paste that is no longer wanted, so it can't land in another app. It's shorter
    // when nothing was said, since Wispr Flow then has little or nothing to write, but no shorter than a wanted paste.
    private static let lateWait: TimeInterval = 15
    private static let quietWait: TimeInterval = writeTimeout
    // A long text may come in more than one paste; it is complete once nothing more has come for this long.
    private static let settle: TimeInterval = 0.3

    /// Wispr Flow can be offered when it's installed and this Mac can tell when it is listening (macOS 14.2 and later).
    static var isAvailable: Bool {
        guard #available(macOS 14.2, *) else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Wispr Flow is listening for the message (true), or didn't start in time (false).
    var onStart: (Bool) -> Void = { _ in }
    /// When Wispr Flow started listening for the current message.
    private(set) var listeningSince: Date?
    var isListening: Bool { phase == .listening }

    private enum Phase { case idle, starting, listening, writing, discarding }
    private var phase = Phase.idle
    private let panel = PastePanel()
    private var written = ""
    private var whenWritten: ((String?) -> Void)?
    // Wispr Flow was given up on before it started listening, so it may still start, and then needs stopping.
    private var mayStartLate = false
    private var poll: Timer?
    private var deadline: Timer?
    private var settling: Timer?
    private var stoppedAt = Date()
    // How often the field has taken the keyboard back this message, so it can't end up fighting another app for it.
    private var takenBack = 0
    private var whenIdleActions: [@MainActor () -> Void] = []

    init() {
        panel.onPaste = { [weak self] text in self?.pasted(text) }
        panel.onLostKeyboard = { [weak self] in self?.lostKeyboard() }
    }

    /// Asks Wispr Flow to listen for a message. Returns why it can't, or nil when it was asked.
    func start() -> String? {
        guard phase == .idle else { return "Wispr Flow is still finishing the last message" }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else { return "Wispr Flow isn't open" }
        guard !DictationMonitor.isAppCapturing() else { return "Wispr Flow is already listening" }
        // Wispr Flow remembers which field has the keyboard as it starts, so the field takes it first.
        panel.show()
        phase = .starting
        written = ""
        listeningSince = nil
        mayStartLate = false
        takenBack = 0
        Self.open(Self.startLink)
        poll = repeating(every: 0.05) { $0.checkListening() }
        deadline = after(Self.startTimeout) { $0.startTimedOut() }
        return nil
    }

    /// Ends the message and hands over what Wispr Flow wrote, or nil when it wrote nothing in time.
    func finish(then done: @escaping (String?) -> Void) {
        switch phase {
        case .listening:
            stop()
            phase = .writing
            whenWritten = done
            deadline?.invalidate()
            deadline = after(Self.writeTimeout) { $0.writeTimedOut() }
        case .starting:
            cancel(heardWords: true)
            done(nil)
        case .idle, .writing, .discarding:
            done(nil)
        }
    }

    /// Stops Wispr Flow without using what it writes. Whether words were heard sets how long its paste is waited for.
    func cancel(heardWords: Bool) {
        switch phase {
        case .starting:
            mayStartLate = true
            stop()
            discard(for: Self.quietWait)
        case .listening:
            stop()
            discard(for: heardWords ? Self.lateWait : Self.quietWait)
        case .writing:
            discard(for: Self.lateWait)
        case .idle, .discarding:
            break
        }
    }

    private func checkListening() {
        guard DictationMonitor.isAppCapturing() else { return }
        switch phase {
        case .starting:
            poll?.invalidate()
            poll = nil
            deadline?.invalidate()
            deadline = nil
            phase = .listening
            listeningSince = Date()
            onStart(true)
        case .discarding where mayStartLate:
            log.info("Wispr Flow started listening after it was given up on; stopping it")
            mayStartLate = false
            stop()
            discard(for: Self.quietWait)
        default:
            break
        }
    }

    /// Stops Wispr Flow, which then pastes what it wrote wherever the keyboard is, so the field takes it first.
    private func stop() {
        takeKeyboardBack()
        stoppedAt = Date()
        Self.open(Self.stopLink)
    }

    /// Another window took the keyboard, most likely because the user clicked in another app. While Wispr Flow listens
    /// the user keeps it, until the message ends. Once Wispr Flow was stopped its paste is due, so the field takes the
    /// keyboard back; but when the paste is long overdue, the user keeps it and the field goes.
    private func lostKeyboard() {
        switch phase {
        case .idle, .starting, .listening:
            break
        case .writing:
            takeKeyboardBack()
        case .discarding:
            if Date().timeIntervalSince(stoppedAt) < Self.writeTimeout {
                takeKeyboardBack()
            } else {
                log.info("gave up waiting for Wispr Flow's text when another window took the keyboard")
                close()
            }
        }
    }

    private func takeKeyboardBack() {
        guard !panel.isKeyWindow else { return }
        guard takenBack < 3 else { return log.info("left the keyboard with another window that keeps taking it") }
        takenBack += 1
        log.info("took the keyboard back for Wispr Flow's text")
        panel.takeKeyboard()
    }

    private func startTimedOut() {
        guard phase == .starting else { return }
        log.info("Wispr Flow didn't start listening within \(Self.startTimeout, format: .fixed(precision: 0)) s")
        cancel(heardWords: false)
        onStart(false)
    }

    private func writeTimedOut() {
        guard phase == .writing else { return }
        log.info("Wispr Flow wrote nothing within \(Self.writeTimeout, format: .fixed(precision: 0)) s")
        let done = whenWritten
        discard(for: Self.lateWait - Self.writeTimeout)
        done?(nil)
    }

    /// Calls `action` once the field is closed and Wispr Flow is done with this message. False when it already is.
    func whenIdle(_ action: @escaping @MainActor () -> Void) -> Bool {
        guard phase != .idle else { return false }
        whenIdleActions.append(action)
        return true
    }

    private func pasted(_ text: String) {
        switch phase {
        case .listening:
            // Wispr Flow stopped by itself, so what it wrote misses whatever the user says next.
            log.info("Wispr Flow stopped listening before the message ended")
            written = text
            discard(for: Self.quietWait)
            settleLater()
        case .writing, .discarding:
            written += text
            settleLater()
        case .idle, .starting:
            break
        }
    }

    private func settleLater() {
        settling?.invalidate()
        settling = after(Self.settle) { $0.settled() }
    }

    private func settled() {
        switch phase {
        case .writing:
            log.info("Wispr Flow wrote \(self.written.count) characters, \(Date().timeIntervalSince(self.stoppedAt), format: .fixed(precision: 1)) s after it was stopped")
            let done = whenWritten
            let text = written
            close()
            done?(text)
        case .discarding:
            log.info("dropped what Wispr Flow wrote, \(Date().timeIntervalSince(self.stoppedAt), format: .fixed(precision: 1)) s after it was stopped")
            close()
        case .idle, .starting, .listening:
            break
        }
    }

    /// Waits a while for a paste that won't be used, so it lands in the field rather than in another app.
    private func discard(for seconds: TimeInterval) {
        phase = .discarding
        whenWritten = nil
        deadline?.invalidate()
        deadline = after(seconds) { flow in
            log.info("gave the keyboard back without anything more from Wispr Flow")
            flow.close()
        }
        if !mayStartLate {
            poll?.invalidate()
            poll = nil
        }
    }

    private func close() {
        for timer in [poll, deadline, settling] { timer?.invalidate() }
        poll = nil
        deadline = nil
        settling = nil
        panel.hide()
        phase = .idle
        written = ""
        whenWritten = nil
        mayStartLate = false
        let actions = whenIdleActions
        whenIdleActions = []
        for action in actions { action() }
    }

    private func after(_ seconds: TimeInterval, _ action: @escaping @MainActor (WisprFlow) -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func repeating(every seconds: TimeInterval, _ action: @escaping @MainActor (WisprFlow) -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private static func open(_ link: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(link, configuration: configuration)
    }
}

/// The invisible panel that holds the field Wispr Flow pastes into. It takes the keyboard without making NotchVoice the
/// active app, so hiding it gives the keyboard back to the app the user was in.
private final class PastePanel: NSPanel {
    var onPaste: (String) -> Void = { _ in }
    var onLostKeyboard: () -> Void = {}
    private let field = PasteField(frame: CGRect(x: 0, y: 0, width: 2, height: 2))

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 2, height: 2), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        field.isRichText = false
        field.importsGraphics = false
        field.allowsUndo = false
        field.onPaste = { [weak self] text in self?.onPaste(text) }
        contentView = field
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // Hiding the panel gives up the keyboard too; only losing it while showing counts.
        if isVisible { onLostKeyboard() }
    }

    func show() {
        field.string = ""
        field.pasteboardCount = NSPasteboard.general.changeCount
        if let screen = NSScreen.main { setFrameOrigin(CGPoint(x: screen.frame.midX, y: screen.frame.maxY - frame.height)) }
        orderFrontRegardless()
        takeKeyboard()
    }

    func takeKeyboard() {
        makeKey()
        makeFirstResponder(field)
    }

    func hide() {
        orderOut(nil)
        field.string = ""
    }
}

/// Lets in only a paste that Wispr Flow sends, after Wispr Flow put its text on the pasteboard. Typing, the user's own
/// pastes and other key commands all stop here, so none of them end up in a message or reach NotchVoice's menu.
private final class PasteField: NSTextView {
    var onPaste: (String) -> Void = { _ in }
    // The pasteboard's change count when the field opened; Wispr Flow's text makes it move on.
    var pasteboardCount = 0

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        if event.type == .keyDown, Self.isPaste(event), Self.isFromWisprFlow(event),
           NSPasteboard.general.changeCount != pasteboardCount,
           let text = NSPasteboard.general.string(forType: .string) {
            // Wispr Flow checks that its text arrived, so the field shows it as any other field would.
            insertText(text, replacementRange: selectedRange())
            onPaste(text)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {}

    override func paste(_ sender: Any?) {}

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private static func isPaste(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && (event.keyCode == UInt16(kVK_ANSI_V) || event.charactersIgnoringModifiers == "v")
    }

    private static func isFromWisprFlow(_ event: NSEvent) -> Bool {
        let pid = pid_t(truncatingIfNeeded: event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0)
        guard pid > 0, let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return id == WisprFlow.bundleID || id.hasPrefix(WisprFlow.bundleID + ".")
    }
}
