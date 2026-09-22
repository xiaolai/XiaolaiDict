import Foundation

/// Whether the setup window has ever opened by itself.
///
/// **This is the only thing in the feature that remembers anything, and it decides exactly one
/// question: does the window open unasked at launch.** It never gates what the window shows. The
/// board reads live state every time, so a reader who opens it again after finishing sees the same
/// rows with ticks against them — not a congratulation, and not a refusal to open.
///
/// That separation is the whole reason re-running costs nothing. A flag that also hid the content
/// would make "let me check my setup" impossible to answer, which is the state most apps' one-shot
/// wizards end up in.
public struct SetupPresentationStore {
    public static let defaultsKey = "SetupWindowShown"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `object(forKey:)` rather than `bool(forKey:)`, so "never set" and "set to false" stay
    /// different — the same reason the text-size store reads its flags that way. A fresh install
    /// has never set it, and that is precisely the state that must open the window.
    public func hasOpenedBefore() -> Bool {
        defaults.object(forKey: Self.defaultsKey) as? Bool ?? false
    }

    public func markOpened() {
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// Puts a reader back to a fresh install's behaviour, for the next launch only. Nothing else is
    /// forgotten — not the chosen dictionary, not the shortcut, not a permission.
    public func forget() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
