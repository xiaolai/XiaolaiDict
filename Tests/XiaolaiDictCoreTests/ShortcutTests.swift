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

    // MARK: - Reserved combinations

    /// A US layout, spoken for by the test rather than read from the Mac it runs on.
    private static let qwerty: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_F: "f", kVK_ANSI_H: "h",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q",
        kVK_ANSI_S: "s", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Z: "z",
        kVK_ANSI_Comma: ",", kVK_ANSI_J: "j", kVK_ANSI_3: "3",
    ]
    private static func us(_ code: UInt32) -> String? { qwerty[Int(code)] }

    private func reserved(_ key: Int, _ modifiers: Int, layout: (UInt32) -> String? = us) -> Bool {
        Shortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers)).isReserved(keyName: layout)
    }

    /// **The standard commands cannot become the lookup shortcut.** A registered hot key is
    /// taken before any app sees the key, so ⌘C recorded by a mis-press made Copy look a word up
    /// in every app. Each of these was accepted: `isUsable` asks only for a modifier.
    @Test func theStandardCommandsAreReserved() {
        for key in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_Q,
                    kVK_ANSI_W, kVK_ANSI_S, kVK_ANSI_F, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
                    kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_Comma, kVK_Tab, kVK_Space] {
            #expect(reserved(key, cmdKey), "⌘ with key code \(key) was accepted as a global hot key")
            #expect(Shortcut(keyCode: UInt32(key), modifiers: UInt32(cmdKey)).isUsable,
                    "the positive control: this is a combination `isUsable` alone lets through")
        }
    }

    /// And the system's own: Redo, the screenshot commands, Force Quit, lock, input sources.
    @Test func theSystemsOwnCombinationsAreReserved() {
        #expect(reserved(kVK_ANSI_Z, cmdKey | shiftKey))
        #expect(reserved(kVK_ANSI_3, cmdKey | shiftKey))
        #expect(reserved(kVK_Escape, cmdKey | optionKey))
        #expect(reserved(kVK_ANSI_Q, cmdKey | controlKey))
        #expect(reserved(kVK_Space, controlKey))
        #expect(reserved(kVK_Space, cmdKey | optionKey))
    }

    /// **The rule is exact modifiers, not "contains ⌘".** A reservation that swallowed every
    /// combination with ⌘ in it would leave the reader almost nothing to choose, and would
    /// refuse the default's neighbours for no reason.
    @Test func theSameKeyWithOtherModifiersIsFree() {
        #expect(!reserved(kVK_ANSI_C, cmdKey | optionKey))
        #expect(!reserved(kVK_ANSI_C, cmdKey | controlKey))
        #expect(!reserved(kVK_ANSI_C, controlKey | optionKey))
        #expect(!reserved(kVK_ANSI_J, cmdKey), "⌘J is no standard command")
        #expect(!reserved(kVK_F5, cmdKey))
    }

    /// The shipped default is one the recorder would take back if the reader pressed it again.
    @Test func theDefaultIsNotReserved() {
        #expect(!Shortcut.defaultLookUp.isReserved(keyName: Self.us))
        #expect(Shortcut.defaultLookUp.isUsable)
    }

    /// **By the character the key types, not where it sits.** On Dvorak the key at QWERTY's I
    /// types C, so ⌘ with that key *is* Copy — and the key at QWERTY's C types J, which is not.
    @Test func reservationFollowsTheLayout() {
        let dvorak: (UInt32) -> String? = { code in
            switch Int(code) {
            case kVK_ANSI_I: "c"
            case kVK_ANSI_C: "j"
            default: nil
            }
        }
        #expect(reserved(kVK_ANSI_I, cmdKey, layout: dvorak))
        #expect(!reserved(kVK_ANSI_C, cmdKey, layout: dvorak))
    }

    /// Space, Tab and Escape type nothing a layout names, so they are matched by key code — and
    /// must still be matched when the layout answers nil for everything.
    @Test func theUnprintableKeysNeedNoLayout() {
        let silent: (UInt32) -> String? = { _ in nil }
        #expect(reserved(kVK_Space, cmdKey, layout: silent))
        #expect(reserved(kVK_Tab, cmdKey, layout: silent))
        #expect(!reserved(kVK_ANSI_C, cmdKey, layout: silent), "an unnamed key is not known to be reserved")
    }
}
