import Foundation

/// **Whether the bundled model's setup is shown** — `defaults write com.xiaolaidict ShowLocalModelSetup -bool YES`
/// (ADR-0053). The bundled model is hidden, not removed: no row asks for its download, no pane offers one, and About
/// does not name it, unless this is set or a model is already on disk. Nothing else about the model changes with it —
/// its code, its service and its tests all run either way, so the path does not rot on the day small models are good
/// enough.
///
/// It takes its defaults suite and has no default of its own: the app reads only the suite it was given.
public struct LocalModelSetupFlag {
    public static let defaultsKey = "ShowLocalModelSetup"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// Set, by whatever spelling `defaults write` writes a yes in — `-bool YES`, `-int 1`, `-string YES`. Lenient on
    /// purpose, unlike the CLI switch: this reveals a setup row, and consents to nothing.
    public func isSet() -> Bool { defaults.bool(forKey: Self.defaultsKey) }
}
