import AppKit
import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "local.notchvoice", category: "hotkey")

struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    private static let modifierKeys: [(flag: NSEvent.ModifierFlags, carbonFlag: Int, symbol: String)] = [
        (.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘"),
    ]

    private static let keyNames: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_ANSI_KeypadClear: "⌧", kVK_Help: "Help",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = Self.modifierKeys.filter { flags.contains($0.flag) }.reduce(0) { $0 | UInt32($1.carbonFlag) }
    }

    @MainActor
    var displayName: String {
        let symbols = Self.modifierKeys.filter { modifiers & UInt32($0.carbonFlag) != 0 }.map(\.symbol).joined()
        return symbols + (Self.keyNames[Int(keyCode)] ?? Self.character(for: keyCode) ?? "Key \(keyCode)")
    }

    @MainActor
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate(
                $0, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let name = String(utf16CodeUnits: characters, count: length).uppercased()
        return name.rangeOfCharacter(from: .controlCharacters) == nil ? name : nil
    }
}

@MainActor
final class Hotkey {
    private static let signature = "NVhk".utf8.reduce(OSType(0)) { $0 << 8 | OSType($1) }
    private static var nextID: UInt32 = 1

    private(set) var shortcut: Shortcut?
    private let action: @MainActor () -> Void
    private let release: (@MainActor () -> Void)?
    private let id: EventHotKeyID
    nonisolated(unsafe) private var registration: EventHotKeyRef?
    nonisolated(unsafe) private var handler: EventHandlerRef?

    /// `release`, when given, is called when the shortcut's keys are let go, for hold-to-talk.
    init(action: @escaping @MainActor () -> Void, release: (@MainActor () -> Void)? = nil) {
        self.action = action
        self.release = release
        id = EventHotKeyID(signature: Self.signature, id: Self.nextID)
        Self.nextID += 1
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var pressedID = EventHotKeyID()
            guard let event, let userData,
                  GetEventParameter(
                      event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &pressedID
                  ) == noErr
            else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            return MainActor.assumeIsolated { hotkey.handle(pressedID, isRelease: isRelease) }
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ shortcut: Shortcut?) -> Bool {
        guard shortcut != self.shortcut else { return true }
        var newRegistration: EventHotKeyRef?
        if let shortcut {
            let status = RegisterEventHotKey(
                shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &newRegistration
            )
            guard status == noErr else {
                log.error("could not register \(shortcut.displayName, privacy: .public): \(status)")
                return false
            }
        }
        if let registration { UnregisterEventHotKey(registration) }
        registration = newRegistration
        self.shortcut = shortcut
        return true
    }

    private func handle(_ pressedID: EventHotKeyID, isRelease: Bool) -> OSStatus {
        guard pressedID.signature == id.signature, pressedID.id == id.id else { return OSStatus(eventNotHandledErr) }
        if isRelease {
            release?()
        } else {
            action()
        }
        return noErr
    }
}
