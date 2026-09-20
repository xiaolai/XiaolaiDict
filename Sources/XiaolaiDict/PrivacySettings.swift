import Foundation

/// Where the reader grants XiaolaiDict the Accessibility permission. macOS 27 renamed the list: what was
/// Privacy & Security → Accessibility is Privacy & Security → Device Control and Data Access (the
/// pane's own string table, macOS 27.0).
enum PrivacySettings {
    /// The path to the list on the running macOS.
    static var accessibilityLocation: String {
        accessibilityLocation(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static func accessibilityLocation(majorVersion: Int) -> String {
        let list = majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
        return "System Settings → Privacy & Security → \(list)"
    }

    /// Where the reader grants Screen Recording, which the hover recogniser needs. macOS 27 renamed
    /// this list too: Screen Recording became Screen & System Audio Recording.
    static var screenRecordingLocation: String {
        screenRecordingLocation(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static func screenRecordingLocation(majorVersion: Int) -> String {
        let list = majorVersion >= 27 ? "Screen & System Audio Recording" : "Screen Recording"
        return "System Settings → Privacy & Security → \(list)"
    }
}
