import SwiftUI

/// **The one place a symbol is given to an action, and the one place that action is named.**
///
/// Nearly every control in the Library, the drawer and the lookup card is an icon alone, so the
/// symbol *is* the label — and measured 2026-10-01 the symbols did not hold one meaning each.
/// `archivebox` was Discard, the Discarded pane, Archive and the Archived filter, two of them 370 pt
/// apart in one sidebar. Saving a meaning was `rectangle.stack.badge.plus` on the card,
/// `tray.and.arrow.down` in the Library and a worded button in the drawer. `arrow.uturn.backward`
/// was Undo and also "offer it again", which undoes nothing. `xmark` — the platform's Close — was
/// the grade *Forgot*, beside a `checkmark`, reading as cancel and OK.
///
/// So a surface never writes a symbol name or an action's title. It writes `.undo`, and the two
/// travel together. `ActionSymbolTests` resolves every name against the system, and fails if two
/// cases share a symbol outside the pairs that are one thing seen twice — a pane and the action
/// that fills it.
///
/// Titles are in title-style capitalisation because they are the names of buttons, tabs and
/// sidebar rows, and they use one word per concept: a meaning is *saved*, a reading is
/// *discarded* and can be *restored*, and only *Delete Permanently* cannot be taken back.
///
/// **Public**, so the menu-bar item in the app target draws from the same table.
public enum ActionSymbol: String, CaseIterable, Sendable {
    // The Library's panes.
    case historyPane, savedPane, reviewPane, discardedPane
    // A meaning in study.
    case saveMeaning, savedState, removeFromSaved, confirmMeaning, chooseMeaning
    case showMeaning, hideMeaning, saveAnswer, writeAnswer
    // A reading in history.
    case discardReading, restoreReading, deletePermanently
    // The Saved pane's filters and what acts on a selection there.
    case allFilter, dueFilter, needsAttentionFilter, strugglingFilter, pausedFilter, archivedFilter
    case suggestedFilter, archive, unarchive, pause, resume, findUnconfirmed
    case saveSuggestion, alreadyKnow, offerAgain
    case clearSearch, showEveryTag, showEverything, showMore, export
    // Review.
    case forgot, remembered, skip, notToday, anotherBatch, practise, done
    // Anywhere.
    case undo, retry
    // The Library window's own chrome: how the collection is arranged, and the detail column.
    case listLayout, gridLayout, inspector
    // The lookup card and a history card.
    case sayAloud, openInDictionary, copy, pinNote, unpinNote, translate, explain
    // A history card in the Reading History panel, and a day's pile of them there.
    case showInLibrary, showAll, showLess
    // Not actions: the mark in front of a caveat, and of a failure. Never a button's symbol.
    case warning, failure

    /// The SF Symbol. Every name is checked against this macOS by `ActionSymbolTests`.
    public var symbol: String {
        switch self {
        case .historyPane: "clock"
        case .savedPane, .saveMeaning: "bookmark"
        case .savedState: "bookmark.fill"
        case .reviewPane: "rectangle.on.rectangle"
        // `xmark.bin`, not `archivebox`: a discarded reading is put out, and can be brought
        // back. `archivebox` is Apple's Archive and is kept for that alone.
        case .discardedPane, .discardReading: "xmark.bin"
        case .restoreReading: "tray.and.arrow.up"
        case .deletePermanently: "trash"
        case .archive, .archivedFilter: "archivebox"
        case .unarchive: "arrow.up.bin"
        case .allFilter, .showEverything: "tray.full"
        case .dueFilter: "calendar.badge.clock"
        // A question, not a warning: these are meanings waiting for the reader's answer, and a
        // triangle in a sidebar reads as something having gone wrong.
        case .needsAttentionFilter, .findUnconfirmed: "questionmark.circle"
        case .strugglingFilter: "arrow.trianglehead.counterclockwise"
        case .pausedFilter: "pause.circle"
        case .suggestedFilter: "sparkles"
        case .undo: "arrow.uturn.backward"
        // Not Undo's arrow: this brings back a suggestion set aside days ago, and reverses no
        // action the reader has just taken.
        case .offerAgain: "arrow.counterclockwise"
        case .retry: "arrow.clockwise"
        case .listLayout: "list.bullet"
        case .gridLayout: "square.grid.2x2"
        // The trailing column, which is where an inspector is; `sidebar.leading` is the system's
        // own sidebar toggle and sits at the other end of the same toolbar.
        case .inspector: "sidebar.trailing"
        case .showMeaning: "eye"
        case .hideMeaning: "eye.slash"
        case .confirmMeaning: "checkmark.seal"
        case .chooseMeaning: "text.badge.checkmark"
        // Thumbs, because `xmark` and `checkmark` side by side are Cancel and OK.
        case .forgot: "hand.thumbsdown"
        case .remembered: "hand.thumbsup"
        case .skip: "forward.end"
        case .notToday: "moon.zzz"
        case .anotherBatch: "rectangle.stack.badge.plus"
        case .practise: "repeat"
        // One checkmark for both: each ends something the reader was in the middle of, and they
        // are never on screen together — one is in Review, the other in the inspector's editor.
        case .done, .saveAnswer: "checkmark"
        case .alreadyKnow: "checkmark.circle"
        case .saveSuggestion: "plus.circle"
        case .pause: "pause"
        case .resume: "play"
        case .removeFromSaved: "minus.circle"
        case .sayAloud: "speaker.wave.2"
        // An arrow leaving for an app's window: the reading is opened in the Library, which is
        // another window, and the panel it was clicked in goes away.
        case .showInLibrary: "arrow.up.forward.app"
        // A disclosure, drawn beside its words: which way a day's pile will go.
        case .showAll: "chevron.down"
        case .showLess: "chevron.up"
        case .openInDictionary: "character.book.closed"
        // Apple's name for Copy since the symbols were redrawn; `doc.on.doc` is its old alias.
        case .copy: "document.on.document"
        case .pinNote: "pin"
        case .unpinNote: "pin.slash"
        case .translate: "translate"
        case .explain: "text.bubble"
        case .export: "square.and.arrow.up"
        case .writeAnswer: "square.and.pencil"
        case .clearSearch: "xmark.circle"
        case .showEveryTag: "tag.slash"
        case .showMore: "arrow.down.circle"
        case .warning: "exclamationmark.triangle"
        case .failure: "exclamationmark.octagon"
        }
    }

    /// The action's name: the tooltip, the accessibility label, the menu row, the sidebar row.
    ///
    /// A `LocalizedStringResource` rather than a `LocalizedStringKey` so one declaration serves
    /// SwiftUI — `Text(title)`, `Label(title, systemImage:)` — and AppKit, which needs a `String`
    /// for an `NSMenuItem` and gets one from `String(localized: title)`.
    ///
    /// A counted title is composed where the count is: `"Discard \(n) Readings"` is written at the
    /// call site, with `symbol` taken from here.
    public var title: LocalizedStringResource {
        switch self {
        case .historyPane: "History"
        case .savedPane, .savedState: "Saved"
        case .reviewPane: "Review"
        case .discardedPane: "Discarded"
        case .saveMeaning: "Save This Meaning"
        case .removeFromSaved: "Remove from Saved"
        case .confirmMeaning: "Confirm This Meaning"
        case .chooseMeaning: "Choose a Meaning"
        case .showMeaning: "Show the Meaning"
        case .hideMeaning: "Hide the Meaning"
        case .saveAnswer: "Save the Answer"
        case .writeAnswer: "Write an Answer"
        case .discardReading: "Discard"
        case .restoreReading: "Restore"
        case .deletePermanently: "Delete Permanently"
        case .allFilter: "All"
        case .dueFilter: "Due"
        case .needsAttentionFilter: "Needs Attention"
        case .strugglingFilter: "Struggling"
        case .pausedFilter: "Paused"
        case .archivedFilter: "Archived"
        case .suggestedFilter: "Suggested"
        case .archive: "Archive"
        case .unarchive: "Unarchive"
        case .pause: "Pause"
        case .resume: "Resume"
        case .findUnconfirmed: "Find Meanings to Confirm"
        case .saveSuggestion: "Save"
        case .alreadyKnow: "Already Know"
        case .offerAgain: "Offer Again"
        case .clearSearch: "Clear Search"
        case .showEveryTag: "Show Every Tag"
        case .showEverything: "Show Everything"
        case .showMore: "Show More"
        case .export: "Export…"
        case .forgot: "Forgot"
        case .remembered: "Remembered"
        case .skip: "Skip"
        case .notToday: "Not Today"
        case .anotherBatch: "Review Another Batch"
        case .practise: "Practise"
        case .done: "Done"
        case .undo: "Undo"
        case .retry: "Retry"
        case .listLayout: "List"
        case .gridLayout: "Grid"
        case .inspector: "Inspector"
        case .sayAloud: "Say It Aloud"
        case .showInLibrary: "Show in Library"
        case .showAll: "Show All"
        case .showLess: "Show Less"
        case .openInDictionary: "Open in Dictionary"
        case .copy: "Copy"
        case .pinNote: "Pin as a Note"
        case .unpinNote: "Unpin"
        case .translate: "Translate"
        case .explain: "Explain"
        case .warning: "Warning"
        case .failure: "Error"
        }
    }

    /// Whether the action takes something away that the reader would have to redo or cannot get
    /// back. Discarding is not one: a discarded reading is one click from restored.
    public var role: ButtonRole? {
        switch self {
        case .deletePermanently, .removeFromSaved: .destructive
        default: nil
        }
    }

    /// The symbol as an image, for a place that draws it without a title — a state mark, an
    /// empty state. Give it an accessibility label where it carries meaning on its own.
    public var image: Image { Image(systemName: symbol) }

    /// Title and symbol together: a sidebar row, a menu item, a tab.
    public var label: Label<Text, Image> { Label(title, systemImage: symbol) }
}
