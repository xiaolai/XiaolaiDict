import DictionaryModel
import Foundation
import StudyKit
import StudyPresentation
import SwiftUI
import XiaolaiDictBase
import os

/// The phrase a reader was standing inside, ready to be drawn.
///
/// **The card's own reading of `PhraseAnswer`**, not the wire type. The wire carries entries; a card wants
/// the one definition it has room for, and it wants to know whether it is allowed to sound certain.
public struct PhrasePresentation: Equatable, Sendable {
    /// The dictionary's own spelling, slots and all — `take something into account`. What the entry is
    /// filed under, and so what the reader must be shown rather than the words they happened to write.
    public let phrase: String
    /// Where the span sits in the reader's sentence, UTF-16, gap included.
    public let range: NSRange
    public let separation: PhraseSeparation
    /// What the phrase means.
    ///
    /// **From whichever of two places actually has it.** A phrase with an entry of its own — *purple
    /// passage*, *red herring* — is explained by that entry's leading sense. A phrase filed as a sub-entry is
    /// answered by the framework with its *parent's* entry, whose senses are nouns about `account`; its own
    /// definition comes from the phrase inventory's body walk. Either way the reader is shown a true meaning
    /// rather than sent somewhere else to look.
    ///
    /// Nil only where neither has one, which is a phrase from the key index that no dictionary explains.
    public let definition: String?
    /// Which dictionary said `definition` — its key. What decides whether the meaning on the notice may be
    /// saved as the study dictionary's (ADR-0049): another dictionary's text never is.
    public let definitionDictionary: String?

    /// The dictionary this lookup studies from — its key, whether or not it holds the phrase. Nil where the
    /// lookup had none to name.
    public let studyDictionary: String?
    /// That dictionary, **where it files the phrase or holds an entry for it**; nil where it does neither,
    /// and then there is nothing in it to save.
    public let studyHolding: DictionaryIdentity?
    /// Where the study dictionary files the phrase — evidence a saved card records, never its key.
    public let studyFilings: [PhraseFiling]
    /// The study dictionary's own entries for the phrase, by `entryKey` — what lets a save see a meaning of
    /// one of them already saved, so the phrase is not made a second card.
    public let studyOwnEntryKeys: [String]

    /// The sense of the phrase the reader met, once the selector has decided.
    ///
    /// **Nil is the answer "you are reading the word, not the phrase."** The selector is given the word's
    /// senses and the phrase's in one set; where it picks one of the word's, the phrase stays on the card as
    /// something the reader might have missed, without claiming to be what they read.
    public var met: SenseMet?

    /// Whether every dictionary could be read for the phrase. Anything less is said on the card: a
    /// phrase with no meaning shown because its lookup failed is not a phrase nobody explains.
    public let retrieval: PhraseRetrieval

    /// Which meaning of the phrase fits the reader's own sentence.
    public struct SenseMet: Equatable, Sendable {
        public let definition: String?
        /// A sense the selector picked is a guess and reads as one; a sense the reader tapped is a fact.
        public let isHypothesis: Bool
        /// Which dictionary's entry the sense is in — its key. The resolver reads one dictionary per lookup,
        /// but not always the one the lookup studies from, and a saved card's answer must be its own.
        public let dictionary: String?

        public init(definition: String?, isHypothesis: Bool, dictionary: String? = nil) {
            self.definition = definition
            self.isHypothesis = isHypothesis
            self.dictionary = dictionary
        }
    }

    /// **Whether the card is allowed to sound certain about the span.**
    ///
    /// An `inferred` split is this app's guess about English, not the publisher's mark — NOAD files
    /// `turn down` bare — so it is drawn as a guess. A `marked` gap of nine words is still the publisher
    /// saying an object goes there, and is not hedged however wide it ran.
    public var isGuess: Bool {
        if case .inferred = separation { return true }
        return false
    }

    /// A phrase drawn with no study dictionary behind it — previews and the drawing tests. **Nothing in it
    /// can be saved**: `collecting` answers `.noStudyDictionary`.
    public init(phrase: String, range: NSRange, separation: PhraseSeparation, definition: String?,
                retrieval: PhraseRetrieval = .complete) {
        self.init(phrase: phrase, range: range, separation: separation,
                  definition: (definition, nil), retrieval: retrieval,
                  study: (key: nil, holding: nil, filings: [], ownEntryKeys: []))
    }

    private init(phrase: String, range: NSRange, separation: PhraseSeparation,
                 definition: (text: String?, dictionary: String?), retrieval: PhraseRetrieval,
                 study: (key: String?, holding: DictionaryIdentity?, filings: [PhraseFiling], ownEntryKeys: [String])) {
        self.phrase = phrase
        self.range = range
        self.separation = separation
        self.definition = definition.text
        definitionDictionary = definition.dictionary
        self.retrieval = retrieval
        studyDictionary = study.key
        studyHolding = study.holding
        studyFilings = study.filings
        studyOwnEntryKeys = study.ownEntryKeys
    }

    /// The card's reading of one lookup's phrase answer, or nil where there is nothing to draw.
    ///
    /// **`.notReady` draws nothing, and that is the one case worth stating.** A reader whose service is
    /// still reading its inventory is not told "no phrase here" — they are told nothing at all, which is
    /// true. Claiming the absence would be the failure rendering as confidently as a success, and the
    /// window is a dozen seconds once per service launch.
    /// **The leading phrase is what the card draws.** The wire carries every phrase covering the word so
    /// that nothing on the lookup path deletes a candidate — the selector sees them all — but a card has room
    /// for one, and the order it arrives in is the order to prefer.
    ///
    /// `studyDictionary` is the key of the dictionary this lookup studies from (D7), which only the runner
    /// knows: it decides whose meaning leads the notice and what *Save This Phrase* would save.
    public init?(_ answer: PhraseAnswer, sentence: String?, studyDictionary: String? = nil) {
        guard case .found(let hits) = answer, let hit = hits.first, let sentence else { return nil }
        let range = NSRange(location: hit.location, length: hit.length)
        // Validated against the sentence the card actually holds. The hit was measured against the
        // sentence that was *sent*, and a card built from a different one would bracket whatever sits at
        // that offset — the same defect `sentenceRange` already documents for the word.
        guard range.location >= 0, range.length > 0,
              NSMaxRange(range) <= (sentence as NSString).length else { return nil }
        let held = studyDictionary.map { key in
            (entries: hit.meaning.ownEntries.filter { $0.dictionary.key == key },
             filings: hit.meaning.filings.filter { $0.dictionary.key == key })
        }
        // **The study dictionary's meaning leads, where it has one** — as its entry leads the card (D7).
        // The first own entry in any dictionary won before, so the notice could show one dictionary's
        // meaning while a saved card revealed another's.
        let studys = held.map { Self.leadingMeaning(of: PhraseMeaning(ownEntries: $0.entries, filings: $0.filings)) }
        let leading = studys.flatMap { $0.text == nil ? nil : $0 } ?? Self.leadingMeaning(of: hit.meaning)
        self.init(phrase: hit.phrase, range: range, separation: hit.separation, definition: leading,
                  retrieval: hit.retrieval,
                  study: (key: studyDictionary,
                          holding: held.flatMap { ($0.entries.first?.dictionary ?? $0.filings.first?.dictionary) },
                          filings: held?.filings ?? [],
                          ownEntryKeys: held?.entries.compactMap(\.entryKey) ?? []))
    }

    /// The meaning the notice leads with, and whose it is.
    ///
    /// **An own entry first, then a filing.** A phrase with an entry of its own is explained by that
    /// entry's leading sense; one filed inside another word's is explained by the body walk, because the
    /// entry the framework answered with is the parent's and its senses are not the phrase's. A phrase can
    /// now be both at once — different dictionaries disagree about which it is — and the card prefers the
    /// entry, whose senses the selector can also reach.
    static func leadingMeaning(of meaning: PhraseMeaning) -> (text: String?, dictionary: String?) {
        if let entry = meaning.ownEntries.first(where: { definition(in: [$0]) != nil }) {
            return (definition(in: [entry]), entry.dictionary.key)
        }
        if let filing = meaning.filings.first(where: { !($0.definition ?? "").isEmpty }) {
            return (filing.definition, filing.dictionary.key)
        }
        return (nil, nil)
    }

    /// **What *Save This Phrase* would save, or why it cannot** — one answer, read by the control and by
    /// the tests, because two conditions that must agree are how a switch comes to refuse a click.
    ///
    /// The spelling is the hit's, verbatim: the inventory's own. The answer is **the meaning the notice
    /// shows** — the proposed sense where the selector chose one, the leading meaning otherwise — **where it
    /// is the study dictionary's**, and nil where it is another's: saved under this dictionary's name it
    /// would be signed by a dictionary that never said it, and the card waits for the reader's words.
    public var collecting: PhraseCollecting {
        guard studyDictionary != nil else { return .refused(.noStudyDictionary) }
        guard let study = studyHolding else { return .refused(.notInStudyDictionary) }
        let shown: (text: String?, dictionary: String?, isHypothesis: Bool) =
            if let met, met.definition != nil {
                (met.definition, met.dictionary, met.isHypothesis)
            } else {
                (definition, definitionDictionary, false)
            }
        let isTheStudyDictionarys = shown.dictionary == study.key
        let answer = isTheStudyDictionarys ? shown.text.flatMap { $0.isEmpty ? nil : $0 } : nil
        return .offered(PhraseCollection(
            dictionary: study, spelling: phrase, answer: answer, filings: studyFilings,
            ownEntryKeys: studyOwnEntryKeys, isProposal: isGuess || (answer != nil && shown.isHypothesis)))
    }

    /// The first definition any of the phrase's entries marks, in the order the dictionaries answered.
    ///
    /// Entry order is the reader's own dictionary order, so this is the dictionary they put first — not a
    /// judgement this type is in a position to make.
    static func definition(in entries: [DictionaryEntry]) -> String? {
        for entry in entries {
            for block in entry.blocks {
                for sense in block.senses {
                    if let definition = sense.definition, !definition.isEmpty { return definition }
                }
            }
        }
        return nil
    }
}

/// Whether the phrase on the card can be saved as a study card, and what would be saved.
public enum PhraseCollecting: Equatable, Sendable {
    case offered(PhraseCollection)
    case refused(PhraseCollectRefusal)
}

/// **Why the phrase cannot be saved**, said on the disabled control — a control that refuses a click is a
/// broken switch, so the reason is legible before the click.
public enum PhraseCollectRefusal: Equatable, Sendable, CaseIterable {
    /// No dictionary answered this lookup that it could be studied from.
    case noStudyDictionary
    /// The study dictionary neither files the phrase nor holds an entry for it; another dictionary does.
    case notInStudyDictionary
    /// The reader discarded the reading the phrase was found in.
    case readingDiscarded
    /// The reading was deleted while its card was open.
    case readingDeleted

    public var reason: LocalizedStringResource {
        switch self {
        case .noStudyDictionary: "No study dictionary answered this lookup, so the phrase cannot be saved"
        case .notInStudyDictionary: "Your study dictionary does not have this phrase, so it cannot be saved"
        case .readingDiscarded: "This reading was discarded. Restore it to save the phrase"
        case .readingDeleted: "This reading was deleted, so the phrase cannot be saved"
        }
    }
}

/// **The phrase control's state, as a decision rather than view code** — a `@ViewBuilder` condition cannot
/// be asserted, and "save, saving, saved, or disabled and why" is a rule a test has to be able to read.
public enum PhraseCollectControl: Equatable, Sendable {
    case offered(PhraseCollection)
    /// The last save of this phrase failed; the same save is offered again.
    case retry(PhraseCollection)
    case saving
    case saved
    case alreadySaved
    case refused(PhraseCollectRefusal)

    /// A save that happened stands whatever became of the reading since: the card is the reader's. Before
    /// one has, a reading put away refuses it, then the phrase's own answer decides.
    public init(_ phrase: PhrasePresentation, status: PhraseCollectStatus?, keep: LookupKeepStatus?) {
        switch status {
        case .collected?: self = .saved; return
        case .alreadyCollected?: self = .alreadySaved; return
        case .collecting?: self = .saving; return
        case .failed?, nil: break
        }
        if keep?.isDiscarded == true { self = .refused(.readingDiscarded); return }
        if keep == .deleted { self = .refused(.readingDeleted); return }
        switch phrase.collecting {
        case .offered(let collection): self = status == .failed ? .retry(collection) : .offered(collection)
        case .refused(let refusal): self = .refused(refusal)
        }
    }

    /// What a press would save, where a press would save anything.
    var collection: PhraseCollection? {
        switch self {
        case .offered(let collection), .retry(let collection): collection
        case .saving, .saved, .alreadySaved, .refused: nil
        }
    }
}

/// **Saving the phrase is the app's job**, as writing any card is; the card is handed a way to ask. It
/// answers whether the ask was taken.
///
/// **The default is loud and answers false**: a hook nobody set is a button that takes a click and does
/// nothing, so it logs a fault — the rule `WindowActions` holds for an unwired window action.
private struct CollectPhraseKey: EnvironmentKey {
    static let defaultValue: @MainActor (PhraseCollection) -> Bool = { _ in
        Logger(subsystem: XiaolaiDictIdentity.app, category: "lookup-panel")
            .fault("phrase: Save This Phrase was pressed with no app to save it")
        return false
    }
}

private struct PhraseCollectStatusesKey: EnvironmentKey {
    static let defaultValue: [String: PhraseCollectStatus] = [:]
}

extension EnvironmentValues {
    /// **The reader asked to keep the phrase on the card as a study card** (ADR-0049) — the only way a
    /// phrase card is made. Answers false where the ask was not taken.
    public var collectPhrase: @MainActor (PhraseCollection) -> Bool {
        get { self[CollectPhraseKey.self] }
        set { self[CollectPhraseKey.self] = newValue }
    }

    /// What became of each save asked for on this card, by spelling.
    public var phraseCollectStatuses: [String: PhraseCollectStatus] {
        get { self[PhraseCollectStatusesKey.self] }
        set { self[PhraseCollectStatusesKey.self] = newValue }
    }
}

/// The phrase, under the sentence it was found in.
///
/// No label naming it a phrase: the span is already underlined in the sentence directly above, and a
/// caption repeating that would be the same fact twice. What the reader cannot see from the sentence is
/// what the phrase *means*, which is what this adds — and, beside it, the way to keep it as a card.
struct PhraseNoticeView: View {
    @Environment(\.scale) private var scale
    @Environment(\.collectPhrase) private var collectPhrase
    @Environment(\.phraseCollectStatuses) private var statuses
    @Environment(\.lookupKeepStatus) private var keepStatus
    let phrase: PhrasePresentation
    /// The word's own colour, so the phrase reads as part of the same lookup rather than a second one.
    let accent: Color
    /// The app did not take the last ask — no ledger, or the hook unset. Shown as a failed save, so the
    /// press is never answered by nothing.
    @State private var notTaken = false

    private var control: PhraseCollectControl {
        PhraseCollectControl(phrase, status: notTaken ? .failed : statuses[phrase.phrase], keep: keepStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                Text(verbatim: phrase.phrase)
                    .font(.system(size: scale.text.body, weight: .medium))
                    .foregroundStyle(accent)
                Spacer(minLength: scale.space.inline)
                collectControl
            }
            // **The sense in context where one was chosen, the leading one otherwise.** Showing the
            // first definition when the selector has decided a different one fits would put the wrong
            // meaning under the right phrase — worse than showing none, because the reader cannot see it
            // is wrong.
            if let definition = phrase.met?.definition ?? phrase.definition {
                Text(verbatim: definition)
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(Token.Limit.wrapLines)
                    // Two lines, and a definition can run past them: what was cut is a hover away
                    // rather than gone.
                    .help(Text(verbatim: definition))
            }
            // **A mark and ordinary text, like the card's own "A guess, not confirmed"** — these
            // two were orange text with nothing but the hue to say they were caveats, at 2.2:1 on
            // the light card.
            if let met = phrase.met, met.isHypothesis {
                StatusLabel(.unconfirmed, "The meaning here is a guess, not confirmed")
            }
            if phrase.retrieval != .complete {
                StatusLabel(.caution, "Not every dictionary could be read for this phrase")
            }
            if phrase.isGuess {
                // Said in the same voice the card uses for a proposed sense, because it is the same kind
                // of claim: the app worked something out and the reader is entitled to know that before
                // they believe it.
                StatusLabel(.unconfirmed, "A guess: these words may not belong together")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // **The same action, by name, for a reader who right-clicks** — the history card's pattern. A menu
        // tracks without activating the app, so the panel stays a panel (ADR-0018).
        // Offered there only where a press would save something, as the history card's menu offers Save:
        // a menu row cannot carry the reason a disabled one would need.
        .contextMenu {
            if control.collection != nil {
                collectButton(for: control).environment(\.iconButtonShowsTitle, true)
            }
        }
        // A new phrase on the card is a new question: what the app refused for the last one is not this
        // one's answer.
        .onChange(of: phrase.phrase) { notTaken = false }
    }

    /// **Save This Phrase**, beside the phrase it saves: a bookmark like *Save This Meaning*, because it is
    /// the same act with the same destination, and the name says which. Saving, it is a spinner and not a
    /// button; saved, a state and not a button; refused, disabled with its reason in the tooltip.
    @ViewBuilder
    private var collectControl: some View {
        switch control {
        case .saving:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: Token.Target.minimum, minHeight: Token.Target.minimum)
                .accessibilityLabel(Text("Saving this phrase…"))
                .help(Text("Saving this phrase…"))
        case .saved, .alreadySaved:
            savedMark(already: control == .alreadySaved)
        case .offered, .retry, .refused:
            collectButton(for: control)
        }
    }

    /// The button, enabled exactly where a press would save something — shared by the row and the menu, so
    /// the two cannot disagree about what is offered.
    private func collectButton(for control: PhraseCollectControl) -> some View {
        let offered = control.collection
        return IconButton(.savePhrase, help: help(for: control), isEnabled: offered != nil) {
            guard let offered else { return }
            notTaken = !collectPhrase(offered)
        }
        // Legible when off, so its reason is reachable: tertiary is this card's disabled look and nothing else.
        .foregroundStyle(offered == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
    }

    /// The tooltip where it says more than the name: why it is off, or that the last save failed.
    private func help(for control: PhraseCollectControl) -> Text? {
        switch control {
        case .refused(let refusal): Text(refusal.reason)
        case .retry: Text("This phrase could not be saved. Save it again to retry")
        case .offered, .saving, .saved, .alreadySaved: nil
        }
    }

    /// A state, not a button: the phrase is in Saved, so there is nothing to press.
    private func savedMark(already: Bool) -> some View {
        let said = already ? Text("This phrase was already saved") : Text(ActionSymbol.savedState.title)
        return ActionSymbol.savedState.image
            .font(.system(size: scale.text.body))
            .foregroundStyle(.secondary)
            .frame(minWidth: Token.Target.minimum, minHeight: Token.Target.minimum)
            .help(said)
            .accessibilityLabel(said)
    }
}
