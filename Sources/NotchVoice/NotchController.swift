import AppKit
import ApplicationServices
import Combine
import SwiftUI
import os

private let captureLog = Logger(subsystem: "local.notchvoice", category: "handsfree")

struct NotchMetrics: Equatable {
    var notch: CGSize
    var hasNotch: Bool

    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 10
    static let openTopRadius: CGFloat = 10
    static let openBottomRadius: CGFloat = 22
    static let glowMargin: CGFloat = 60

    var closedSize: CGSize { CGSize(width: notch.width + 2 * Self.closedTopRadius, height: notch.height) }
    static let indicatorWidth: CGFloat = 26
    /// The closed notch grows a little to the right to show the hands-free indicator.
    var closedSizeWithIndicator: CGSize { CGSize(width: closedSize.width + 2 * Self.indicatorWidth, height: notch.height) }
    static let voiceRowHeight: CGFloat = 58
    static let sessionRowHeight: CGFloat = 38
    static let sessionListPadding: CGFloat = 12
    static let tabBarHeight: CGFloat = 26
    static let captureHeight: CGFloat = 86

    var questionSize: CGSize { CGSize(width: max(540, notch.width + 330), height: notch.height + 272) }
    var noticeSize: CGSize { CGSize(width: max(520, notch.width + 310), height: notch.height + 50) }

    /// The notch popped out with only the capture field, while hands-free waits for a dictated message.
    var captureSize: CGSize { CGSize(width: max(460, notch.width + 270), height: notch.height + Self.captureHeight) }

    func openSize(rows: Int, hasTabs: Bool = false, capture: Bool = false) -> CGSize {
        let list = rows > 0 ? CGFloat(rows) * Self.sessionRowHeight + Self.sessionListPadding : 0
        let wide = rows > 0 || hasTabs
        return CGSize(
            width: max(wide ? 440 : 360, notch.width + (wide ? 250 : 170)),
            height: notch.height + Self.voiceRowHeight + (hasTabs ? Self.tabBarHeight : 0) + list + (capture ? Self.captureHeight : 0)
        )
    }
    var permissionSize: CGSize { CGSize(width: max(440, notch.width + 250), height: notch.height + 152) }
    var windowSize: CGSize {
        let tallest = openSize(rows: max(ClaudeSession.maxShown, TrackedPR.maxShown), hasTabs: true, capture: true)
        return CGSize(
            width: max(permissionSize.width, tallest.width, questionSize.width) + 2 * Self.glowMargin,
            height: max(permissionSize.height, tallest.height, questionSize.height) + Self.glowMargin
        )
    }

    @MainActor
    static func target() -> (screen: NSScreen, metrics: NotchMetrics)? {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            return (screen, NotchMetrics(notch: notch, hasNotch: true))
        }
        guard let screen = NSScreen.screens.first else { return nil }
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return (screen, NotchMetrics(notch: CGSize(width: 185, height: menuBarHeight), hasNotch: false))
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var isOpen = false
    @Published var isPreviewingGlow = false
    @Published var prompt: PermissionPrompt?
    @Published var pendingCount = 0
    @Published var sessions: [ClaudeSession] = []
    @Published var orchestratorID: String?
    @Published var prs: [TrackedPR] = []
    @Published var handsFree = HandsFreeController.Phase.off
    @Published var listensOnHeadphones = false
    /// Shown while hands-free takes a message: a status line, Wispr's text field, and Apple's live transcript.
    @Published var capture: CaptureState?
    @Published var captureText = ""
    @Published var captureFocus = 0
    @Published var question: QuestionPrompt?
    @Published var questionProgress = QuestionProgress(count: 0)
    @Published var notice: BlockedNotice?
    @Published var tab: NotchTab = .sessions

    var hasTabs: Bool { !prs.isEmpty }
    var shownTab: NotchTab { hasTabs ? tab : .sessions }
    var openSize: CGSize {
        metrics.openSize(rows: shownTab == .sessions ? sessions.count : prs.count, hasTabs: hasTabs, capture: capture != nil)
    }
    @Published var metrics = NotchMetrics(notch: CGSize(width: 185, height: 32), hasNotch: false)
}

struct CaptureState: Equatable {
    var status: String
    var transcript = ""
}

@MainActor
final class NotchController: CaptureSurface {
    private let voice: VoiceController
    private let state = NotchState()
    private let panel = NotchPanel()
    private var screenFrame = CGRect.zero
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var trackingTimer: Timer?
    private var hoverStart: Date?
    private var leaveStart: Date?
    private var isMenuOpen = false
    private var themeChanges: AnyCancellable?
    private var permissionChanges: AnyCancellable?
    private var sessionChanges: AnyCancellable?
    private var orchestratorChanges: AnyCancellable?
    private var prChanges: AnyCancellable?
    private var handsFreeChanges: AnyCancellable?
    private weak var handsFree: HandsFreeController?
    private var headphoneMicChanges: AnyCancellable?
    private var questionChanges: AnyCancellable?
    private var noticeChanges: AnyCancellable?
    private let questions: QuestionCenter
    private let notices: NoticeCenter
    private var glowPreview = 0
    private let preferences: Preferences
    private var reopenAfterPrompt = false
    private var pinChanges: AnyCancellable?

    init(voice: VoiceController, preferences: Preferences, permissions: PermissionCenter, sessions: SessionStore, tracker: TrackerStore, handsFree: HandsFreeController, questions: QuestionCenter, notices: NoticeCenter, openSettings: @escaping @MainActor () -> Void) {
        self.voice = voice
        self.questions = questions
        self.notices = notices
        self.preferences = preferences
        let root = NotchRootView(
            state: state, voice: voice, preferences: preferences, answer: permissions.answer, openSettings: openSettings,
            sendCapture: { [weak handsFree] in handsFree?.sendNow() },
            cancelCapture: { [weak handsFree] in handsFree?.cancelFromField() },
            questionActions: QuestionActions(
                toggle: { [weak self] in self?.toggleOption($0) },
                setOther: { [weak self] in self?.state.questionProgress.other[self?.state.questionProgress.index ?? 0] = $0 },
                back: { [weak self] in self?.previousQuestion() },
                next: { [weak self] in self?.nextQuestion() },
                handBack: { [weak self] in self?.handBackQuestion() },
                goToSession: { [weak self] in SessionNavigator.go(to: self?.state.question?.sessionID) }
            ),
            noticeActions: (
                go: { [weak self] in SessionNavigator.go(to: self?.state.notice?.sessionID); self?.notices.dismiss() },
                dismiss: { [weak self] in self?.notices.dismiss() }
            )
        )
        let host = NotchHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        layout()

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        pinChanges = preferences.$isPanelPinned.dropFirst().sink { [weak self] _ in
            // Unpinning with the mouse elsewhere should collapse the panel straight away.
            MainActor.assumeIsolated { self?.startTracking() }
        }
        themeChanges = preferences.$theme.dropFirst().removeDuplicates().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.previewGlow() }
        }
        permissionChanges = permissions.$queue.sink { [weak self] queue in
            MainActor.assumeIsolated { self?.showPermission(queue.first, count: queue.count) }
        }
        self.handsFree = handsFree
        questionChanges = questions.$queue.sink { [weak self] queue in
            MainActor.assumeIsolated { self?.showQuestion(queue.first) }
        }
        noticeChanges = notices.$current.sink { [weak self] notice in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { self.state.notice = notice }
                self.setInteractive(notice != nil || self.needsMouse)
            }
        }
        headphoneMicChanges = handsFree.$onHeadphones.sink { [weak self] on in
            MainActor.assumeIsolated { self?.state.listensOnHeadphones = on }
        }
        handsFreeChanges = handsFree.$phase.sink { [weak self] phase in
            MainActor.assumeIsolated {
                withAnimation(.easeInOut(duration: 0.25)) { self?.state.handsFree = phase }
            }
        }
        prChanges = tracker.$prs.sink { [weak self] list in
            MainActor.assumeIsolated {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { self?.state.prs = list }
            }
        }
        orchestratorChanges = sessions.$orchestratorID.sink { [weak self] id in
            MainActor.assumeIsolated { self?.state.orchestratorID = id }
        }
        sessionChanges = sessions.$sessions.sink { [weak self] list in
            MainActor.assumeIsolated {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { self?.state.sessions = list }
            }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            },
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isMenuOpen = true }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isMenuOpen = false }
            },
        ]
    }

    private func layout() {
        guard let target = NotchMetrics.target() else { return }
        screenFrame = target.screen.frame
        state.metrics = target.metrics
        let size = target.metrics.windowSize
        let frame = CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private var hoverZone: CGRect {
        let notch = state.metrics.notch
        return CGRect(x: screenFrame.midX - notch.width / 2, y: screenFrame.maxY - notch.height, width: notch.width, height: notch.height + 8)
    }

    private var permissionZone: CGRect {
        let size = state.metrics.permissionSize
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height + 8)
    }

    private var panelZone: CGRect {
        let size = state.openSize
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height + 8)
    }

    private func mouseMoved() {
        if state.isOpen, state.prompt == nil, preferences.isPanelPinned {
            track()
        } else if state.isOpen || hoverZone.contains(NSEvent.mouseLocation) {
            startTracking()
        }
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
        track()
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        hoverStart = nil
        leaveStart = nil
    }

    // MARK: Questions

    private var needsMouse: Bool { state.prompt != nil || state.question != nil || state.capture != nil }

    private func showQuestion(_ prompt: QuestionPrompt?) {
        guard prompt?.id != state.question?.id else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            state.question = prompt
            state.questionProgress = QuestionProgress(count: prompt?.questions.count ?? 0)
            if prompt != nil { state.isOpen = false }
        }
        // Key (but not active) while a question is up, so "Other…" can be typed into without stealing focus.
        panel.allowsKey = prompt != nil || state.capture != nil
        setInteractive(needsMouse)
        if prompt != nil {
            announceQuestion()
        } else {
            startTracking()
        }
    }

    private func announceQuestion() {
        guard let prompt = state.question else { return }
        let question = prompt.questions[state.questionProgress.index]
        let numbers = ["one", "two", "three", "four"]
        let options = question.options.prefix(4).enumerated().map { "Option \(numbers[$0.offset]): \($0.element.label)." }
        let intro = state.questionProgress.index == 0 ? "\(prompt.sessionName) asks: " : ""
        voice.announce(intro + question.text + " " + options.joined(separator: " "))
    }

    private func toggleOption(_ index: Int) {
        guard let prompt = state.question else { return }
        let current = state.questionProgress.index
        if prompt.questions[current].multiSelect {
            if state.questionProgress.picks[current].contains(index) {
                state.questionProgress.picks[current].remove(index)
            } else {
                state.questionProgress.picks[current].insert(index)
            }
        } else {
            state.questionProgress.picks[current] = [index]
            state.questionProgress.other[current] = ""
            nextQuestion()
        }
    }

    private func previousQuestion() {
        guard state.questionProgress.index > 0 else { return }
        state.questionProgress.index -= 1
    }

    private func nextQuestion() {
        guard let prompt = state.question else { return }
        let progress = state.questionProgress
        let answered = !progress.picks[progress.index].isEmpty || !progress.other[progress.index].trimmingCharacters(in: .whitespaces).isEmpty
        guard answered else { return }
        if progress.index < prompt.questions.count - 1 {
            withAnimation(.easeInOut(duration: 0.2)) { state.questionProgress.index += 1 }
            announceQuestion()
        } else {
            questions.answer(prompt.id, answers: QuestionPrompt.answers(for: prompt.questions, picks: progress.picks, other: progress.other))
        }
    }

    private func handBackQuestion() {
        guard let prompt = state.question else { return }
        questions.handBack(prompt.id)
    }

    /// A spoken answer to the question on screen ("option two", "the first one", an option's name). True if used.
    func handleSpokenAnswer(_ text: String) -> Bool {
        guard let prompt = state.question else { return false }
        let question = prompt.questions[state.questionProgress.index]
        guard let action = QuestionVoice.parse(text, for: question) else { return false }
        captureLog.info("spoken answer: \(String(describing: action), privacy: .public)")
        switch action {
        case .pick(let indexes):
            if question.multiSelect {
                state.questionProgress.picks[state.questionProgress.index] = Set(indexes)
                nextQuestion()
            } else if let first = indexes.first {
                toggleOption(first)
            }
        case .other(let words):
            state.questionProgress.other[state.questionProgress.index] = words
            state.questionProgress.picks[state.questionProgress.index] = []
            nextQuestion()
        case .next:
            nextQuestion()
        case .handBack:
            handBackQuestion()
        }
        return true
    }

    // MARK: Capture field

    var captureText: String { state.captureText }

    func showCapture(status: String, text: String?) {
        if let text { state.captureText = text } else if state.capture == nil { state.captureText = "" }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            state.capture = CaptureState(status: status)
        }
        // Wispr Flow types into the focused field of the frontmost app, so NotchVoice has to be frontmost with the
        // field focused. An accessory app's own activate() is often refused; opening itself through Launch Services
        // isn't.
        panel.allowsKey = true
        // A non-activating panel can be key while another app stays frontmost, and Wispr types into the frontmost
        // app; so the panel activates NotchVoice while it captures.
        panel.styleMask.remove(.nonactivatingPanel)
        setInteractive(true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        NSApp.activate()
        // With Accessibility access (needed for sending anyway), macOS honours this even when activate() is refused.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        panel.makeKeyAndOrderFront(nil)
        state.captureFocus += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                captureLog.info("capture focus: front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none", privacy: .public), active \(NSApp.isActive, privacy: .public), key \(self.panel.isKeyWindow, privacy: .public), first responder \(String(describing: type(of: self.panel.firstResponder)), privacy: .public)")
                if !self.panel.isKeyWindow || !NSApp.isActive {
                    AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                    self.panel.makeKeyAndOrderFront(nil)
                    self.state.captureFocus += 1
                }
            }
        }
    }

    func setCaptureStatus(_ status: String) {
        state.capture?.status = status
    }

    func setCaptureTranscript(_ transcript: String) {
        state.capture?.transcript = transcript
    }

    func hideCapture() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { state.capture = nil }
        state.captureText = ""
        panel.allowsKey = state.question != nil
        panel.styleMask.insert(.nonactivatingPanel)
        panel.resignKey()
        panel.orderFrontRegardless()
        setInteractive(false)
        startTracking()
    }

    private func track() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
        if state.prompt == nil, state.capture != nil || state.question != nil || state.notice != nil {
            setInteractive(true)
            return
        }
        if state.prompt != nil {
            setInteractive(permissionZone.contains(mouse) || isMenuOpen)
            return
        }
        if state.isOpen {
            let inside = panelZone.contains(mouse) || isMenuOpen
            setInteractive(inside)
            if preferences.isPanelPinned {
                // A pinned panel never closes, so drop the 30 Hz timer; mouse-move events keep it taking clicks
                // only while it's under the mouse.
                stopTracking()
                return
            }
            if inside {
                leaveStart = nil
                return
            }
            let since = leaveStart ?? now
            leaveStart = since
            if now.timeIntervalSince(since) >= 0.3 { setOpen(false) }
        } else {
            guard hoverZone.contains(mouse), NSEvent.pressedMouseButtons == 0 else {
                stopTracking()
                return
            }
            let since = hoverStart ?? now
            hoverStart = since
            if now.timeIntervalSince(since) >= 0.15 { setOpen(true) }
        }
    }

    private func setOpen(_ open: Bool) {
        if open { voice.refresh() }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { state.isOpen = open }
        setInteractive(open)
        hoverStart = nil
        leaveStart = nil
        if !open { stopTracking() }
    }

    func flash() {
        guard state.prompt == nil else { return }
        setOpen(true)
        // track() closes the panel 0.3 s after leaveStart unless the mouse is on it, so it stays up for 1.5 s.
        leaveStart = Date(timeIntervalSinceNow: 1.2)
        startTracking()
    }

    private func showPermission(_ prompt: PermissionPrompt?, count: Int) {
        guard state.prompt?.id != prompt?.id || state.pendingCount != count else { return }
        if prompt != nil, state.prompt == nil { reopenAfterPrompt = state.isOpen && preferences.isPanelPinned }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            state.prompt = prompt
            state.pendingCount = count
            if prompt != nil { state.isOpen = false }
        }
        if prompt != nil {
            startTracking()
        } else if reopenAfterPrompt {
            reopenAfterPrompt = false
            setOpen(true)
            startTracking()
        } else {
            setInteractive(false)
            track()
        }
    }

    private func previewGlow() {
        glowPreview += 1
        let preview = glowPreview
        state.isPreviewingGlow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.glowPreview == preview else { return }
                self.state.isPreviewingGlow = false
            }
        }
    }

    private func setInteractive(_ interactive: Bool) {
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }
}

final class NotchPanel: NSPanel {
    /// Only while hands-free shows its capture field, so Wispr Flow can type into it.
    var allowsKey = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
