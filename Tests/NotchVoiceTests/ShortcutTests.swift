import AppKit
import Carbon.HIToolbox
import Testing
@testable import NotchVoice

@MainActor
struct ShortcutTests {
    @Test func modifiersAreShownInApplesOrder() {
        let shortcut = Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(shortcut.displayName == "⌃⌥⇧⌘F5")
    }

    @Test func specialKeysHaveReadableNames() {
        #expect(Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)).displayName == "⌥Space")
        #expect(Shortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey)).displayName == "⌘←")
        #expect(Shortcut(keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey)).displayName == "⌃⎋")
    }

    @Test func aShortcutNeedsCommandOptionOrControl() throws {
        #expect(Shortcut(event: try keyDown([])) == nil)
        #expect(Shortcut(event: try keyDown(.shift)) == nil)
        let recorded = Shortcut(event: try keyDown([.command, .option]))
        #expect(recorded == Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey)))
    }

    private func keyDown(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: UInt16(kVK_ANSI_M)
        ))
    }
}
