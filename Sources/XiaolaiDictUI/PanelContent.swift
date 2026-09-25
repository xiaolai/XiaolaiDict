import AppKit
import XiaolaiDictCore

/// One lookup, as the panel shows it — a container that fills in rather than a payload that is
/// awaited. Everything known the moment the reader pressed the shortcut is here at once; what the
/// dictionaries say arrives later, in the same panel.
public struct LookupPresentation: Equatable {
    /// Which request this is. The panel's content view is identified by it, so what a reader revealed
    /// for one lookup — a translation, an explanation — never appears under the next word, and an
    /// answer still arriving for an old lookup lands in a view that is already gone.
    public let request: Int
    public let term: String
    public let lemma: Lemma
    /// The app, and the site, the word was read in.
    public let source: String?
    public let capture: CaptureQuality
    /// The reader's own sentence, where one was captured. The sentence pane explains this, and it
    /// is the only text the remote tier would ever be allowed to see.
    public var sentence: String?
    /// Where the word sits in `sentence`, UTF-16 — the range the capture actually recorded.
    ///
    /// **The card searched for the word instead**, taking the first case-insensitive substring
    /// match: looking up *he* in "The man said he was fine" marked the *he* inside "The", and a
    /// word repeated in its own sentence marked the wrong occurrence. `Selection.rangeInSentence`
    /// was captured and thrown away at this boundary; the history drawer never had that bug
    /// because the ledger stores the range.
    public var sentenceRange: NSRange?
    /// Nil while the dictionaries are still being asked. The panel says so rather than showing an
    /// empty pane that reads like an entry.
    public var outcome: LookupOutcome?
    /// Nil while the selector is still deciding. The entry is readable with all of its senses long
    /// before this arrives — the mark is late, the entry is not.
    public var sense: SenseMark?
    /// Which entry `sense` is about — `PanelSelection.identity(of:)`'s spelling. The resolver only
    /// ever reads the primary dictionary's entries, so a mark shown on any other entry is borrowed;
    /// the card compares this before drawing one.
    public var senseOwner: String?
    /// The primary dictionary's own entry, in `PanelSelection.identity(of:)`'s spelling — what the
    /// card opens on. Nil where the primary answered with nothing, which is when service order is
    /// the only order there is.
    public var primaryEntry: String?
    /// Nil on a first lookup, and until the ledger has been read. Prior encounters, never prior
    /// meanings.
    public var memory: MemoryStrip?
    /// The study items the reader has already met, so a sense read before can be marked (C3).
    public var met: Set<StudyItem> = []

    /// **`request` has no default**, because a default is what makes two lookups share an identity.
    /// The panel resets a card's own state — a revealed gloss, a translation, an explanation — when
    /// this number changes, so two presentations built without one are the same lookup as far as
    /// SwiftUI is concerned, and the previous reader's answers stay on screen under the next word.
    public init(
        request: Int, term: String, lemma: Lemma, source: String?, capture: CaptureQuality,
        sentence: String? = nil, outcome: LookupOutcome? = nil, sense: SenseMark? = nil,
        memory: MemoryStrip? = nil, met: Set<StudyItem> = []
    ) {
        self.request = request
        self.term = term
        self.lemma = lemma
        self.source = source
        self.capture = capture
        self.sentence = sentence
        self.outcome = outcome
        self.sense = sense
        self.memory = memory
        self.met = met
    }
}

/// What the panel shows.
public enum PanelContent {
    case lookup(LookupPresentation)
    /// Something the reader needs to know instead of an entry: no selection, no permission.
    case message(title: String, detail: String)


    /// Which lookup this content *is*, where it is one. **The panel's own counter is not this**:
    /// it moves the moment a new lookup starts, which is before the reader's selection has even
    /// been read — so a tap on the card still on screen would be attributed to a lookup that has
    /// not happened yet, and the ledger would hang the sense off the wrong word.
    public var request: Int? {
        guard case .lookup(let presentation) = self else { return nil }
        return presentation.request
    }

    /// What this panel is waiting for, in words, or nil when it is waiting for nothing.
    public var waitingDescription: String? {
        guard case .lookup(let presentation) = self, presentation.outcome == nil else { return nil }
        return String(localized: "Looking up “\(presentation.term)” in your dictionaries…",
                      comment: "Shown while the dictionaries are being asked; the placeholder is the word")
    }

    /// Accessibility is off, so there is no selection to read.
    ///
    /// The panel's own sentences live here rather than where the panel is shown, for the reason
    /// `waitingDescription` already did: this is the view layer, which is where reader-facing text
    /// belongs and where the string scan looks. The app module had them, and the previews had a
    /// second copy of the same four.
    public static var accessibilityIsOff: PanelContent {
        .message(
            title: String(localized: "XiaolaiDict needs Accessibility access",
                          comment: "Lookup panel, when Accessibility has not been granted"),
            detail: String(localized: "It reads your selection through Accessibility. Allow XiaolaiDict in \(PrivacySettings.accessibilityLocation), then press the shortcut again.",
                           comment: "The placeholder is the System Settings list to grant it in"))
    }

    /// There is no frontmost app to read a selection out of.
    public static var frontmostAppUnknown: PanelContent {
        nothingToLookUp(String(localized: "The frontmost app could not be identified, so its selection cannot be read.",
                               comment: "Lookup panel, when no app is frontmost"))
    }

    /// Nothing could be read, under the reason the reader was given. That reason is already in the
    /// reader's own words by the time it arrives, so it is not looked up a second time here.
    public static func nothingToLookUp(_ reason: String) -> PanelContent {
        .message(
            title: String(localized: "Nothing to look up",
                          comment: "Lookup panel, when there was no word to look up"),
            detail: reason)
    }

    public enum Kind: Hashable {
        case lookup
        case message

        /// A starting size, not a fixed one — the lookup window hugs its content, so this is what
        /// it opens at before the card has laid itself out.
        ///
        /// Exhaustive, so a new kind of content cannot quietly get another kind's size.
        public var defaultSize: NSSize {
            switch self {
            case .lookup: NSSize(width: Token.Panel.cardOpeningWidth, height: Token.Panel.cardOpeningHeight)
            case .message: NSSize(width: Token.Panel.messageWidth, height: Token.Panel.messageHeight)
            }
        }

        public var minimumSize: NSSize {
            switch self {
            case .lookup: NSSize(width: Scale.standard.space.cardMinWidth, height: Token.Panel.messageMinHeight)
            case .message: NSSize(width: Token.Panel.messageMinWidth, height: Token.Panel.messageMinHeight)
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .lookup: .lookup
        case .message: .message
        }
    }
}

