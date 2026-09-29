import DictionaryModel
import Foundation
import SwiftUI

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

    /// The sense of the phrase the reader met, once the selector has decided.
    ///
    /// **Nil is the answer "you are reading the word, not the phrase."** The selector is given the word's
    /// senses and the phrase's in one set; where it picks one of the word's, the phrase stays on the card as
    /// something the reader might have missed, without claiming to be what they read.
    public var met: SenseMet?

    /// Which meaning of the phrase fits the reader's own sentence.
    public struct SenseMet: Equatable, Sendable {
        public let definition: String?
        /// A sense the selector picked is a guess and reads as one; a sense the reader tapped is a fact.
        public let isHypothesis: Bool

        public init(definition: String?, isHypothesis: Bool) {
            self.definition = definition
            self.isHypothesis = isHypothesis
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

    public init(phrase: String, range: NSRange, separation: PhraseSeparation, definition: String?) {
        self.phrase = phrase
        self.range = range
        self.separation = separation
        self.definition = definition
    }

    /// The card's reading of one lookup's phrase answer, or nil where there is nothing to draw.
    ///
    /// **`.notReady` draws nothing, and that is the one case worth stating.** A reader whose service is
    /// still reading its inventory is not told "no phrase here" — they are told nothing at all, which is
    /// true. Claiming the absence would be the failure rendering as confidently as a success, and the
    /// window is a dozen seconds once per service launch.
    public init?(_ answer: PhraseAnswer, sentence: String?) {
        guard case .found(let hit) = answer, let sentence else { return nil }
        let range = NSRange(location: hit.location, length: hit.length)
        // Validated against the sentence the card actually holds. The hit was measured against the
        // sentence that was *sent*, and a card built from a different one would bracket whatever sits at
        // that offset — the same defect `sentenceRange` already documents for the word.
        guard range.location >= 0, range.length > 0,
              NSMaxRange(range) <= (sentence as NSString).length else { return nil }
        switch hit.meaning {
        case .ownEntry(let entries):
            self.init(phrase: hit.phrase, range: range, separation: hit.separation,
                      definition: Self.definition(in: entries))
        case .subEntry(let definition):
            self.init(phrase: hit.phrase, range: range, separation: hit.separation,
                      definition: definition.isEmpty ? nil : definition)
        }
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

/// The phrase, under the sentence it was found in.
///
/// No label naming it a phrase: the span is already underlined in the sentence directly above, and a
/// caption repeating that would be the same fact twice. What the reader cannot see from the sentence is
/// what the phrase *means*, which is what this adds.
struct PhraseNoticeView: View {
    @Environment(\.scale) private var scale
    let phrase: PhrasePresentation
    /// The word's own colour, so the phrase reads as part of the same lookup rather than a second one.
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            Text(verbatim: phrase.phrase)
                .font(.system(size: scale.text.body, weight: .medium))
                .foregroundStyle(accent)
            // **The sense in context where one was chosen, the leading one otherwise.** Showing the
            // first definition when the selector has decided a different one fits would put the wrong
            // meaning under the right phrase — worse than showing none, because the reader cannot see it
            // is wrong.
            if let definition = phrase.met?.definition ?? phrase.definition {
                Text(verbatim: definition)
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(Token.Limit.wrapLines)
            }
            if let met = phrase.met, met.isHypothesis {
                Text("The sense here is a guess — not confirmed")
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.orange)
            }
            if phrase.isGuess {
                // Said in the same voice the card uses for a proposed sense, because it is the same kind
                // of claim: the app worked something out and the reader is entitled to know that before
                // they believe it.
                Text("A guess — these words may not belong together")
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.orange)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
