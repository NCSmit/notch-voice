import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var voice: VoiceController
    @ObservedObject var preferences: Preferences
    let answer: @MainActor (UUID, PermissionResponse) -> Void
    let cancelTalk: @MainActor () -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        NotchView(
            metrics: state.metrics,
            isOpen: state.isOpen,
            isEnabled: voice.isEnabled,
            isSpeaking: voice.isSpeaking,
            isGlowing: voice.isSpeaking || state.isPreviewingGlow || state.prompt != nil || state.talk != nil,
            theme: preferences.theme,
            prompt: state.prompt,
            pendingCount: state.pendingCount,
            talk: state.talk,
            setEnabled: voice.setEnabled,
            skip: voice.skip,
            answer: answer,
            cancelTalk: cancelTalk,
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
    let talk: TalkController.Card?
    let setEnabled: @MainActor (Bool) -> Void
    let skip: @MainActor (Bool) -> Void
    let answer: @MainActor (UUID, PermissionResponse) -> Void
    let cancelTalk: @MainActor () -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        let isExpanded = isOpen || prompt != nil || talk != nil
        let size = prompt != nil ? metrics.permissionSize : talk != nil ? metrics.talkSize : isOpen ? metrics.openSize : metrics.closedSize
        let topRadius = isExpanded ? NotchMetrics.openTopRadius : NotchMetrics.closedTopRadius
        let bottomRadius = isExpanded ? NotchMetrics.openBottomRadius : NotchMetrics.closedBottomRadius
        let showsBody = isExpanded || isGlowing

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
            if let prompt {
                PermissionCard(prompt: prompt, pendingCount: pendingCount, accent: theme.accent, answer: answer)
                    .id(prompt.id)
                    .padding(.top, metrics.notch.height)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))
                    ))
            } else if let talk {
                TalkCard(card: talk, accent: theme.accent, cancel: cancelTalk)
                    .padding(.top, metrics.notch.height)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))
                    ))
            } else if isOpen {
                VoicePanel(
                    isEnabled: isEnabled,
                    isSpeaking: isSpeaking,
                    accent: theme.accent,
                    setEnabled: setEnabled,
                    skip: skip,
                    openSettings: openSettings
                )
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
    let accent: LinearGradient
    let setEnabled: @MainActor (Bool) -> Void
    let skip: @MainActor (Bool) -> Void
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
                        .foregroundStyle(.white.opacity(0.5))
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { setEnabled(!isEnabled) }
            .accessibilityElement(children: .combine)

            if isSpeaking {
                Button {
                    skip(NSEvent.modifierFlags.contains(.option))
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Skip this reply. Option-click to skip every reply waiting too.")
                .accessibilityLabel("Skip this reply")
                .accessibilityAction(named: "Skip every reply") { skip(true) }
            }

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
            if isSpeaking {
                Button("Skip This Reply") { skip(false) }
                Button("Skip Every Reply") { skip(true) }
                Divider()
            }
            Button("Settings…") { openSettings() }
            Divider()
            Button("Quit NotchVoice") { NSApp.terminate(nil) }
        }
    }

    private var status: String {
        if isSpeaking { return "Speaking…" }
        return isEnabled ? "Replies are read aloud" : "Off"
    }
}

struct TalkCard: View {
    let card: TalkController.Card
    let accent: LinearGradient
    let cancel: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: isListening)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isError ? AnyShapeStyle(Color.orange) : AnyShapeStyle(accent)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.head)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isListening {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Stop without sending")
                .accessibilityLabel("Stop without sending")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var isListening: Bool {
        if case .listening = card { return true }
        return false
    }

    private var isError: Bool {
        if case .done(_, true) = card { return true }
        return false
    }

    private var symbol: String {
        switch card {
        case .listening: "mic.fill"
        case .writing: "ellipsis"
        case .sending: "paperplane.fill"
        case .sent: "checkmark"
        case .done(_, let isError): isError ? "exclamationmark" : "xmark"
        }
    }

    private var title: String {
        switch card {
        case .listening(let words, _): words.isEmpty ? "Listening…" : words
        case .writing(let words): words.isEmpty ? "Your message" : words
        case .sending(let words): words
        case .sent: "Sent to the orchestrator"
        case .done(let message, _): message
        }
    }

    private var detail: String {
        switch card {
        case .listening(_, let hint): hint
        case .writing: "Wispr Flow is writing it out…"
        case .sending: "Sending to the orchestrator…"
        case .sent: "It will answer out loud"
        case .done: "Nothing was sent"
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
