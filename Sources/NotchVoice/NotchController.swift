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
    static let voiceRowHeight: CGFloat = 58
    static let sessionRowHeight: CGFloat = 38
    static let sessionListPadding: CGFloat = 12
    static let tabBarHeight: CGFloat = 26

    func openSize(rows: Int, hasTabs: Bool = false) -> CGSize {
        let list = rows > 0 ? CGFloat(rows) * Self.sessionRowHeight + Self.sessionListPadding : 0
        let wide = rows > 0 || hasTabs
        return CGSize(
            width: max(wide ? 440 : 360, notch.width + (wide ? 250 : 170)),
            height: notch.height + Self.voiceRowHeight + (hasTabs ? Self.tabBarHeight : 0) + list
        )
    }
    var permissionSize: CGSize { CGSize(width: max(440, notch.width + 250), height: notch.height + 152) }
    var windowSize: CGSize {
        let tallest = openSize(rows: max(ClaudeSession.maxShown, TrackedPR.maxShown), hasTabs: true)
        return CGSize(
            width: max(permissionSize.width, tallest.width) + 2 * Self.glowMargin,
            height: max(permissionSize.height, tallest.height) + Self.glowMargin
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
    @Published var tab: NotchTab = .sessions

    var hasTabs: Bool { !prs.isEmpty }
    var shownTab: NotchTab { hasTabs ? tab : .sessions }
    var openSize: CGSize {
        metrics.openSize(rows: shownTab == .sessions ? sessions.count : prs.count, hasTabs: hasTabs)
    }
    @Published var metrics = NotchMetrics(notch: CGSize(width: 185, height: 32), hasNotch: false)
}

@MainActor
final class NotchController {
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
    private var glowPreview = 0
    private let preferences: Preferences
    private var reopenAfterPrompt = false
    private var pinChanges: AnyCancellable?

    init(voice: VoiceController, preferences: Preferences, permissions: PermissionCenter, sessions: SessionStore, tracker: TrackerStore, openSettings: @escaping @MainActor () -> Void) {
        self.voice = voice
        self.preferences = preferences
        let root = NotchRootView(state: state, voice: voice, preferences: preferences, answer: permissions.answer, openSettings: openSettings)
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

    private func track() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
