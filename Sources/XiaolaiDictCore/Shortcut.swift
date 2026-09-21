import Carbon.HIToolbox
import Foundation

/// A key combination: a virtual key code and Carbon modifier flags.
///
/// In `XiaolaiDictCore` because it is data, and because the settings window draws it: the recorder
/// is a control in Settings rather than a window of its own, and `XiaolaiDictUI` cannot see the app
/// target. Registering the combination with the system stays in the app, where Carbon is.
public struct Shortcut: Equatable, Codable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌃⌥D — "Dictionary". Not a macOS default. VoiceOver users know ⌃⌥ as the VoiceOver keys,
    /// which is one reason the reader can change it.
    public static let defaultLookUp = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))

    /// ⌘, ⌃ or ⌥ is required: a shortcut of a bare key, or of ⇧ and a key, would fire while typing.
    public var isUsable: Bool {
        keyCode <= Self.highestKeyCode && modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    /// Virtual key codes are seven bits; `kVK_UpArrow` is 0x7E. `Codable` accepts any `UInt32`, so
    /// a hand-edited or corrupted preference could hold a key code no keyboard has — and one past
    /// 65,535 trapped when the menu labelled it, converting it with `UInt16(_:)`.
    static let highestKeyCode: UInt32 = 0x7F

    /// As macOS writes it: modifiers in the system's order, ⌃⌥⇧⌘, then the key as `keyName` labels
    /// it — by default the current keyboard layout, so the label is right on AZERTY and Dvorak too.
    public func label(keyName: (UInt32) -> String? = Shortcut.currentLayoutName) -> String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        let prefix = symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
        return prefix + (Self.specialKeys[Int(keyCode)] ?? keyName(keyCode)?.uppercased() ?? "key \(keyCode)")
    }

    /// Keys whose label is not a character the layout types.
    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        // The layout answers these with control characters (U+0003 and U+001B), which print as
        // nothing in a menu.
        kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadClear: "⌧",
    ]

    /// Dead keys suppressed, so a key that starts a composition on this layout (`^` on French,
    /// `` ` `` on US International) is labelled by what it types rather than by nothing. **The mask,
    /// not the bit**: `kUCKeyTranslateNoDeadKeysBit` is 0 — the bit's index — and passing it asked
    /// for no options at all.
    public static let layoutTranslationOptions = OptionBits(kUCKeyTranslateNoDeadKeysMask)

    /// The character the current keyboard layout types for `keyCode` with no modifiers.
    public static func currentLayoutName(_ keyCode: UInt32) -> String? {
        // `exactly`, because `UInt16(_:)` traps on a key code past 65,535 — which a corrupted
        // preference can hold, however `isUsable` screens it.
        guard let code = UInt16(exactly: keyCode),
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                layoutTranslationOptions, &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

/// The reader's chosen shortcut, kept in user defaults.
public struct ShortcutStore {
    public static let key = "lookUpShortcut"
    public let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The saved shortcut, or the default when none is saved — or what is saved is unusable.
    public func load() -> Shortcut {
        guard let data = defaults.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(Shortcut.self, from: data), saved.isUsable
        else { return .defaultLookUp }
        return saved
    }

    public func save(_ shortcut: Shortcut) throws {
        defaults.set(try JSONEncoder().encode(shortcut), forKey: Self.key)
    }
}
