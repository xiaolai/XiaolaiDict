import CoreServices
import Foundation

/// The public, documented lookup: plain text only, but safe to call in-process. It is what the
/// panel shows when the dictionary service has crashed (design note §10).
public enum PublicDictionary {
    public static func definition(of term: String) -> String? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = CFRange(location: 0, length: (trimmed as NSString).length)
        // NULL is the public API's documented "every active dictionary" — unlike the private
        // DCSCopyRecordsForSearchString, which segfaults on it since macOS 26. Probed on macOS 27.
        guard let definition = DCSCopyTextDefinition(nil, trimmed as CFString, range)?.takeRetainedValue() else {
            return nil
        }
        let text = definition as String
        return text.isEmpty ? nil : text
    }
}
