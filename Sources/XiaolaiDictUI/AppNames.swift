import AppKit

/// The name an app goes by, from its bundle identifier.
///
/// Cached for `AppIcons`' reason — `NSWorkspace` goes to disk for each one — and misses are cached
/// too. **Nil when the app is not installed**, and the caller shows the identifier instead: a name
/// made up from an identifier would look like one the system gave, and `com.lastpass.LastPass`
/// dressed as "LastPass" is a claim that LastPass is on this Mac.
@MainActor
enum AppNames {
    private static var cache: [String: String?] = [:]

    static func name(for bundleID: String) -> String? {
        if let known = cache[bundleID] { return known }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
            // Finder shows the extension when the reader has asked it to, and "1Password.app" in a
            // list of apps is a filename, not a name.
            .map { $0.hasSuffix(".app") ? String($0.dropLast(".app".count)) : $0 }
        cache[bundleID] = found
        return found
    }
}
