import AppKit
import XiaolaiDictCore

/// One lookup, as the panel shows it — a container that fills in rather than a payload that is
/// awaited. Everything known the moment the reader pressed the shortcut is here at once; what the
/// dictionaries say arrives later, in the same panel.
public struct LookupPresentation: Equatable {
    public let term: String
    public let lemma: Lemma
    /// The app, and the site, the word was read in.
    public let source: String?
    public let capture: CaptureQuality
    /// The reader's own sentence, where one was captured. The sentence pane explains this, and it
    /// is the only text the remote tier would ever be allowed to see.
    public var sentence: String?
    /// Nil while the dictionaries are still being asked. The panel says so rather than showing an
    /// empty pane that reads like an entry.
    public var outcome: LookupOutcome?
    /// Nil while the selector is still deciding. The entry is readable with all of its senses long
    /// before this arrives — the mark is late, the entry is not.
    public var sense: SenseMark?
    /// Nil on a first lookup, and until the ledger has been read. Prior encounters, never prior
    /// meanings.
    public var memory: MemoryStrip?
    /// The study items the reader has already met, so a sense read before can be marked (C3).
    public var met: Set<StudyItem> = []

    public init(
        term: String, lemma: Lemma, source: String?, capture: CaptureQuality,
        sentence: String? = nil, outcome: LookupOutcome? = nil, sense: SenseMark? = nil,
        memory: MemoryStrip? = nil, met: Set<StudyItem> = []
    ) {
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


    /// What this panel is waiting for, in words, or nil when it is waiting for nothing.
    public var waitingDescription: String? {
        guard case .lookup(let presentation) = self, presentation.outcome == nil else { return nil }
        return "Looking up “\(presentation.term)” in your dictionaries…"
    }

    public enum Kind: Hashable {
        case lookup
        case message

        /// Exhaustive, so a new kind of content cannot quietly get another kind's size.
        public var defaultSize: NSSize {
            switch self {
            case .lookup: NSSize(width: Token.Panel.lookupWidth, height: Token.Panel.lookupHeight)
            case .message: NSSize(width: Token.Panel.messageWidth, height: Token.Panel.messageHeight)
            }
        }

        public var minimumSize: NSSize {
            switch self {
            case .lookup: NSSize(width: Token.Panel.lookupMinWidth, height: Token.Panel.lookupMinHeight)
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

