import Foundation

/// **What replacing a reading's word-only cards with the meaning the reader chose came to** — R1b,
/// a reader option that is off by default (review-module-plan §8.3b, §9).
///
/// A value, not a verdict: every word-only card the reading had is either in `replaced` or in `kept`
/// with the reason it was kept, and an empty answer means there was nothing to replace.
public struct WordCardReplacement: Sendable, Equatable {
    /// Why a word-only card was left in study beside the meaning.
    public enum Kept: String, Sendable, Equatable, CaseIterable {
        /// It has review history — graded, practised, or graded and undone. The reader has met it as a
        /// question, and retiring it is theirs to decide.
        case reviewed
        /// It has an answer of the reader's own and the meaning already reveals another — one of their
        /// own, or one it has been asked with. **The first answer stays** (ADR-0030).
        case answersDiffer
    }

    /// Archived, in the order they were found: oldest first.
    public let replaced: [UUID]
    public let kept: [UUID: Kept]

    public init(replaced: [UUID], kept: [UUID: Kept]) {
        self.replaced = replaced
        self.kept = kept
    }

    /// No word-only card of this reading to replace.
    public static let nothing = WordCardReplacement(replaced: [], kept: [:])
}

extension Ledger {
    /// **Narrows a reading's saved word to the meaning the reader chose** — without re-keying anything.
    ///
    /// ADR-0029 makes target, issuer and language a note's identity, and "a duplicate is repairable, a
    /// false merge is not": a word-only card is never rewritten into a meaning. What this does instead
    /// is three writes the ledger already offers, **in one savepoint**:
    ///
    /// 1. the word-only card's **answer of the reader's own** becomes the meaning's answer — only where
    ///    the meaning has none of the reader's own and has never been asked, because replacing what a
    ///    card reveals under a reader who has been asked it is an edit only they make (ADR-0030);
    /// 2. its **tags** are added to the meaning's;
    /// 3. it is **archived** — never removed (ADR-0033's two deletions): its row, its answer, its tags
    ///    and every reading it is linked to stay, and Saved › Archived brings it back.
    ///
    /// **Which cards**: the entry notes linked to this reading, in the meaning's dictionary, under its
    /// issuer and language, enrolled `active`. An automatic draft `keep` has already unlinked from this
    /// reading is not one — that is today's behaviour, and the option does not change it.
    ///
    /// **Never without the reader's say**: a card with any review history — a grade, a practice, one
    /// undone — is kept beside the meaning, untouched, and so is one whose answer would overwrite
    /// another; the answer says which, so the surface can say so.
    ///
    /// **All or nothing, and once**: a row this build cannot read — a note, an enrollment, an answer's
    /// origin — throws and takes back everything written before it; applied again, an archived card is
    /// no longer a candidate and nothing changes. A note that is not a meaning narrows nothing.
    public func replaceWordCards(onLookup lookupID: Int, with senseNoteID: UUID,
                                 at when: Date) throws -> WordCardReplacement {
        var result = WordCardReplacement.nothing
        try inOneTransaction("replaceWordCards") {
            guard let sense = try notes(where: "WHERE id = ?", bind: [.text(senseNoteID.uuidString)]).first,
                  case .sense(let dictionary, _, _, _) = sense.target else { return }
            // **Every note linked to the reading in this dictionary is decoded**, and a row that cannot
            // be is refused here — never filtered out in SQL, where a damaged enrollment would have
            // read as "not in study" and stayed beside the meaning unremarked.
            let linked = try notes(where: """
                WHERE dictionary = ? AND id <> ?
                  AND id IN (SELECT note_id FROM study_note_lookups WHERE lookup_id = ?)
                """, bind: [.text(dictionary), .text(sense.id.uuidString), .integer(lookupID)])
            let words = linked.filter {
                if case .entry = $0.target {
                    $0.issuer == sense.issuer && $0.language == sense.language && $0.enrollment == .active
                } else { false }
            }
            var replaced: [UUID] = [], kept: [UUID: WordCardReplacement.Kept] = [:]
            for word in words {
                if try hasReviewHistory(word.id) {
                    kept[word.id] = .reviewed
                    continue
                }
                if let own = try answer(of: word.id), own.origin == .reader, own.isUsable {
                    let current = try answer(of: sense.id)
                    let senseWasAsked = try hasReviewHistory(sense.id)
                    if current?.origin == .reader || senseWasAsked {
                        guard current?.text == own.text else {
                            kept[word.id] = .answersDiffer
                            continue
                        }
                    } else {
                        try setAnswer(StudyAnswer(origin: .reader, text: own.text), of: sense.id, at: when)
                    }
                }
                for tag in try tags(of: word.id) { try self.tag(noteID: sense.id, tag) }
                try setEnrollment(.archived, of: word.id)
                replaced.append(word.id)
            }
            result = WordCardReplacement(replaced: replaced, kept: kept)
        }
        return result
    }

    /// Whether any of a note's cards has been met as a question — graded, practised, or graded and
    /// undone. An undone grade is history too: the reader saw the card and answered it.
    func hasReviewHistory(_ noteID: UUID) throws -> Bool {
        var found = false
        try run("""
            SELECT EXISTS (SELECT 1 FROM review_events e JOIN study_cards c ON c.id = e.card_id
                           WHERE c.note_id = ?)
            """, bind: [.text(noteID.uuidString)]) { found = $0.integer(0) == 1 }
        return found
    }
}
