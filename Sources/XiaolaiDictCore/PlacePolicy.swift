/// Which apps' page and file XiaolaiDict is willing to record.
///
/// A URL or a file path is considerably more sensitive than the word it came with: the probe that
/// measured what apps can say walked past a password manager, two messaging apps and a browser that
/// also does banking. So the app is always recorded — it is how "in Safari" gets said at all — and
/// the place inside it is not, for apps on this list (`dev-docs/where-a-word-was-read.md` §5).
///
/// It ships non-empty on purpose. The list has to exist **before** the columns are first written,
/// not after, or the first excluded app is already in the database (§7).
public struct PlacePolicy: Sendable, Equatable {
    /// Password managers, at minimum. Messaging apps are the reader's call and are not excluded by
    /// default, because excluding them silently would make "where did I read this" wrong without
    /// saying so.
    public static let passwordManagers: Set<String> = [
        "com.1password.1password",
        "com.1password.1password-launcher",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.dashlane.Dashlane",
        "in.sinew.Enpass-Desktop",
        "com.keepassium.mac",
        "org.keepassxc.keepassxc",
        "com.lastpass.LastPass",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    public static let shipped = PlacePolicy(excluded: passwordManagers)

    public let excluded: Set<String>

    public init(excluded: Set<String>) {
        self.excluded = excluded
    }

    public func excludes(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excluded.contains(bundleID)
    }

    /// `place` with everything but the app removed, when the app is excluded. The window title goes
    /// too: a password manager's title is the name of the item being looked at.
    public func applied(to place: ReadingPlace) -> ReadingPlace {
        guard excludes(place.bundleID) else { return place }
        return ReadingPlace(bundleID: place.bundleID, name: place.name)
    }
}
