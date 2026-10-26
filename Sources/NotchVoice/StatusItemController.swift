import AppKit
import Combine

/// The menu bar icon. Its menu lists the open Claude Code sessions, and clicking one brings it forward.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let store: SessionStore
    private let openSettings: @MainActor () -> Void
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var sessions: [ClaudeSession] = []
    private var speakingSession: String?
    private var isMenuOpen = false
    private var changes: AnyCancellable?

    init(sessions: SessionStore, voice: VoiceController, preferences: Preferences, openSettings: @escaping @MainActor () -> Void) {
        store = sessions
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        changes = sessions.$sessions
            .combineLatest(voice.$speakingSession, preferences.$showsSessionsInMenuBar)
            .sink { [weak self] sessions, speakingSession, isShown in
                MainActor.assumeIsolated { self?.update(sessions, speakingSession: speakingSession, isShown: isShown) }
            }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        store.reload()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func update(_ sessions: [ClaudeSession], speakingSession: String?, isShown: Bool) {
        self.sessions = sessions
        self.speakingSession = speakingSession
        if isShown, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.imagePosition = .imageLeading
            item.button?.toolTip = "Claude Code sessions"
            item.menu = menu
            statusItem = item
        } else if !isShown, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        updateButton()
        rebuildMenu()
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let waiting = sessions.count { $0.state == .waiting }
        button.image = Self.symbol(waiting > 0 ? "hand.raised.fill" : "waveform", pointSize: 14, weight: .regular)
        button.title = waiting > 0 ? "\(waiting)" : ""
        button.setAccessibilityLabel(waiting > 0 ? "NotchVoice, \(Self.needYou(waiting))" : "NotchVoice")
    }

    private func rebuildMenu() {
        let rows = menu.items.filter { $0.representedObject is String }
        let hasReleaseItem = menu.items.contains { $0.action == #selector(releaseOrchestrator) }
        if isMenuOpen, rows.map({ $0.representedObject as? String }) == sessions.map(\.id),
           hasReleaseItem == sessions.contains(where: \.isOrchestrator) {
            // Replacing items under the pointer resets the highlight and can swallow a click, so an open menu whose
            // sessions are unchanged is updated in place.
            for (item, session) in zip(rows, sessions) {
                Self.configure(item, for: session, isSpeaking: session.id == speakingSession, canOpen: SessionOpener.canOpen(session))
            }
            return
        }
        menu.items = Self.menuItems(for: sessions, speakingSession: speakingSession, canOpen: SessionOpener.canOpen, target: self)
    }

    static func menuItems(
        for sessions: [ClaudeSession],
        speakingSession: String?,
        canOpen: (ClaudeSession) -> Bool,
        target: StatusItemController?
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = [.sectionHeader(title: "Claude Code Sessions")]
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No sessions open", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            items.append(empty)
        }
        for session in sessions {
            let item = item(for: session, isSpeaking: session.id == speakingSession, canOpen: canOpen(session))
            item.action = #selector(openSession(_:))
            item.target = target
            items.append(item)
        }
        items.append(.separator())
        if sessions.contains(where: \.isOrchestrator) {
            let release = NSMenuItem(title: "Let Every Session Speak", action: #selector(releaseOrchestrator), keyEquivalent: "")
            release.target = target
            release.toolTip = "Read every session's replies aloud again. The orchestrator keeps running."
            items.append(release)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = target
        let quit = NSMenuItem(title: "Quit NotchVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return items + [settings, quit]
    }

    static func item(for session: ClaudeSession, isSpeaking: Bool, canOpen: Bool) -> NSMenuItem {
        let item = NSMenuItem()
        configure(item, for: session, isSpeaking: isSpeaking, canOpen: canOpen)
        return item
    }

    private static func configure(_ item: NSMenuItem, for session: ClaudeSession, isSpeaking: Bool, canOpen: Bool) {
        let title = session.isOrchestrator ? "Orchestrator" : session.title
        item.title = title
        item.representedObject = session.id
        item.image = image(for: session, isSpeaking: isSpeaking)
        item.isEnabled = canOpen
        item.toolTip = session.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        let detail = detail(for: session, isSpeaking: isSpeaking)
        if #available(macOS 14.4, *) {
            item.subtitle = detail
        } else {
            let attributed = NSMutableAttributedString(string: title + "\n")
            attributed.append(NSAttributedString(string: detail, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = attributed
        }
    }

    static func detail(for session: ClaudeSession, isSpeaking: Bool) -> String {
        let status = if isSpeaking {
            "Speaking…"
        } else if session.activity.isEmpty {
            session.state == .idle ? "Done" : "Working"
        } else {
            session.activity
        }
        return session.project.isEmpty || session.project == session.title ? status : "\(session.project) · \(status)"
    }

    private static func image(for session: ClaudeSession, isSpeaking: Bool) -> NSImage? {
        let state = session.state
        if session.isOrchestrator {
            let image = Self.symbol("crown.fill", pointSize: 12, weight: .semibold, canvas: NSSize(width: 16, height: 16))
            image?.accessibilityDescription = "Orchestrator"
            return image
        }
        let (symbol, color): (String, NSColor?) = if isSpeaking {
            ("waveform", nil)
        } else {
            switch state {
            case .waiting: ("hand.raised.fill", .systemOrange)
            case .working: ("circle.fill", .systemGreen)
            case .idle: ("circle", nil)
            }
        }
        // One canvas size for every state keeps the titles lined up.
        let image = Self.symbol(symbol, pointSize: isSpeaking || state == .waiting ? 13 : 8, weight: .semibold, color: color, canvas: NSSize(width: 16, height: 16))
        image?.accessibilityDescription = isSpeaking ? "Speaking" : state == .waiting ? "Needs you" : state == .working ? "Working" : "Idle"
        return image
    }

    /// An SF Symbol drawn into a plain image, because recent macOS leaves symbol images out of menus.
    private static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor? = nil, canvas: NSSize? = nil) -> NSImage? {
        var configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let color { configuration = configuration.applying(.init(paletteColors: [color])) }
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return nil
        }
        let glyphSize = glyph.size
        let image = NSImage(size: canvas ?? glyphSize, flipped: false) { rect in
            let origin = NSPoint(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2)
            glyph.draw(in: NSRect(origin: origin, size: glyphSize))
            return true
        }
        image.isTemplate = color == nil
        return image
    }

    private static func needYou(_ count: Int) -> String {
        count == 1 ? "1 session needs you" : "\(count) sessions need you"
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let session = sessions.first(where: { $0.id == id }) else { return }
        SessionOpener.open(session)
    }

    @objc private func releaseOrchestrator() {
        store.releaseOrchestrator()
    }

    @objc private func showSettings() {
        openSettings()
    }
}
