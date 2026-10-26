import AppKit
import Combine
import SwiftUI

struct NotchMetrics: Equatable {
    var notch: CGSize
    var hasNotch: Bool

    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 10
    static let openTopRadius: CGFloat = 10
    static let openBottomRadius: CGFloat = 22
    static let glowMargin: CGFloat = 60

    var closedSize: CGSize { CGSize(width: notch.width + 2 * Self.closedTopRadius, height: notch.height) }
    var openSize: CGSize { CGSize(width: max(360, notch.width + 170), height: notch.height + 58) }
    var permissionSize: CGSize { CGSize(width: max(440, notch.width + 250), height: notch.height + 152) }
    var talkSize: CGSize { CGSize(width: max(440, notch.width + 250), height: notch.height + 64) }
    var windowSize: CGSize {
        let question = questionSize(options: 4)
        return CGSize(width: max(permissionSize.width, question.width) + 2 * Self.glowMargin,
                      height: max(permissionSize.height, question.height) + Self.glowMargin)
    }

    /// A question card grows with its options, of which AskUserQuestion has two to four.
    func questionSize(options: Int) -> CGSize {
        CGSize(width: max(540, notch.width + 330), height: notch.height + 112 + CGFloat(min(max(options, 2), 4)) * 36)
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
    @Published var talk: TalkController.Card?
    @Published var question: QuestionPrompt?
    @Published var questionProgress = QuestionProgress(count: 0)
    @Published var questionFrom = ""
    @Published var canGoToQuestion = false
    @Published var metrics = NotchMetrics(notch: CGSize(width: 185, height: 32), hasNotch: false)
}

@MainActor
final class NotchController {
    private let voice: VoiceController
    private let questions: QuestionCenter
    private let sessions: SessionStore
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
    private var talkChanges: AnyCancellable?
    private var questionChanges: AnyCancellable?
    private var glowPreview = 0

    init(voice: VoiceController, preferences: Preferences, permissions: PermissionCenter, talk: TalkController,
         questions: QuestionCenter, sessions: SessionStore, openSettings: @escaping @MainActor () -> Void) {
        self.voice = voice
        self.questions = questions
        self.sessions = sessions
        let questionActions = QuestionActions(
            toggle: { [weak self] in self?.pickOption($0) },
            setOther: { [weak self] in self?.setOther($0) },
            back: { [weak self] in self?.previousQuestion() },
            next: { [weak self] in self?.nextQuestion() },
            handBack: { [weak self] in self?.handBackQuestion() },
            goToSession: { [weak self] in self?.goToQuestionSession() }
        )
        let root = NotchRootView(state: state, voice: voice, preferences: preferences, answer: permissions.answer,
                                 cancelTalk: talk.cancel, questionActions: questionActions, openSettings: openSettings)
        let host = NotchHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        layout()

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        themeChanges = preferences.$theme.dropFirst().removeDuplicates().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.previewGlow() }
        }
        permissionChanges = permissions.$queue.sink { [weak self] queue in
            MainActor.assumeIsolated { self?.showPermission(queue.first, count: queue.count) }
        }
        talkChanges = talk.$card.removeDuplicates().sink { [weak self] card in
            MainActor.assumeIsolated { self?.showTalk(card) }
        }
        questionChanges = questions.$queue.sink { [weak self] queue in
            MainActor.assumeIsolated { self?.showQuestion(queue.first) }
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

    private var questionZone: CGRect {
        let options = state.question.map { $0.questions[state.questionProgress.index].options.count } ?? 4
        let size = state.metrics.questionSize(options: options)
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height + 8)
    }

    private var talkZone: CGRect {
        let size = state.metrics.talkSize
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height + 8)
    }

    private var panelZone: CGRect {
        let size = state.metrics.openSize
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height + 8)
    }

    private func mouseMoved() {
        if state.isOpen || hoverZone.contains(NSEvent.mouseLocation) { startTracking() }
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

    private func track() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
        if state.prompt != nil {
            setInteractive(permissionZone.contains(mouse) || isMenuOpen)
            return
        }
        if state.question != nil {
            setInteractive(questionZone.contains(mouse))
            return
        }
        if state.talk != nil {
            setInteractive(talkZone.contains(mouse))
            return
        }
        if state.isOpen {
            let inside = panelZone.contains(mouse) || isMenuOpen
            setInteractive(inside)
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
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            state.prompt = prompt
            state.pendingCount = count
            if prompt != nil { state.isOpen = false }
        }
        if prompt != nil {
            startTracking()
        } else {
            setInteractive(false)
            track()
        }
    }

    private func showTalk(_ card: TalkController.Card?) {
        let wasShown = state.talk != nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            state.talk = card
            if card != nil { state.isOpen = false }
        }
        if card != nil {
            startTracking()
        } else if wasShown {
            setInteractive(false)
            track()
        }
    }

    // MARK: Questions

    private func showQuestion(_ prompt: QuestionPrompt?) {
        guard prompt?.id != state.question?.id else { return }
        let wasShown = state.question != nil
        let session = prompt?.sessionID.flatMap { id in sessions.sessions.first { $0.id == id } }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            state.question = prompt
            state.questionProgress = QuestionProgress(count: prompt?.questions.count ?? 0)
            state.questionFrom = session?.title ?? prompt.flatMap { Self.folder(of: $0.cwd) } ?? "A session"
            state.canGoToQuestion = session.map(SessionOpener.canOpen) ?? false
            if prompt != nil { state.isOpen = false }
        }
        voice.stopAnnouncement()
        if prompt != nil {
            // Only now can the panel take the keyboard, so "Other…" can be typed into; the app stays in the background.
            panel.allowsKey = true
            startTracking()
            announceQuestion(from: session?.project ?? prompt.flatMap { Self.folder(of: $0.cwd) })
        } else if wasShown {
            panel.allowsKey = false
            if panel.isKeyWindow {
                // Hands the keyboard back to the app the user was in.
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
            setInteractive(false)
            track()
        }
    }

    private func announceQuestion(from project: String? = nil) {
        guard let prompt = state.question else { return }
        let question = prompt.questions[state.questionProgress.index]
        let options = question.options.enumerated().map { "Option \($0.offset + 1): \($0.element.label)." }
        let intro = project.map { "A question from \($0). " } ?? ""
        voice.announce(intro + question.text + " " + options.joined(separator: " "))
    }

    private func pickOption(_ index: Int) {
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

    private func setOther(_ text: String) {
        guard state.question != nil else { return }
        state.questionProgress.other[state.questionProgress.index] = text
    }

    private func previousQuestion() {
        guard state.questionProgress.index > 0 else { return }
        state.questionProgress.index -= 1
    }

    private func nextQuestion() {
        guard let prompt = state.question else { return }
        let progress = state.questionProgress
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

    private func goToQuestionSession() {
        guard let id = state.question?.sessionID, let session = sessions.sessions.first(where: { $0.id == id }) else { return }
        SessionOpener.open(session)
    }

    private static func folder(of cwd: String?) -> String? {
        cwd.map { URL(filePath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
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

    /// True only while a question card is up, so its text field can be typed into.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
