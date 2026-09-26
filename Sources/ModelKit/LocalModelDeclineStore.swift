import Foundation

/// Whether the reader chose **Not now** for the local model.
///
/// Its own flag, as the plan asks: the model row is settled by the model being downloaded or by the
/// reader declining it, and a decline must outlive the app quitting or the board would ask again at
/// every launch. It never removes the download — the row keeps it one click away — and starting a
/// download clears it.
public struct LocalModelDeclineStore {
    public static let defaultsKey = "LocalModelDeclined"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func hasDeclined() -> Bool { defaults.bool(forKey: Self.defaultsKey) }

    public func decline() { defaults.set(true, forKey: Self.defaultsKey) }

    public func clear() { defaults.removeObject(forKey: Self.defaultsKey) }
}
