import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var voice: VoiceController
    let showVoiceMenu: @MainActor (CGRect) -> Void

    var body: some View {
        NotchView(
            metrics: state.metrics,
            isOpen: state.isOpen,
            isEnabled: voice.isEnabled,
            isSpeaking: voice.isSpeaking,
            voiceName: voice.voiceName,
            setEnabled: voice.setEnabled,
            showVoiceMenu: showVoiceMenu
        )
    }
}

struct NotchView: View {
    let metrics: NotchMetrics
    let isOpen: Bool
    let isEnabled: Bool
    let isSpeaking: Bool
    let voiceName: String
    let setEnabled: @MainActor (Bool) -> Void
    let showVoiceMenu: @MainActor (CGRect) -> Void

    var body: some View {
        let size = isOpen ? metrics.openSize : metrics.closedSize
        let topRadius = isOpen ? NotchMetrics.openTopRadius : NotchMetrics.closedTopRadius
        let bottomRadius = isOpen ? NotchMetrics.openBottomRadius : NotchMetrics.closedBottomRadius
        let showsBody = isOpen || isSpeaking

        ZStack(alignment: .top) {
            NotchGlow(
                outline: NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, isClosed: false),
                isActive: isSpeaking
            )
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(.black)
                .animation(showsBody ? .easeOut(duration: 0.15) : .easeIn(duration: 0.2).delay(0.3)) {
                    $0.opacity(showsBody ? 1 : 0)
                }
            if isOpen {
                VoicePanel(
                    isEnabled: isEnabled,
                    isSpeaking: isSpeaking,
                    voiceName: voiceName,
                    setEnabled: setEnabled,
                    showVoiceMenu: showVoiceMenu
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
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.56, blue: 0.36),
        Color(red: 1.00, green: 0.77, blue: 0.47),
        Color(red: 1.00, green: 0.45, blue: 0.62),
        Color(red: 0.74, green: 0.52, blue: 1.00),
        Color(red: 0.42, green: 0.64, blue: 1.00),
        Color(red: 1.00, green: 0.56, blue: 0.36),
    ]

    static let accent = LinearGradient(colors: [colors[0], colors[2]], startPoint: .leading, endPoint: .trailing)

    static func level(at time: Double) -> Double {
        let breath = sin(time * 2 * .pi * 0.5)
        let chatter = sin(time * 2 * .pi * 2.6) * sin(time * 2 * .pi * 0.7 + 1.1)
        return 0.6 + 0.25 * breath + 0.15 * chatter
    }
}

struct NotchGlow: View {
    let outline: NotchShape
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let level = reduceMotion ? 0.8 : Glow.level(at: time)
            let spin = reduceMotion ? 0 : (time * 45).truncatingRemainder(dividingBy: 360)
            let gradient = AngularGradient(colors: Glow.colors, center: .center, angle: .degrees(spin))
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
    let voiceName: String
    let setEnabled: @MainActor (Bool) -> Void
    let showVoiceMenu: @MainActor (CGRect) -> Void
    @State private var voiceButtonFrame = CGRect.zero

    var body: some View {
        VStack(spacing: 0) {
            toggleRow
            voiceRow
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
        .contextMenu {
            Toggle("Open at Login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0) }))
            Divider()
            Button("Quit NotchVoice") { NSApp.terminate(nil) }
        }
    }

    private var toggleRow: some View {
        HStack(spacing: 12) {
            Image(systemName: isEnabled ? "waveform" : "waveform.slash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isEnabled ? AnyShapeStyle(Glow.accent) : AnyShapeStyle(Color.white.opacity(0.35)))
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
            NotchSwitch(isOn: isEnabled)
        }
        .frame(height: 50)
        .contentShape(Rectangle())
        .onTapGesture { setEnabled(!isEnabled) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice replies")
        .accessibilityValue(isEnabled ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { setEnabled(!isEnabled) }
    }

    private var voiceRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 24)
            Text("Voice")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Text(voiceName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { voiceButtonFrame = $0 }
        }
        .frame(height: 34)
        .contentShape(Rectangle())
        .onTapGesture { showVoiceMenu(voiceButtonFrame) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice")
        .accessibilityValue(voiceName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showVoiceMenu(voiceButtonFrame) }
    }

    private var status: String {
        if isSpeaking { return "Speaking…" }
        return isEnabled ? "Replies are read aloud" : "Off"
    }
}

struct NotchSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(Color.white.opacity(0.16))
            Capsule().fill(Glow.accent).opacity(isOn ? 1 : 0)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                .padding(2.5)
        }
        .frame(width: 40, height: 24)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
    }
}
