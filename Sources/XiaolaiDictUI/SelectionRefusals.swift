import Foundation
import MacCapture

/// **What the reader is told when a selection cannot be looked up** — the words for `SelectionReader`'s typed
/// refusals. The reader decides which refusal it is and says nothing; these sentences were written inside it, and
/// moved here verbatim, keys and comments both, when it left the app for `MacCapture` (2026-10-08,
/// plan-macos-modularisation P5). The catalog is the witness that none of them changed.
extension SelectionReader.Refusal {
    /// The lookup panel's detail line for this refusal.
    public var message: String {
        switch self {
        case .nothingSelected(let app):
            String(localized: "Nothing is selected in \(app), or it does not expose its selection to Accessibility.",
                   comment: "Lookup panel; the placeholder is the app's name")
        case .searchLimitReached(let app, let limit):
            String(localized: """
                Nothing is selected in \(app)'s focused element, and its window is too large to search \
                for a page within \(limit) elements.
                """, comment: "Lookup panel; the placeholders are the app's name and a count of elements")
        case .noWord(let app):
            String(localized: "The selection in \(app) has no word in it.",
                   comment: "Lookup panel; the placeholder is the app's name")
        case .tooLong(let app, let characters):
            String(localized: "The selection in \(app) is \(characters) characters — too long to look up.",
                   comment: "Lookup panel; the placeholders are the app's name and a character count")
        case .failed(let error, let app):
            SelectionReader.message(for: error, app: app)
        }
    }
}

extension SelectionReader {
    /// What the reader is told when reading the selection failed, one sentence a failure.
    static func message(for error: CaptureError, app: String) -> String {
        switch error {
        // **Localized where written** (ADR-0025): these reach the panel as its detail line.
        case .notResponding:
            String(localized: "\(app) did not answer Accessibility in time — it may be busy. Try again in a moment.",
                   comment: "Lookup panel; the placeholder is the app's name")
        case .deadlineExceeded:
            String(localized: "Reading the selection from \(app) took longer than \(budget.components.seconds) seconds, so it was stopped.",
                   comment: "Lookup panel; the placeholders are the app's name and a number of seconds")
        case .accessibilityDisabled:
            String(localized: "Accessibility access for XiaolaiDict is off. Allow it in \(PrivacySettings.accessibilityLocation).",
                   comment: "Lookup panel; the placeholder is the System Settings list to grant it in")
        case .appUnavailable:
            String(localized: "\(app) quit, or stopped answering Accessibility requests.",
                   comment: "Lookup panel; the placeholder is the app's name")
        case .accessibilityRefused:
            String(localized: "\(app) refused Accessibility requests — is the screen locked?",
                   comment: "Lookup panel; the placeholder is the app's name")
        case .cancelled:
            String(localized: "A newer lookup replaced this one.", comment: "Lookup panel, when a lookup was superseded")
        }
    }
}
