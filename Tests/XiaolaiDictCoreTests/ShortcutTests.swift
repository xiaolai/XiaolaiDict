import Carbon.HIToolbox
import Foundation
import XiaolaiDictCore
import Testing
import XiaolaiDictTestSupport

/// The shortcut as data: what can be saved, loaded and labelled without trapping.
struct ShortcutTests {
    /// **A key code no keyboard has is not a shortcut.** `Codable` accepts any `UInt32`, and
    /// `isUsable` checked only the modifiers — so a hand-edited or corrupted preference with a key
    /// code past 65,535 was loaded as usable, and labelling it for the menu converted it with
    /// `UInt16(_:)`, which traps. Virtual key codes are seven bits.
    @Test func aKeyCodeNoKeyboardHasIsNotUsable() {
        #expect(!Shortcut(keyCode: 70_000, modifiers: UInt32(cmdKey)).isUsable)
        #expect(!Shortcut(keyCode: 0x80, modifiers: UInt32(cmdKey)).isUsable)
        #expect(Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey)).isUsable)
    }

    @Test func aCorruptSavedKeyCodeFallsBackToTheDefault() throws {
        let defaults = TemporaryDefaults.suite()
        let corrupt = try JSONEncoder().encode(Shortcut(keyCode: 70_000, modifiers: UInt32(cmdKey)))
        defaults.set(corrupt, forKey: ShortcutStore.key)
        #expect(ShortcutStore(defaults: defaults).load() == .defaultLookUp)
    }

    /// And the layout lookup refuses it rather than trapping, whoever asks.
    @Test func theLayoutHasNoNameForAKeyItCannotHave() {
        #expect(Shortcut.currentLayoutName(70_000) == nil)
    }

    /// The layout answers keypad Enter and Clear with control characters — U+0003 and U+001B —
    /// which would print as nothing in a menu.
    @Test func keypadEnterAndClearHaveTheirOwnLabels() {
        let control: (UInt32) -> String? = { $0 == UInt32(kVK_ANSI_KeypadEnter) ? "\u{3}" : "\u{1B}" }
        #expect(Shortcut(keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: UInt32(cmdKey)).label(keyName: control) == "⌘⌤")
        #expect(Shortcut(keyCode: UInt32(kVK_ANSI_KeypadClear), modifiers: UInt32(cmdKey)).label(keyName: control) == "⌘⌧")
    }

    /// **The option is the mask, not the bit number.** `kUCKeyTranslateNoDeadKeysBit` is 0 — the
    /// bit's *index* — so passing it asked for no options at all, and on a layout with dead keys
    /// (US International, French) a dead key labelled as nothing. The mask is 1.
    @Test func deadKeysAreSuppressedWithTheMask() {
        #expect(Shortcut.layoutTranslationOptions == OptionBits(kUCKeyTranslateNoDeadKeysMask))
        #expect(Shortcut.layoutTranslationOptions != 0)
    }
}
