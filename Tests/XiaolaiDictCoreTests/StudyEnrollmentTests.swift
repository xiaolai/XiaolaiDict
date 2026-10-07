import CaptureModel
import DictionaryModel
import Foundation
import Testing
@testable import XiaolaiDictCore

/// **Making one trustworthy study target out of a lookup.** WI-002.
///
/// The thing this has to get right is not saving — it is *not* saving something that will later be graded
/// as though it were known. A sense the model guessed, an entry rung with no answer of its own, a note
/// whose reading the reader has since deleted: each is enrollable and none is gradable, and the difference
/// has to survive being written down.
///
/// **Readiness is derived, never stored.** Schema 8 kept it in a column, which was wrong for the ordinary
/// reason: the facts it depends on change elsewhere. Deleting the last lookup that evidences a note leaves
/// no cue, and a stored `ready` would still say ready — the stale-value failure this project spends its
/// time removing. Schema 9 stores the facts (a confirmation, an answer, the links) and computes the rest.
struct StudyEnrollmentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger() throws -> Ledger { try Ledger(path: ":memory:") }

    private func lookup(_ ledger: Ledger, _ lemma: String = "fine") throws -> Int {
        try ledger.record(LookupRecord(
            surface: lemma, lemma: lemma, context: "He paid the \(lemma).", lemmaBasis: .tagger,
            language: "en", contextRange: NSRange(location: 12, length: lemma.utf16.count),
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari", document: nil,
                                page: nil, title: nil, rawTitle: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService,
            quality: .accessibility(.accessibilityTextMarkers, context: .complete)))
    }

    private let sense = StudyTarget.sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001",
                                          senseKeyKind: .publisher)

    private func answer(_ text: String = "a sum of money exacted as a penalty",
                        origin: StudyAnswer.Origin = .dictionary) -> StudyAnswer {
        StudyAnswer(origin: origin, text: text, dictionaryVersion: "2.6", senseHash: "h1")
    }

    // MARK: - Saving

    /// The everyday case: the reader taps a sense and it becomes one active, gradable target.
    @Test func areaderTappedSenseIsSavedReadyToReview() throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let note = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                                     answer: answer(), lookupID: id, at: now)
        #expect(note.enrollment == .active)
        #expect(try ledger.readiness(of: note.id) == .ready)
        #expect(try ledger.answer(of: note.id)?.text == "a sum of money exacted as a penalty")
        #expect(try ledger.lookupIDs(evidencing: note.id) == [id])
    }

    /// **C03: the same target twice is one note that has met the reader twice.** A second save does not
    /// make a second card, and it does not throw at the caller either — tapping a sense you already study
    /// is an ordinary thing to do, and the honest answer is the note you already have.
    @Test func savingTheSameTargetTwiceEnrichesOneNote() throws {
        let ledger = try ledger()
        let first = try lookup(ledger), second = try lookup(ledger, "fine")
        let a = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                                  answer: answer(), lookupID: first, at: now)
        let b = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                                  answer: answer(), lookupID: second, at: now.addingTimeInterval(60))
        #expect(a.id == b.id)
        #expect(try ledger.notes().count == 1)
        #expect(try ledger.lookupIDs(evidencing: a.id) == [first, second],
                "both readings evidence the one target")
    }

    /// And the same lookup twice — a double tap, a retry after a failure the reader could not see — adds
    /// one link, not two. An encounter counted twice is a reading history that overstates itself.
    @Test func thesameLookupTwiceIsOneEncounter() throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let note = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                                     answer: answer(), lookupID: id, at: now)
        _ = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                              answer: answer(), lookupID: id, at: now)
        #expect(try ledger.lookupIDs(evidencing: note.id) == [id])
    }

    // MARK: - What may not be graded

    /// **C04: a sense the model proposed is a hypothesis, and a hypothesis is not a question.** Grading
    /// one records the reader's memory of a guess, against a target that may not be the one they met.
    @Test func amodelProposalIsSavedButNotGradable() throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let note = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .model,
                                     answer: answer(), lookupID: id, at: now)
        #expect(note.enrollment == .active, "it is saved")
        #expect(try ledger.readiness(of: note.id) == .needsConfirmation, "and it is not askable")
    }

    /// The reader accepting it is a new fact, recorded on the note — **the selector's own row is not
    /// rewritten**. `chosen_by` never merges: a proposal that was later agreed with is not the same
    /// history as a sense the reader picked unaided, and the ledger has to be able to tell them apart.
    @Test func confirmingAproposalDoesNotRewriteWhatTheSelectorDid() throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        try ledger.record(SenseEncounter(
            dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad", version: "2.6"),
            entryID: "e1", senseKey: "e1.001", senseKeyKind: .publisher, sensePath: nil,
            entrySenseCount: 4, senseHash: "h1", gloss: "a penalty", chosenBy: .model, chosenAt: now),
            for: id)
        let note = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .model,
                                     answer: answer(), lookupID: id, at: now)

        try ledger.confirm(noteID: note.id, at: now.addingTimeInterval(30))
        #expect(try ledger.readiness(of: note.id) == .ready)
        #expect(try ledger.encounters(ofLookup: id).map(\.chosenBy) == [.model],
                "the selector's attribution is evidence, not a draft to be edited")
    }

    /// **K04: an answer nothing can reveal is not a card.** A target saved with no answer is kept — the
    /// reader asked for it — and is refused a grade until it has one, rather than being asked as a
    /// question with a blank back.
    @Test func atargetWithNoAnswerNeedsRepair() throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let note = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                                     answer: nil, lookupID: id, at: now)
        #expect(try ledger.readiness(of: note.id) == .needsRepair)
        try ledger.setAnswer(answer(), of: note.id, at: now)
        #expect(try ledger.readiness(of: note.id) == .ready)
    }

    /// An empty answer is the same nothing, said differently. A whitespace-only string reaching the back
    /// of a card is the "blank graded answer" K04 names.
    @Test(arguments: ["", "   ", "\n"])
    func anEmptyAnswerIsNoAnswer(text: String) throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let note = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                                     answer: answer(text), lookupID: id, at: now)
        #expect(try ledger.readiness(of: note.id) == .needsRepair)
    }

    /// **An entry rung is honest, and it is not a sense-specific answer.** The dictionary's whole entry
    /// is too broad for "what does this mean here?", so an entry target carrying the dictionary's text
    /// waits for the reader to narrow it; one carrying the reader's own words is ready.
    @Test func anEntryRungWaitsForTheReadersOwnAnswer() throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let target = StudyTarget.entry(dictionary: "noad", entryID: "e1")
        let note = try ledger.enroll(target, issuer: .live, language: "en", chosenBy: nil,
                                     answer: answer(), lookupID: id, at: now)
        #expect(try ledger.readiness(of: note.id) == .needsConfirmation)
        try ledger.setAnswer(answer("the money you pay when you are caught", origin: .reader),
                             of: note.id, at: now)
        #expect(try ledger.readiness(of: note.id) == .ready)
    }

    /// **A note whose reading the reader deleted has no cue, and says so.** This is the case a stored
    /// readiness column could not express: nothing about the note changed, and it stopped being askable.
    @Test func anoteWhoseReadingIsGoneNeedsRepair() throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let note = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                                     answer: answer(), lookupID: id, at: now)
        #expect(try ledger.readiness(of: note.id) == .ready)
        try ledger.delete(lookup: id)
        #expect(try ledger.readiness(of: note.id) == .needsRepair,
                "the answer survived, the question did not")
        #expect(try ledger.notes().count == 1, "and the target is still the reader's")
    }

    // MARK: - Disposition

    /// **C05: every disposition is reversible, and none of them erases anything.** "Already know" is a
    /// declaration about this target, not a measurement and not a delete.
    @Test(arguments: [StudyEnrollment.ignored, .archived, .candidate, .active])
    func adispositionIsReversibleAndKeepsTheEvidence(disposition: StudyEnrollment) throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let note = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                                     answer: answer(), lookupID: id, at: now)
        try ledger.setEnrollment(disposition, of: note.id)
        #expect(try ledger.notes().first?.enrollment == disposition)
        try ledger.setEnrollment(.active, of: note.id)
        #expect(try ledger.notes().first?.enrollment == .active)
        #expect(try ledger.lookupIDs(evidencing: note.id) == [id], "the reading was never the target's")
    }

    /// **Undo removes the enrollment and nothing else.** The reader's reading history is not the reader's
    /// study list, and the command that ends one must not touch the other (D02).
    @Test func unenrollingKeepsTheReadingHistory() throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let note = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                                     answer: answer(), lookupID: id, at: now)
        try ledger.remove(noteID: note.id)
        #expect(try ledger.notes().isEmpty)
        #expect(try ledger.answer(of: note.id) == nil, "the derived copy goes with it")
        #expect(try ledger.history(of: "fine").count == 1, "the lookup is the reader's, not the card's")
    }

    // MARK: - Repair

    /// **R07: correcting a wrong meaning starts a target of its own.** The corrected sense is a different
    /// note, so it cannot inherit the wrong one's schedule — and the original keeps its history rather
    /// than being relabelled, because the reader really did meet it and really did mark it.
    @Test func correctingTheMeaningCannotInheritTheWrongTargetsHistory() throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let wrong = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .model,
                                      answer: answer(), lookupID: id, at: now)
        let right = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e1", senseKey: "e1.004", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader, answer: answer("of high quality"),
            lookupID: id, at: now.addingTimeInterval(30))
        #expect(wrong.id != right.id)
        #expect(try ledger.readiness(of: wrong.id) == .needsConfirmation, "the guess is still a guess")
        #expect(try ledger.readiness(of: right.id) == .ready)
        #expect(try ledger.notes().count == 2)
    }

    /// **M07: a sense whose text has moved under it is not the sense that was enrolled.** The hash is
    /// what notices an Apple content update re-pointing a positional key, and a card that cannot be shown
    /// to be about the same sense may not be graded on the reader's memory of the old one.
    @Test func achangedSenseHashNeedsRepair() throws {
        let ledger = try ledger()
        let id = try lookup(ledger)
        let note = try ledger.enroll(sense, issuer: .live, language: "en", chosenBy: .reader,
                                     answer: answer(), lookupID: id, at: now)
        #expect(try ledger.readiness(of: note.id) == .ready)
        #expect(try ledger.readiness(of: note.id, senseHashNow: "h1") == .ready)
        #expect(try ledger.readiness(of: note.id, senseHashNow: "h2") == .needsRepair)
        #expect(try ledger.readiness(of: note.id, senseHashNow: nil) == .ready,
                "a dictionary that cannot be asked is not evidence the sense moved")
    }
}
