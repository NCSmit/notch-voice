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
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(voice: voice, preferences: preferences)))
        window.title = "NotchVoice Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        return window
    }
}

struct SettingsView: View {
    @ObservedObject var voice: VoiceController
    @ObservedObject var preferences: Preferences
    @State private var catalog = VoiceCatalog.load()

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("Voice") {
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
                        Text("Hear the voice with these settings")
                            .foregroundStyle(.secondary)
                    }
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
                    Text("While Claude speaks, Spotify and Apple Music turn down to this level. Afterwards they go back to how loud they were.")
                }
                Section("Glow") {
                    themePicker
                }
                Section("General") {
                    Toggle("Open at Login", isOn: opensAtLogin)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            footer
        }
        .frame(width: 470, height: 692)
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
            voiceToggle(id: nil, name: "System Voice")
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

    private var musicVolume: Binding<Double> {
        Binding(get: { voice.musicVolume }, set: { voice.setMusicVolume(($0 * 20).rounded() / 20) })
    }

    private var opensAtLogin: Binding<Bool> {
        Binding(get: { preferences.opensAtLogin }, set: { preferences.setOpensAtLogin($0) })
    }
}
