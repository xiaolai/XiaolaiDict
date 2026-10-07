import CaptureModel
import DictionaryModel
import Foundation
import ReviewKit
import Testing
@testable import XiaolaiDictCore

/// **Narrowing a saved word to the meaning the reader chose** — R1b, a reader option that is off by
/// default (review-module-plan §8.3b, §9).
///
/// ADR-0029 makes target, issuer and language a note's identity, so a word-only card is never
/// re-keyed into a meaning: "a duplicate is repairable, a false merge is not". What the option does
/// instead is three ordinary writes the ledger already has, in one savepoint — the reader's own answer
/// and tags given to the meaning, and the word-only card **archived**, never deleted (ADR-0033's two
/// deletions): its lookups stay, and Saved › Archived brings it back. A card with reviews is never
/// retired without the reader's say, and nothing is half-done.
struct WordCardReplacementTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger() throws -> Ledger { try Ledger(path: ":memory:") }

    private func lookup(_ ledger: Ledger, _ word: String = "fine") throws -> Int {
        try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A \(word) day.", lemmaBasis: .tagger, language: "en",
            contextRange: nil, place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil, script: .latin))
    }

    /// The word-only card the reader saved from a reading: the entry rung, kept explicitly (History's
    /// Save), with whatever answer and tags they gave it since.
    private func wordCard(_ ledger: Ledger, on lookupID: Int, entry: String = "e", dictionary: String = "noad",
                          answer: String? = nil, tags: [String] = [], at when: Date? = nil) throws -> StudyNote {
        let note = try #require(try ledger.keep(
            .entry(dictionary: dictionary, entryID: entry), issuer: .live, language: "en", chosenBy: nil,
            answer: nil, lookupID: lookupID, at: when ?? now, source: .manual))
        if let answer { try ledger.setReaderAnswer(answer, of: note.id, at: now) }
        for tag in tags { try ledger.tag(noteID: note.id, tag) }
        return note
    }

    /// The meaning the reader tapped on that reading, as Choose a Meaning keeps it: theirs, confirmed,
    /// carrying the dictionary's text for that sense.
    private func meaning(_ ledger: Ledger, on lookupID: Int, entry: String = "e") throws -> StudyNote {
        try #require(try ledger.keep(
            .sense(dictionary: "noad", entryID: entry, senseKey: "\(entry).1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a sum paid as a penalty", senseHash: "h"),
            lookupID: lookupID, at: now, source: .manual))
    }

    private func enrollment(_ ledger: Ledger, _ id: UUID) throws -> StudyEnrollment? {
        try ledger.enrollments(ofNotes: [id])[id]
    }

    private func grade(_ ledger: Ledger, _ note: StudyNote) throws {
        let card = try ledger.card(of: note.id, at: now)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: card.revision,
                             at: now, using: try MemoryScheduler())
    }

    /// Everything the operation could touch, for every note, as one comparable value: what each note
    /// is enrolled as and confirmed at, its answer, its tags, its links and its cards' revisions.
    private func snapshot(_ ledger: Ledger) throws -> [String] {
        try ledger.notes().map { note in
            let answer = try ledger.answer(of: note.id)
            let card = try ledger.existingCard(of: note.id, prompt: .meaning)
            return [note.id.uuidString, "\(note.target)", note.enrollment.rawValue,
                    "\(note.confirmedAt?.timeIntervalSince1970 ?? -1)",
                    "\(answer?.origin.rawValue ?? "-"):\(answer?.text ?? "-"):\(answer?.senseHash ?? "-")",
                    try ledger.tags(of: note.id).joined(separator: ","),
                    try ledger.lookupIDs(evidencing: note.id).map(String.init).joined(separator: ","),
                    "\(card?.revision ?? -1)"].joined(separator: " | ")
        }
    }

    // MARK: - Replaced

    /// **The reader's own answer and tags go to the meaning, and the word-only card is archived** —
    /// its row, its answer, its tags and its reading all still there, so it can be brought back.
    @Test func aSavedWordCardGivesTheMeaningItsAnswerAndTagsAndIsArchived() throws {
        let ledger = try ledger()
        let reading = try lookup(ledger)
        let word = try wordCard(ledger, on: reading, answer: "a penalty, as in the parking one", tags: ["law", "money"])
        let sense = try meaning(ledger, on: reading)

        let outcome = try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now)
        #expect(outcome == WordCardReplacement(replaced: [word.id], kept: [:]))

        let answer = try #require(try ledger.answer(of: sense.id))
        #expect(answer.origin == .reader, "the meaning still reveals the dictionary's text, not the reader's own")
        #expect(answer.text == "a penalty, as in the parking one")
        #expect(try ledger.tags(of: sense.id) == ["law", "money"])
        #expect(try ledger.readiness(of: sense.id) == .ready)

        #expect(try enrollment(ledger, word.id) == .archived, "the word-only card is still in study")
        #expect(try ledger.notes().contains { $0.id == word.id }, "the word-only card was deleted, not archived")
        #expect(try ledger.lookupIDs(evidencing: word.id) == [reading], "the word-only card lost its reading")
        #expect(try ledger.answer(of: word.id)?.text == "a penalty, as in the parking one",
                "archiving took the word-only card's own answer with it")
        #expect(try ledger.tags(of: word.id) == ["law", "money"])

        // Reversible: Saved › Archived's Unarchive is `setEnrollment(.active)`.
        try ledger.setEnrollment(.active, ofNotes: [word.id])
        #expect(try ledger.readiness(of: word.id) == .ready, "brought back, the word-only card is as it was")
    }

    /// **The shape on the measured ledger**: a word saved with no answer of its own. Nothing to carry,
    /// and it still leaves study — the meaning keeps the dictionary's text it was saved with.
    @Test func aWordCardWithNoAnswerOfItsOwnIsStillReplaced() throws {
        let ledger = try ledger()
        let reading = try lookup(ledger)
        let word = try wordCard(ledger, on: reading)
        let sense = try meaning(ledger, on: reading)

        #expect(try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now)
                == WordCardReplacement(replaced: [word.id], kept: [:]))
        #expect(try ledger.answer(of: sense.id) == StudyAnswer(origin: .dictionary, text: "a sum paid as a penalty",
                                                              senseHash: "h"))
        #expect(try enrollment(ledger, word.id) == .archived)
    }

    // MARK: - Kept beside

    /// **A word-only card with reviews is never retired without the reader's say.** Kept, untouched,
    /// and named as kept — and the meaning gets nothing of it, because half a merge is a merge.
    @Test func aWordCardWithReviewsIsKeptBesideTheMeaning() throws {
        let ledger = try ledger()
        let reading = try lookup(ledger)
        let word = try wordCard(ledger, on: reading, answer: "a penalty", tags: ["law"])
        try grade(ledger, word)
        let sense = try meaning(ledger, on: reading)
        let before = try snapshot(ledger)

        let outcome = try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now)
        #expect(outcome == WordCardReplacement(replaced: [], kept: [word.id: .reviewed]))
        #expect(try snapshot(ledger) == before, "a reviewed word-only card was changed, or its meaning was")
    }

    /// **Practice is review history too**, and so is a grade that was undone: the reader has met this
    /// card as a question either way.
    @Test func aWordCardOnlyPractisedIsKeptToo() throws {
        let ledger = try ledger()
        let reading = try lookup(ledger)
        let word = try wordCard(ledger, on: reading, answer: "a penalty")
        try grade(ledger, word)
        let card = try ledger.card(of: word.id, at: now)
        _ = try ledger.practise(cardID: card.id, .good, eventID: UUID(), at: now.addingTimeInterval(60))
        let sense = try meaning(ledger, on: reading)

        #expect(try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now).kept == [word.id: .reviewed])
    }

    /// **The first answer stays** (ADR-0030). A meaning that already has an answer of the reader's own,
    /// or that has been asked with the one it has, is not given another: the two cards are kept, and
    /// said to be. The same words twice are no conflict.
    @Test func aMeaningWithAnAnswerOfItsOwnIsNotGivenAnother() throws {
        let ledger = try ledger()
        let reading = try lookup(ledger)
        let word = try wordCard(ledger, on: reading, answer: "a penalty")
        let sense = try meaning(ledger, on: reading)
        try ledger.setReaderAnswer("money paid for breaking a rule", of: sense.id, at: now)
        let before = try snapshot(ledger)
        #expect(try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now).kept == [word.id: .answersDiffer])
        #expect(try snapshot(ledger) == before)

        // A control: the same words are not two answers.
        try ledger.setReaderAnswer("a penalty", of: sense.id, at: now)
        #expect(try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now).replaced == [word.id])
    }

    @Test func aMeaningAlreadyAskedIsNotGivenTheWordsAnswer() throws {
        let ledger = try ledger()
        let reading = try lookup(ledger)
        let word = try wordCard(ledger, on: reading, answer: "a penalty")
        let sense = try meaning(ledger, on: reading)
        try grade(ledger, sense)
        let before = try snapshot(ledger)

        #expect(try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now).kept == [word.id: .answersDiffer],
                "the answer a reviewed meaning reveals was rewritten under the reader")
        #expect(try snapshot(ledger) == before)
    }

    // MARK: - Once, and all or nothing

    /// **Idempotent**: a Retry, or the same meaning chosen again, changes nothing the first did not.
    @Test func replacingTwiceIsReplacingOnce() throws {
        let ledger = try ledger()
        let reading = try lookup(ledger)
        _ = try wordCard(ledger, on: reading, answer: "a penalty", tags: ["law"])
        let sense = try meaning(ledger, on: reading)
        _ = try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now)
        let once = try snapshot(ledger)

        #expect(try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now.addingTimeInterval(60))
                == WordCardReplacement(replaced: [], kept: [:]))
        #expect(try snapshot(ledger) == once, "a second application wrote again")
    }

    /// **A damaged row refuses the whole of it, and what was already written is taken back.** Two
    /// word-only cards on one reading, one of them with an answer whose origin this build cannot read,
    /// **in both orders the replacement can meet them** — oldest first, so their creation instants decide.
    ///
    /// - **Healthy first**: it is replaced — answer, tags, archive — before the damaged one is reached, and
    ///   only the savepoint takes that back. Half-applied, the meaning would carry the first card's answer
    ///   and tags over a second card still standing.
    /// - **Damaged first**: nothing is written before the refusal, so this order cannot test the rollback;
    ///   what it holds is that the damaged card is refused, never skipped — skipped, it would stay in study
    ///   beside a meaning the reader was told replaced it, and the healthy one would be archived.
    ///
    /// Both cards used to be created at one instant, so their order was their random ids', and the rollback
    /// went untested on half the runs: with the savepoint removed, 10 of 20 repetitions passed (the final
    /// closing pass, finding 5).
    @Test(arguments: [true, false])
    func aDamagedWordCardRefusesTheWholeReplacement(healthyFirst: Bool) throws {
        let ledger = try ledger()
        let reading = try lookup(ledger)
        let (healthyAt, damagedAt) = healthyFirst ? (now, now.addingTimeInterval(1)) : (now.addingTimeInterval(1), now)
        let healthy = try wordCard(ledger, on: reading, entry: "e", answer: "a penalty", tags: ["law"], at: healthyAt)
        let damaged = try wordCard(ledger, on: reading, entry: "e2", answer: "fine weather", at: damagedAt)
        // **The premise, asserted**: the order the replacement reads them in is `notes(where:)`'s.
        let order = try ledger.notes().filter { if case .entry = $0.target { true } else { false } }.map(\.id)
        #expect(order == (healthyFirst ? [healthy.id, damaged.id] : [damaged.id, healthy.id]))
        try ledger.execute("""
            PRAGMA ignore_check_constraints = ON;
            UPDATE study_answers SET origin = 'scribble' WHERE note_id = '\(damaged.id.uuidString)';
            PRAGMA ignore_check_constraints = OFF;
            """)
        let sense = try meaning(ledger, on: reading)
        let before = try ledger.notes().map(\.enrollment)
        let senseTags = try ledger.tags(of: sense.id), senseAnswer = try ledger.answer(of: sense.id)

        #expect(throws: LedgerError.corruptRow("study_answers \(damaged.id.uuidString)")) {
            _ = try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now)
        }
        #expect(try ledger.notes().map(\.enrollment) == before, "a card was archived by a refused replacement")
        #expect(try ledger.tags(of: sense.id) == senseTags, "the meaning kept tags from a refused replacement")
        #expect(try ledger.answer(of: sense.id) == senseAnswer, "the meaning kept an answer from a refused replacement")
    }

    /// **Refused, never skipped**: a word-only card whose enrollment this build cannot read is not
    /// left out of the replacement as though it were not in study — filtering it in SQL would have
    /// done exactly that, silently.
    @Test func aWordCardWhoseEnrollmentCannotBeReadIsRefused() throws {
        let ledger = try ledger()
        let reading = try lookup(ledger)
        let word = try wordCard(ledger, on: reading)
        let sense = try meaning(ledger, on: reading)
        try ledger.execute("""
            PRAGMA ignore_check_constraints = ON;
            UPDATE study_notes SET enrollment = 'shelved' WHERE id = '\(word.id.uuidString)';
            PRAGMA ignore_check_constraints = OFF;
            """)
        #expect(throws: LedgerError.corruptRow("study_notes \(word.id.uuidString)")) {
            _ = try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now)
        }
    }

    // MARK: - Which cards

    /// **Only this reading's word-only cards in the meaning's own dictionary, issuer and language.** A
    /// word-only card in another dictionary is another dictionary's study (D7); one on another reading
    /// is about another reading; one archived already, or a meaning rather than a word, is no
    /// word-only card in study at all.
    @Test func onlyThisReadingsWordCardsInTheMeaningsDictionaryAreReplaced() throws {
        let ledger = try ledger()
        let reading = try lookup(ledger), other = try lookup(ledger, "fine")
        let otherDictionary = try wordCard(ledger, on: reading, dictionary: "oald")
        let otherReading = try wordCard(ledger, on: other, entry: "e3")
        let archived = try wordCard(ledger, on: reading, entry: "e4")
        try ledger.setEnrollment(.archived, ofNotes: [archived.id])
        let anotherMeaning = try meaning(ledger, on: reading, entry: "e5")
        let word = try wordCard(ledger, on: reading)
        let sense = try meaning(ledger, on: reading)

        #expect(try ledger.replaceWordCards(onLookup: reading, with: sense.id, at: now)
                == WordCardReplacement(replaced: [word.id], kept: [:]))
        for untouched in [otherDictionary, otherReading, anotherMeaning] {
            #expect(try enrollment(ledger, untouched.id) == .active, "\(untouched.target) was archived")
        }
    }

    /// **A meaning is what narrows**: handed an entry note, there is nothing narrower to give its
    /// place to, and nothing changes.
    @Test func anEntryNoteNarrowsNothing() throws {
        let ledger = try ledger()
        let reading = try lookup(ledger)
        let word = try wordCard(ledger, on: reading)
        let another = try wordCard(ledger, on: reading, entry: "e2")
        let before = try snapshot(ledger)
        #expect(try ledger.replaceWordCards(onLookup: reading, with: another.id, at: now)
                == WordCardReplacement(replaced: [], kept: [:]))
        #expect(try snapshot(ledger) == before)
        #expect(try enrollment(ledger, word.id) == .active)
    }
}
