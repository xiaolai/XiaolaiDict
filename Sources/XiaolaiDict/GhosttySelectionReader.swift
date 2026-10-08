import AppKit

/// Ghostty does not expose its selected terminal text through AXSelectedText. Ask its documented
/// scripting interface to copy the focused terminal's selection instead of synthesizing a key press.
@MainActor
enum GhosttySelectionReader {
    static let bundleID = "com.mitchellh.ghostty"
    static let maximumLength = 2_000

    enum Result: Equatable {
        case selected(String)
        case nothing(String)
    }

    static func read() -> Result {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let script = NSAppleScript(source: """
            tell application id "com.mitchellh.ghostty"
                perform action "copy_to_clipboard" on focused terminal of selected tab of front window
            end tell
            """)
        var error: NSDictionary?
        guard let reply = script?.executeAndReturnError(&error), error == nil, reply.booleanValue else {
            return .nothing(String(localized: "Ghostty could not copy the selected text. Select text in its focused terminal and allow XiaolaiDict to control Ghostty when macOS asks.",
                                   comment: "Sentence translation panel when Ghostty's AppleScript copy failed"))
        }
        return result(after: before, current: pasteboard.changeCount, text: pasteboard.string(forType: .string))
    }

    /// A successful action can leave the clipboard untouched when nothing is selected. In that
    /// case its previous contents must never be presented as a new selection.
    static func result(after before: Int, current: Int, text: String?) -> Result {
        guard current != before, let text else {
            return .nothing(String(localized: "Select text in Ghostty before translating.",
                                   comment: "Sentence translation panel when Ghostty copied no selection"))
        }
        let selected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else {
            return .nothing(String(localized: "Select text in Ghostty before translating.",
                                   comment: "Sentence translation panel when Ghostty copied no selection"))
        }
        guard selected.count <= maximumLength else {
            return .nothing(String(localized: "The selected text is too long to translate (limit: 2,000 characters).",
                                   comment: "Sentence translation panel when selected text exceeds the limit"))
        }
        return .selected(selected)
    }
}
