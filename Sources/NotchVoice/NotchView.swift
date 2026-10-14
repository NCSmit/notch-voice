import AppKit
import SwiftUI

enum NotchTab {
    case sessions, prs
}

struct NotchRootView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var voice: VoiceController
    @ObservedObject var preferences: Preferences
    let answer: @MainActor (UUID, PermissionResponse) -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        NotchView(
            metrics: state.metrics,
            isOpen: state.isOpen,
            isEnabled: voice.isEnabled,
            isSpeaking: voice.isSpeaking,
            isGlowing: voice.isSpeaking || state.isPreviewingGlow || state.prompt != nil,
            theme: preferences.theme,
            prompt: state.prompt,
            pendingCount: state.pendingCount,
            sessions: state.sessions,
            speakingSession: voice.isSpeaking ? voice.speakingSession : nil,
            orchestratorID: state.orchestratorID,
            prs: state.prs,
            tab: state.shownTab,
            selectTab: { tab in withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { state.tab = tab } },
            handsFree: state.handsFree,
            isOrchestratorMode: voice.isOrchestratorMode,
            setOrchestratorMode: voice.setOrchestratorMode,
            isPinned: preferences.isPanelPinned,
            setPinned: preferences.setPanelPinned,
            setEnabled: voice.setEnabled,
            answer: answer,
            openSettings: openSettings
        )
    }
}

struct NotchView: View {
    let metrics: NotchMetrics
    let isOpen: Bool
    let isEnabled: Bool
    let isSpeaking: Bool
    let isGlowing: Bool
    let theme: GlowTheme
    let prompt: PermissionPrompt?
    let pendingCount: Int
    let sessions: [ClaudeSession]
    let speakingSession: String?
    let orchestratorID: String?
    let prs: [TrackedPR]
    let tab: NotchTab
    let selectTab: @MainActor (NotchTab) -> Void
    let handsFree: HandsFreeController.Phase
    let isOrchestratorMode: Bool
    let setOrchestratorMode: @MainActor (Bool) -> Void
    let isPinned: Bool
    let setPinned: @MainActor (Bool) -> Void
    let setEnabled: @MainActor (Bool) -> Void
    let answer: @MainActor (UUID, PermissionResponse) -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        let isExpanded = isOpen || prompt != nil
        let rows = tab == .sessions ? sessions.count : prs.count
        let showsIndicator = handsFree != .off
        let size = prompt != nil ? metrics.permissionSize
            : isOpen ? metrics.openSize(rows: rows, hasTabs: !prs.isEmpty)
            : showsIndicator ? metrics.closedSizeWithIndicator : metrics.closedSize
        let topRadius = isExpanded ? NotchMetrics.openTopRadius : NotchMetrics.closedTopRadius
        let bottomRadius = isExpanded ? NotchMetrics.openBottomRadius : NotchMetrics.closedBottomRadius
        let showsBody = isExpanded || isGlowing || handsFree != .off

        ZStack(alignment: .top) {
            NotchGlow(
                outline: NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, isClosed: false),
                colors: theme.colors,
                isActive: isGlowing
            )
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(.black)
                .animation(showsBody ? .easeOut(duration: 0.15) : .easeIn(duration: 0.2).delay(0.3)) {
                    $0.opacity(showsBody ? 1 : 0)
                }
            if !isExpanded, showsIndicator {
                HandsFreeIndicator(phase: handsFree, accent: theme.accent)
                    .frame(width: NotchMetrics.indicatorWidth, height: metrics.notch.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, NotchMetrics.closedTopRadius)
                    .transition(.opacity)
            }
            if let prompt {
                PermissionCard(prompt: prompt, pendingCount: pendingCount, accent: theme.accent, answer: answer)
                    .id(prompt.id)
                    .padding(.top, metrics.notch.height)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))
                    ))
            } else if isOpen {
                VStack(spacing: 0) {
                    VoicePanel(
                        isEnabled: isEnabled,
                        isSpeaking: isSpeaking,
                        isOrchestratorMode: isOrchestratorMode,
                        hasOrchestrator: orchestratorID != nil,
                        handsFree: handsFree,
                        isPinned: isPinned,
                        accent: theme.accent,
                        setEnabled: setEnabled,
                        setOrchestratorMode: setOrchestratorMode,
                        setPinned: setPinned,
                        openSettings: openSettings
                    )
                    .frame(height: NotchMetrics.voiceRowHeight)
                    if !prs.isEmpty {
                        NotchTabBar(tab: tab, sessionCount: sessions.count, prCount: prs.count, accent: theme.accent, select: selectTab)
                            .frame(height: NotchMetrics.tabBarHeight)
                    }
                    if tab == .prs {
                        PRList(prs: prs)
                    } else if !sessions.isEmpty {
                        SessionList(sessions: sessions, speakingSession: speakingSession, orchestratorID: orchestratorID, prs: prs, accent: theme.accent)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, metrics.notch.height)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                    removal: .opacity.animation(.easeIn(duration: 0.1))
                ))
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var isClosed = true

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = topRadius
        let bottom = bottomRadius
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        if isClosed { path.closeSubpath() }
        return path
    }
}

enum Glow {
    static func level(at time: Double) -> Double {
        let breath = sin(time * 2 * .pi * 0.5)
        let chatter = sin(time * 2 * .pi * 2.6) * sin(time * 2 * .pi * 0.7 + 1.1)
        return 0.6 + 0.25 * breath + 0.15 * chatter
    }
}

struct NotchGlow: View {
    let outline: NotchShape
    let colors: [Color]
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let level = reduceMotion ? 0.8 : Glow.level(at: time)
            let spin = reduceMotion ? 0 : (time * 45).truncatingRemainder(dividingBy: 360)
            let gradient = AngularGradient(colors: colors, center: .center, angle: .degrees(spin))
            ZStack {
                outline
                    .stroke(gradient, style: StrokeStyle(lineWidth: 22 + 16 * level, lineCap: .round, lineJoin: .round))
                    .blur(radius: 26)
                    .opacity(0.5 + 0.5 * level)
                outline
                    .stroke(gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                    .blur(radius: 10)
                    .opacity(0.95)
                outline
                    .stroke(gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .blur(radius: 0.6)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.5)) { $0.opacity(isActive ? 1 : 0) }
    }
}

struct VoicePanel: View {
    let isEnabled: Bool
    let isSpeaking: Bool
    let isOrchestratorMode: Bool
    let hasOrchestrator: Bool
    let handsFree: HandsFreeController.Phase
    let isPinned: Bool
    let accent: LinearGradient
    let setEnabled: @MainActor (Bool) -> Void
    let setOrchestratorMode: @MainActor (Bool) -> Void
    let setPinned: @MainActor (Bool) -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: isEnabled ? "waveform" : "waveform.slash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isEnabled ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.35)))
                    .symbolEffect(.variableColor.iterative, isActive: isSpeaking)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice replies")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(status)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusIsWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.white.opacity(0.5)))
                        .lineLimit(1)
                        .help(status)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { setEnabled(!isEnabled) }
            .accessibilityElement(children: .combine)

            Button { setPinned(!isPinned) } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPinned ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.75)))
                    .rotationEffect(.degrees(isPinned ? 0 : 45))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Pinned open. Click to let the panel close when the mouse leaves." : "Keep the panel open")
            .accessibilityLabel("Keep panel open")
            .accessibilityValue(isPinned ? "On" : "Off")

            Button { setOrchestratorMode(!isOrchestratorMode) } label: {
                Image(systemName: isOrchestratorMode ? "crown.fill" : "person.3.fill")
                    .font(.system(size: isOrchestratorMode ? 12 : 11, weight: .semibold))
                    .foregroundStyle(isOrchestratorMode ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.75)))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isOrchestratorMode ? "Orchestrator mode: only the orchestrator speaks. Click to hear every session." : "Every session speaks. Click for orchestrator mode.")
            .accessibilityLabel("Orchestrator mode")
            .accessibilityValue(isOrchestratorMode ? "On" : "Off")

            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

            NotchSwitch(isOn: isEnabled, accent: accent)
                .contentShape(Rectangle())
                .onTapGesture { setEnabled(!isEnabled) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Voice replies")
                .accessibilityValue(isEnabled ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
                .accessibilityAction { setEnabled(!isEnabled) }
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu {
            Button("Settings…") { openSettings() }
            Divider()
            Button("Quit NotchVoice") { NSApp.terminate(nil) }
        }
    }

    private var status: String {
        if case .failed(let reason) = handsFree { return "Hands-free: " + reason }
        if handsFree == .capturing { return "Listening to you… say \u{201C}send it\u{201D}" }
        if isSpeaking { return "Speaking…" }
        guard isEnabled else { return "Off" }
        guard isOrchestratorMode else { return "Replies are read aloud" }
        return hasOrchestrator ? "Only the orchestrator speaks" : "Run /orchestrator in a session"
    }
}

extension VoicePanel {
    var statusIsWarning: Bool {
        if case .failed = handsFree { return true }
        return false
    }
}

/// A small mic beside the closed notch: armed for "Hey orchestrator", hearing a message, or unable to listen.
struct HandsFreeIndicator: View {
    let phase: HandsFreeController.Phase
    let accent: LinearGradient

    var body: some View {
        Group {
            switch phase {
            case .listening:
                Image(systemName: "mic.fill").foregroundStyle(accent).opacity(0.85)
            case .capturing, .sending:
                Image(systemName: "mic.fill").foregroundStyle(.red).symbolEffect(.pulse, isActive: true)
            case .failed:
                Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
            case .off:
                EmptyView()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .help(help)
        .accessibilityLabel(help)
    }

    private var help: String {
        switch phase {
        case .listening: "Listening for \u{201C}Hey orchestrator\u{201D}"
        case .capturing: "Taking your message"
        case .sending: "Sending to the orchestrator"
        case .failed(let reason): reason
        case .off: ""
        }
    }
}

struct SessionList: View {
    let sessions: [ClaudeSession]
    let speakingSession: String?
    let orchestratorID: String?
    let prs: [TrackedPR]
    let accent: LinearGradient

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                SessionRow(
                    session: session,
                    isSpeaking: session.id == speakingSession,
                    isOrchestrator: session.id == orchestratorID,
                    pr: prs.first { $0.sessionID == session.id },
                    accent: accent
                )
                    .frame(height: NotchMetrics.sessionRowHeight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, NotchMetrics.sessionListPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude Code sessions")
    }
}

struct SessionRow: View {
    let session: ClaudeSession
    let isSpeaking: Bool
    let isOrchestrator: Bool
    let pr: TrackedPR?
    let accent: LinearGradient

    var body: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if isOrchestrator {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(accent)
                            .accessibilityLabel("Orchestrator")
                    }
                    Text(isOrchestrator ? "Orchestrator" : session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(session.state == .idle && !isSpeaking ? 0.7 : 1))
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(session.state == .waiting ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.white.opacity(0.5)))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 6)
            if let pr {
                PRBadge(pr: pr)
            } else if !session.project.isEmpty, session.project != session.title {
                Text(session.project)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent)
                .opacity(isSpeaking ? 0.28 : 0)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent, lineWidth: 1)
                .opacity(isSpeaking ? 0.9 : 0)
        }
        .animation(.easeInOut(duration: 0.3), value: isSpeaking)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if isSpeaking { return "Speaking…" }
        if session.state == .idle {
            return session.activity.isEmpty || session.activity == "Ready" ? "Done" : session.activity
        }
        return session.activity.isEmpty ? "Working" : session.activity
    }

    @ViewBuilder
    private var indicator: some View {
        if isSpeaking {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .symbolEffect(.variableColor.iterative, isActive: true)
        } else {
            switch session.state {
            case .waiting:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, isActive: true)
            case .working:
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(accent)
                    .symbolEffect(.pulse, isActive: true)
            case .idle:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

struct NotchTabBar: View {
    let tab: NotchTab
    let sessionCount: Int
    let prCount: Int
    let accent: LinearGradient
    let select: @MainActor (NotchTab) -> Void

    var body: some View {
        HStack(spacing: 6) {
            button(.sessions, "Sessions", sessionCount)
            button(.prs, "Pull requests", prCount)
            Spacer()
        }
        .padding(.horizontal, 22)
    }

    private func button(_ value: NotchTab, _ title: String, _ count: Int) -> some View {
        let selected = tab == value
        return Button { select(value) } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").foregroundStyle(.white.opacity(0.45))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PRList: View {
    let prs: [TrackedPR]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(prs) { pr in
                PRRow(pr: pr)
                    .frame(height: NotchMetrics.sessionRowHeight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, NotchMetrics.sessionListPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pull requests")
    }
}

struct PRRow: View {
    let pr: TrackedPR

    var body: some View {
        Button {
            if let url = pr.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pr.isMerged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pr.isMerged ? Color.purple : Color.white.opacity(0.6))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("#\(pr.number) \(pr.title)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(pr.isMerged ? 0.6 : 1))
                        .lineLimit(1)
                    Text([pr.repoName, pr.sessionName].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if pr.isMerged {
                    Text("Merged")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.purple)
                } else {
                    CheckDot(label: "CI", color: pr.ci.color, help: "CI: \(pr.ci.rawValue)")
                    CheckDot(label: "Bugbot", color: pr.bugbot.color, help: "Cursor Bugbot on the latest commit: \(pr.bugbot.spoken)")
                }
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open on GitHub")
        .accessibilityElement(children: .combine)
    }
}

struct PRBadge: View {
    let pr: TrackedPR

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(pr.number)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            if pr.isMerged {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 9, weight: .bold)).foregroundStyle(.purple)
            } else {
                Circle().fill(pr.ci.color).frame(width: 6, height: 6).help("CI: \(pr.ci.rawValue)")
                Circle().fill(pr.bugbot.color).frame(width: 6, height: 6).help("Bugbot: \(pr.bugbot.spoken)")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pull request \(pr.number), CI \(pr.ci.rawValue), Bugbot \(pr.bugbot.spoken)")
    }
}

struct CheckDot: View {
    let label: String
    let color: Color
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .help(help)
    }
}

extension TrackedPR.Check {
    var color: Color {
        switch self {
        case .passing: .green
        case .failing: .red
        case .pending: .yellow
        case .none: .white.opacity(0.25)
        }
    }
}

extension TrackedPR.Bugbot {
    var color: Color {
        switch self {
        case .clean: .green
        case .findings: .red
        case .running: .yellow
        case .missing: .white.opacity(0.25)
        }
    }

    var spoken: String {
        switch self {
        case .clean: "clean"
        case .findings: "has findings"
        case .running: "still reviewing"
        case .missing: "hasn't run"
        }
    }
}

struct PermissionCard: View {
    let prompt: PermissionPrompt
    let pendingCount: Int
    let accent: LinearGradient
    let answer: @MainActor (UUID, PermissionResponse) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: prompt.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(accent))
                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text([prompt.note, prompt.project.isEmpty ? nil : prompt.project].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "Claude is asking")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if pendingCount > 1 {
                    Text("+\(pendingCount - 1) more")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                Button { answer(prompt.id, .dismiss) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Answer in Claude instead")
                .accessibilityLabel("Dismiss and answer in Claude")
            }
            ScrollView {
                Text(prompt.detail.isEmpty ? "No details" : prompt.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(prompt.detail.isEmpty ? 0.4 : 0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
            HStack(spacing: 8) {
                Spacer()
                Button { answer(prompt.id, .deny) } label: {
                    Text("Deny")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 28)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button { answer(prompt.id, .allow) } label: {
                    Text("Allow")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 28)
                        .background(Capsule().fill(accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request: \(prompt.title)")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct NotchSwitch: View {
    let isOn: Bool
    let accent: LinearGradient

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(Color.white.opacity(0.16))
            Capsule().fill(accent).opacity(isOn ? 1 : 0)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                .padding(2.5)
        }
        .frame(width: 40, height: 24)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
    }
}
