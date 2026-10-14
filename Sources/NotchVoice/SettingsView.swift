import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let voice: VoiceController
    private let preferences: Preferences
    private var window: NSWindow?

    init(voice: VoiceController, preferences: Preferences) {
        self.voice = voice
        self.preferences = preferences
    }

    func show() {
        voice.loadSettings()
        preferences.refresh()
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView(voice: voice, preferences: preferences))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.title = "NotchVoice Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let available = (NSScreen.main?.visibleFrame.height ?? SettingsView.size.height) - 24
        window.setContentSize(CGSize(width: SettingsView.size.width, height: min(SettingsView.size.height, available)))
        return window
    }
}

struct SettingsView: View {
    static let size = CGSize(width: 470, height: 1180)
    private static let spokenContentSettings = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!

    @ObservedObject var voice: VoiceController
    @ObservedObject var preferences: Preferences
    @State private var catalog = VoiceCatalog.load()

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("Voice") {
                    LabeledContent("Voice") {
                        HStack(spacing: 8) {
                            voiceMenu
                            Button { voice.playSample() } label: { Image(systemName: "play.fill") }
                                .help("Play a sample")
                            InfoButton("Your Mac's system voice is chosen in System Settings › Accessibility › Spoken Content.") {
                                Button("Open Spoken Content…") { NSWorkspace.shared.open(Self.spokenContentSettings) }
                            }
                        }
                    }
                    LabeledContent("Speed") {
                        HStack(spacing: 10) {
                            Slider(value: speed, in: 0.6...2.0)
                            Text(String(format: "%.1f×", voice.speed))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    Toggle(isOn: keepsRepliesShort) {
                        Label2("Short spoken replies", info: "Reminds Claude to answer in a few sentences while voice replies are on.")
                    }
                    LabeledContent("Music while speaking") {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: musicVolume, in: 0...1)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                            Text("\(Int((voice.musicVolume * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    .help("Spotify and Apple Music turn down to this level while Claude speaks.")
                }
                Section("Glow") {
                    themePicker
                }
                Section("Sessions") {
                    Toggle(isOn: orchestratorMode) {
                        Label2("Orchestrator mode", info: "Only the session where you ran /orchestrator speaks. It briefs you on the others and passes your instructions on.")
                    }
                    Toggle(isOn: asksForPermission) {
                        Label2("Permission requests in the notch", info: "Claude's own prompt still works too; the first answer counts.")
                    }
                }
                Section("Hands-free") {
                    Toggle(isOn: listensForWakeWord) {
                        Label2("Listen for the wake phrase", info: "Say the wake phrase, dictate with Wispr Flow, then say the send phrase. Your message is typed into the orchestrator session. The phrases are recognised on this Mac.")
                    }
                    Group {
                        Toggle(isOn: listensThroughHeadphones) {
                            Label2("Use AirPods mic", info: "Listen through your AirPods while a reply is playing, so you can say \u{201C}skip\u{201D}, and when you haven't used the keyboard or mouse for a while. Their audio is call quality while the mic is open.")
                        }
                        if preferences.listensThroughHeadphones {
                            LabeledContent("Away after") {
                                Stepper(awayLabel, value: awayDelay, in: Preferences.awayDelayRange, step: 30)
                            }
                            Toggle("Not while music plays", isOn: skipsHeadphonesDuringMusic)
                                .help("Spotify and Apple Music keep full quality; the MacBook mic listens instead.")
                        }
                        PhraseEditor(preferences: preferences)
                    }
                    .disabled(!preferences.listensForWakeWord)
                }
                Section("Shortcuts") {
                    ShortcutRecorder(
                        title: "Mute",
                        shortcut: preferences.muteShortcut,
                        setShortcut: preferences.setMuteShortcut,
                        pauseShortcut: preferences.pauseMuteShortcut
                    )
                    ShortcutRecorder(
                        title: "Skip reply",
                        shortcut: preferences.skipShortcut,
                        setShortcut: preferences.setSkipShortcut,
                        pauseShortcut: preferences.pauseSkipShortcuts
                    )
                    ShortcutRecorder(
                        title: "Skip all",
                        shortcut: preferences.skipAllShortcut,
                        setShortcut: preferences.setSkipAllShortcut,
                        pauseShortcut: preferences.pauseSkipShortcuts
                    )
                }
                Section {
                    Toggle("Open at Login", isOn: opensAtLogin)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            footer
        }
        .frame(width: Self.size.width)
        .frame(minHeight: 480, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black)
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(preferences.theme.accent)
            }
            .frame(width: 48, height: 48)
            .shadow(color: preferences.theme.colors[0].opacity(0.6), radius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text("NotchVoice")
                    .font(.title2.weight(.semibold))
                Text("Claude Code, out loud.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                .foregroundStyle(.secondary)
            Link("GitHub", destination: URL(string: "https://github.com/NCSmit/notch-voice")!)
            Spacer()
            Button("Quit NotchVoice") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }

    private var voiceMenu: some View {
        Menu {
            voiceToggle(id: nil, name: voice.systemVoiceLabel)
            ForEach(catalog.preferred) { group in
                Section(group.title) {
                    ForEach(group.voices) { voiceToggle(id: $0.id, name: $0.name) }
                }
            }
            Divider()
            Menu("Novelty") {
                ForEach(catalog.novelty) { voiceToggle(id: $0.id, name: $0.name) }
            }
            Menu("Other Languages") {
                ForEach(catalog.others) { language in
                    Menu(language.name) {
                        ForEach(language.groups) { group in
                            Section(group.title) {
                                ForEach(group.voices) { voiceToggle(id: $0.id, name: $0.name) }
                            }
                        }
                    }
                }
            }
        } label: {
            Text(voice.voiceName)
        }
        .fixedSize()
    }

    private func voiceToggle(id: String?, name: String) -> some View {
        Toggle(name, isOn: Binding(get: { voice.voiceID == id }, set: { if $0 { voice.setVoice(id) } }))
    }

    private var themePicker: some View {
        HStack(spacing: 0) {
            ForEach(GlowTheme.allCases) { theme in
                let isSelected = preferences.theme == theme
                Button {
                    preferences.setTheme(theme)
                } label: {
                    VStack(spacing: 7) {
                        Circle()
                            .fill(AngularGradient(colors: theme.colors, center: .center))
                            .frame(width: 34, height: 34)
                            .shadow(color: theme.colors[0].opacity(isSelected ? 0.7 : 0), radius: 8)
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 2)
                                    .padding(-5)
                            }
                        Text(theme.name)
                            .font(.caption)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.2), value: preferences.theme)
    }

    private var speed: Binding<Double> {
        Binding(get: { voice.speed }, set: { voice.setSpeed(($0 * 10).rounded() / 10) })
    }

    private var keepsRepliesShort: Binding<Bool> {
        Binding(get: { voice.keepsRepliesShort }, set: { voice.setKeepsRepliesShort($0) })
    }

    private var awayDelay: Binding<Double> {
        Binding(get: { preferences.awayDelay }, set: { preferences.setAwayDelay($0) })
    }

    private var awayLabel: String {
        let seconds = Int(preferences.awayDelay)
        if seconds < 60 { return "\(seconds) s" }
        return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
    }

    private var listensThroughHeadphones: Binding<Bool> {
        Binding(get: { preferences.listensThroughHeadphones }, set: { preferences.setListensThroughHeadphones($0) })
    }

    private var skipsHeadphonesDuringMusic: Binding<Bool> {
        Binding(get: { preferences.skipsHeadphonesDuringMusic }, set: { preferences.setSkipsHeadphonesDuringMusic($0) })
    }

    private var listensForWakeWord: Binding<Bool> {
        Binding(get: { preferences.listensForWakeWord }, set: { preferences.setListensForWakeWord($0) })
    }

    private var orchestratorMode: Binding<Bool> {
        Binding(get: { voice.isOrchestratorMode }, set: { voice.setOrchestratorMode($0) })
    }

    private var musicVolume: Binding<Double> {
        Binding(get: { voice.musicVolume }, set: { voice.setMusicVolume(($0 * 20).rounded() / 20) })
    }

    private var asksForPermission: Binding<Bool> {
        Binding(get: { preferences.asksForPermission }, set: { preferences.setAsksForPermission($0) })
    }

    private var opensAtLogin: Binding<Bool> {
        Binding(get: { preferences.opensAtLogin }, set: { preferences.setOpensAtLogin($0) })
    }
}


/// A setting's label with an ⓘ that explains it, instead of a paragraph under it.
struct Label2: View {
    let title: String
    let info: String

    init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(info)
        }
    }
}

struct InfoButton<Extra: View>: View {
    let text: String
    let extra: Extra
    @State private var showing = false

    init(_ text: String, @ViewBuilder extra: () -> Extra) {
        self.text = text
        self.extra = extra()
    }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                extra
            }
            .padding(14)
            .frame(width: 260)
        }
    }
}

extension InfoButton where Extra == EmptyView {
    init(_ text: String) {
        self.init(text) { EmptyView() }
    }
}

/// The spoken phrases, edited as a set: saved when one is committed, if they're all usable.
struct PhraseEditor: View {
    @ObservedObject var preferences: Preferences
    @State private var draft = VoicePhrases.defaults
    @State private var problem: String?

    var body: some View {
        Group {
            field("Wake phrase", \.wake)
            field("Send phrase", \.send)
            field("Cancel phrase", \.cancel)
            field("Skip phrase", \.skip)
            field("Skip all phrase", \.skipAll)
            HStack {
                Text(problem ?? "Short, common words can misfire.")
                    .font(.caption)
                    .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                Spacer()
                if draft != .defaults {
                    Button("Reset") {
                        draft = .defaults
                        problem = preferences.setPhrases(draft)
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear { draft = preferences.phrases }
    }

    private func field(_ title: String, _ path: WritableKeyPath<VoicePhrases, String>) -> some View {
        TextField(title, text: Binding(get: { draft[keyPath: path] }, set: { draft[keyPath: path] = $0 }))
            .onSubmit { problem = preferences.setPhrases(draft) }
            .onChange(of: draft[keyPath: path]) {
                // Save as you type when valid; show what's wrong otherwise (the last good phrases stay in use).
                problem = preferences.setPhrases(draft)
            }
    }
}
