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
}
