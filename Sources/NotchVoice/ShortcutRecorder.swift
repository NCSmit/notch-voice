import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: View {
    let title: String
    let shortcut: Shortcut?
    let setShortcut: @MainActor (Shortcut?) -> Bool
    let pauseShortcut: @MainActor (Bool) -> Void
    @State private var keyMonitor: Any?
    @State private var isInUse = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(isRecording ? "Press a shortcut…" : shortcut?.displayName ?? "None")
                    .foregroundStyle(isRecording || shortcut == nil ? .secondary : .primary)
                Button(isRecording ? "Cancel" : "Record") {
                    if isRecording { stopRecording() } else { startRecording() }
                }
                if shortcut != nil, !isRecording {
                    Button("Clear Shortcut", systemImage: "xmark.circle.fill") { change(to: nil) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear Shortcut")
                }
            }
        } label: {
            Text(title)
            if isInUse {
                Text("That shortcut is already in use")
                    .foregroundStyle(.red)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
            isInUse = false
        }
    }

    private var isRecording: Bool { keyMonitor != nil }

    private func startRecording() {
        isInUse = false
        pauseShortcut(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if let shortcut = Shortcut(event: event) {
            stopRecording()
            change(to: shortcut)
        } else if Int(event.keyCode) == kVK_Escape {
            stopRecording()
        }
    }

    private func change(to shortcut: Shortcut?) {
        isInUse = !setShortcut(shortcut)
    }

    private func stopRecording() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
        pauseShortcut(false)
    }
}
