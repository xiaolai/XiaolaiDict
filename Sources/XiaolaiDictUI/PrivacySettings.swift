import Foundation

/// Where the reader grants XiaolaiDict the Accessibility permission. macOS 27 renamed the list: what was
/// Privacy & Security → Accessibility is Privacy & Security → Device Control and Data Access (the
/// pane's own string table, macOS 27.0).
///
/// Every name here is macOS's, not this app's — so a translation is not a rendering of the English
/// but whatever the running system prints on that pane. A reader sent to a list under a name the
/// system does not use is a reader who cannot find it, which is the whole point of naming it.
public enum PrivacySettings {
    /// The path to the list on the running macOS.
    public static var accessibilityLocation: String {
        accessibilityLocation(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    public static func accessibilityLocation(majorVersion: Int) -> String {
        let list = majorVersion >= 27
            ? String(localized: "Device Control and Data Access",
                     comment: "macOS 27's name for the Accessibility list — use the system's own wording")
            : String(localized: "Accessibility",
                     comment: "The Accessibility permission, as macOS names it in System Settings")
        return path(to: list)
    }

    /// Where the reader grants Screen Recording, which the hover recogniser needs. macOS 27 renamed
    /// this list too: Screen Recording became Screen & System Audio Recording.
    public static var screenRecordingLocation: String {
        screenRecordingLocation(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    public static func screenRecordingLocation(majorVersion: Int) -> String {
        let list = majorVersion >= 27
            ? String(localized: "Screen & System Audio Recording",
                     comment: "macOS 27's name for the Screen Recording list — use the system's own wording")
            : String(localized: "Screen Recording",
                     comment: "The Screen Recording permission, as macOS names it in System Settings")
        return path(to: list)
    }

    /// One sentence for both, so the two cannot drift apart in a translation the way they could
    /// while each wrote out its own copy of the path.
    private static func path(to list: String) -> String {
        String(localized: "System Settings → Privacy & Security → \(list)",
               comment: "Where a permission is granted; the placeholder is the list's own name")
    }
}
