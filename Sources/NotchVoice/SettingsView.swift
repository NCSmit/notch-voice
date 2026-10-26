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
        // Otherwise the name field takes focus with its text selected, and a stray key would replace the name.
        window.makeFirstResponder(nil)
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
        let height = SettingsView.size.height + (preferences.hasWisprFlow ? SettingsView.wisprFlowHeight : 0)
        let available = (NSScreen.main?.visibleFrame.height ?? height) - 24
        window.setContentSize(CGSize(width: SettingsView.size.width, height: min(height, available)))
        return window
    }
}

struct SettingsView: View {
    static let size = CGSize(width: 470, height: 1384)
    /// The room the Wispr Flow row and its longer footer take, when Wispr Flow is installed.
    static let wisprFlowHeight: CGFloat = 52
    private static let spokenContentSettings = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!

    @ObservedObject var voice: VoiceController
    @ObservedObject var preferences: Preferences
    @State private var catalog = VoiceCatalog.load()
    @State private var wakeNameDraft = ""
    @FocusState private var isEditingName: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    LabeledContent("Voice") { voiceMenu }
                    LabeledContent("Speed") {
                        HStack(spacing: 10) {
                            Slider(value: speed, in: 0.6...2.0)
                            Text(String(format: "%.1f×", voice.speed))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    LabeledContent {
                        Button("Play Sample", systemImage: "play.fill") { voice.playSample() }
                    } label: {
                        Button("Change System Voice…") { NSWorkspace.shared.open(Self.spokenContentSettings) }
                            .buttonStyle(.link)
                            .help("Opens Spoken Content in System Settings, where your Mac's voice is chosen")
                    }
                    Toggle("Keep spoken replies short", isOn: keepsRepliesShort)
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Reminds Claude to answer in a few sentences while voice replies are on.")
                }
                Section {
                    LabeledContent("Music volume") {
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
                } header: {
                    Text("Music")
                } footer: {
                    Text("Spotify and Apple Music turn down to this level while Claude speaks.")
                }
                Section("Glow") {
                    themePicker
                }
                Section {
                    Toggle("Ask for permission in the notch", isOn: asksForPermission)
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Claude's own prompt still works too, and the first answer counts.")
                }
                Section {
                    Toggle("Show sessions in the menu bar", isOn: showsSessionsInMenuBar)
                } header: {
                    Text("Sessions")
                } footer: {
                    Text("Lists your open Claude Code sessions. Click one to go to its window.")
                }
                Section {
                    Toggle("Listen for \u{201C}\(TalkPhrases.wakePhrase(preferences.wakeName))\u{201D}", isOn: listensForWakePhrase)
                    LabeledContent("Name") {
                        TextField("Name", text: $wakeNameDraft, prompt: Text(Preferences.defaultWakeName))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 150)
                            .focused($isEditingName)
                            .onSubmit(saveWakeName)
                            .onChange(of: isEditingName) { _, editing in
                                if !editing { saveWakeName() }
                            }
                            .onDisappear(perform: saveWakeName)
                    }
                    ShortcutRecorder(
                        title: "Talk shortcut",
                        shortcut: preferences.talkShortcut,
                        setShortcut: preferences.setTalkShortcut,
                        pauseShortcut: preferences.pauseShortcuts
                    )
                    Picker("Talk shortcut works by", selection: talkMode) {
                        Text("Holding it down").tag(TalkMode.hold)
                        Text("Pressing it to start").tag(TalkMode.press)
                    }
                    LabeledContent("Pause before sending") {
                        HStack(spacing: 10) {
                            Slider(value: pauseBeforeSending, in: TalkPolicy.pauses, step: 0.5)
                            Text(String(format: "%.1f s", preferences.pauseBeforeSending))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    .help("How long a pause sends a message after \u{201C}\(TalkPhrases.wakePhrase(preferences.wakeName))\u{201D} or a press of the talk shortcut. Holding the shortcut down sends when you let go.")
                    if preferences.hasWisprFlow {
                        Picker("Write out messages with", selection: transcriber) {
                            Text("Apple (on this Mac)").tag(Transcriber.apple)
                            Text("Wispr Flow").tag(Transcriber.wisprFlow)
                        }
                    }
                } header: {
                    Text("Talk to the orchestrator")
                } footer: {
                    Text(talkFooter)
                }
                .onAppear { wakeNameDraft = preferences.wakeName }
                Section("General") {
                    ShortcutRecorder(
                        title: "Mute shortcut",
                        shortcut: preferences.muteShortcut,
                        setShortcut: preferences.setMuteShortcut,
                        pauseShortcut: preferences.pauseShortcuts
                    )
                    ShortcutRecorder(
                        title: "Skip shortcut",
                        shortcut: preferences.skipShortcut,
                        setShortcut: preferences.setSkipShortcut,
                        pauseShortcut: preferences.pauseShortcuts
                    )
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

    private var musicVolume: Binding<Double> {
        Binding(get: { voice.musicVolume }, set: { voice.setMusicVolume(($0 * 20).rounded() / 20) })
    }

    private var asksForPermission: Binding<Bool> {
        Binding(get: { preferences.asksForPermission }, set: { preferences.setAsksForPermission($0) })
    }

    private var showsSessionsInMenuBar: Binding<Bool> {
        Binding(get: { preferences.showsSessionsInMenuBar }, set: { preferences.setShowsSessionsInMenuBar($0) })
    }

    private var listensForWakePhrase: Binding<Bool> {
        Binding(get: { preferences.listensForWakePhrase }, set: { preferences.setListensForWakePhrase($0) })
    }

    private var talkMode: Binding<TalkMode> {
        Binding(get: { preferences.talkMode }, set: { preferences.setTalkMode($0) })
    }

    private var pauseBeforeSending: Binding<Double> {
        Binding(get: { preferences.pauseBeforeSending }, set: { preferences.setPauseBeforeSending($0) })
    }

    private var transcriber: Binding<Transcriber> {
        Binding(get: { preferences.transcriber }, set: { preferences.setTranscriber($0) })
    }

    private var talkFooter: String {
        let phrase = "\u{201C}\(TalkPhrases.wakePhrase(preferences.wakeName))\u{201D}"
        let microphone = "While listening is on and an orchestrator is open, the microphone stays on."
        guard preferences.hasWisprFlow, preferences.transcriber == .wisprFlow else {
            return "Say \(phrase) or use the shortcut, then speak to the session where you ran /orchestrator. Your words are recognised on this Mac. \(microphone)"
        }
        return "Say \(phrase) or use the shortcut, wait for the sound, then speak to the session where you ran /orchestrator. Wispr Flow writes out your message, and NotchVoice keeps the keyboard until it\u{2019}s done. \(microphone)"
    }

    private func saveWakeName() {
        preferences.setWakeName(wakeNameDraft)
        wakeNameDraft = preferences.wakeName
    }

    private var opensAtLogin: Binding<Bool> {
        Binding(get: { preferences.opensAtLogin }, set: { preferences.setOpensAtLogin($0) })
    }
}
