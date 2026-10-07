import CaptureModel
import DictionaryModel
import Foundation
import ReviewKit
import StudyKit
@testable import StudyModels
import StudyPresentation
import Testing
@testable import XiaolaiDictUI
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **The funnel between saving a meaning and being asked it** — review-module-plan §8.3, WI-4.
///
/// On the one ledger measured, 67 meanings were saved and 2 passed the queue. These are the wires
/// between the two: what Confirm reaches and what it counts, what Review says is in the way, the
/// route to an answer of the reader's own, and the cooldown experiment.
@MainActor
struct FunnelWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func lookup(_ ledger: Ledger, _ word: String, at when: Date? = nil) throws -> Int {
        try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word) in it.",
            lemmaBasis: .tagger, language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: when ?? now, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
    }

    /// A sense the selector proposed, saved as it was drawn: the dictionary's text, not yet the
    /// reader's (ADR-0030).
    private func proposal(_ ledger: Ledger, _ word: String) throws -> StudyNote {
        try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .model,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: try lookup(ledger, word), at: now)
    }

    /// An entry note with no answer and no confirmation — the shape of the 22 on the measured ledger:
    /// a backfilled draft enrols as `.model`, and the entry rung the automatic path records carries
    /// no gloss (`PrimaryDictionary.encounter`).
    private func answerlessEntry(_ ledger: Ledger, _ word: String, at when: Date? = nil) throws -> StudyNote {
        try ledger.enroll(
            .entry(dictionary: "noad", entryID: "e-\(word)"), issuer: .live, language: "en",
            chosenBy: .model, answer: nil, lookupID: try lookup(ledger, word, at: when), at: when ?? now)
    }

    /// An entry rung saved from the card: the dictionary's leading definition, confirmed as it was
    /// saved because no sense was claimed. ADR-0030 holds it at `needsConfirmation` until the reader
    /// narrows it — which confirming cannot do.
    private func entryWithTheDictionarysText(_ ledger: Ledger, _ word: String) throws -> StudyNote {
        try ledger.enroll(
            .entry(dictionary: "noad", entryID: "e-\(word)"), issuer: .live, language: "en",
            chosenBy: nil, answer: StudyAnswer(origin: .dictionary, text: "the whole entry for \(word)"),
            lookupID: try lookup(ledger, word), at: now)
    }

    private func library(_ path: String, defaults: UserDefaults = TemporaryDefaults.suite()) -> LibraryModel {
        LibraryModel(store: Wiring.store(path), clock: { self.now },
                     exportDirectory: { ScratchFile.unmade("export", file: "exports") },
                     defaults: defaults, primary: { PrimaryDictionary(chosen: "noad") })
    }

    private func confirmedAt(_ path: String, _ id: UUID) -> Date? {
        (try? Ledger(path: path).notes().first { $0.id == id })?.confirmedAt
    }

    // MARK: - (a) Confirm reaches what it changes, and counts that

    /// **Three rows selected, one of which Confirm can change.** The control counted and confirmed
    /// the whole selection: an answerless entry note had `confirmed_at` written and stayed exactly as
    /// unreviewable as before, and a note already confirmed was counted as one more to confirm.
    @Test func aMixedSelectionConfirmsOnlyWhatNeedsConfirmation() async throws {
        let (path, clean) = Wiring.scratch("funnel-mixed")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let proposal = try proposal(ledger, "fine")
        let answerless = try answerlessEntry(ledger, "hold")
        let ready = try Wiring.save(ledger, "bank", at: now)
        let before = try ledger.notes()

        let model = library(path)
        await model.reload()
        model.act(.select([proposal.id, answerless.id, ready.id]))
        try await Wiring.settle { model.presentation.selection.count == 3 }
        #expect(model.presentation.canConfirm, "positive control: one of the three needs confirming")
        // What "Confirm ^[n Meaning]" is drawn from: the toolbar's target and the right-click
        // menu's, which are one builder.
        #expect(model.presentation.confirmable == [proposal.id])
        #expect(model.presentation.selectionTarget.confirmable.count == 1, "the label would say Confirm 3")
        #expect(model.presentation.selectionTarget.ids.count == 3, "and every other control still reaches all three")

        model.act(.confirm)
        try await Wiring.settle { confirmedAt(path, proposal.id) != nil }
        let after = try Ledger(path: path).notes()
        let written = after.filter { note in
            note.confirmedAt != nil && before.first { $0.id == note.id }?.confirmedAt == nil
        }
        #expect(written.map(\.id) == [proposal.id],
                "Confirm wrote confirmed_at on \(written.count) notes; only the proposal needed it")
        #expect(try Ledger(path: path).readiness(of: answerless.id) == .needsRepair)
    }

    /// **The plan's rule, refined by evidence.** "Rows whose readiness is `.needsConfirmation`" includes
    /// an entry rung carrying the dictionary's own text (StudyNote.swift: `isEntryRung, answerIsPublishers`),
    /// which is confirmed as it is saved — so Confirm offered over it writes nothing at all, and if it
    /// were unconfirmed would write a fact that leaves it unreviewable. What it needs is an answer.
    @Test func anEntryCarryingTheDictionarysTextIsNotOfferedConfirm() async throws {
        let (path, clean) = Wiring.scratch("funnel-entry")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let entry = try entryWithTheDictionarysText(ledger, "fine")
        #expect(try ledger.readiness(of: entry.id) == .needsConfirmation, "the premise: ADR-0030's verdict")
        #expect(entry.confirmedAt != nil, "and it is confirmed already")

        let model = library(path)
        await model.reload()
        model.act(.select([entry.id]))
        try await Wiring.settle { model.presentation.selection == [entry.id] }
        #expect(!model.presentation.canConfirm, "Confirm is offered over a note it cannot change")
        #expect(model.presentation.rows.first?.status == .needsRepair,
                "the row says \"Confirm the meaning\" of a note confirming cannot help")
        // The right-click menu on the row itself, which is described from the row.
        let row = try #require(model.presentation.rows.first)
        #expect(!row.isConfirmable)
        #expect(model.presentation.target(of: row).confirmable.isEmpty)
    }

    /// **What Review says is in the way, by reason.** It said all of them "cannot be reviewed until
    /// you choose or confirm", and Confirm is not the remedy for most of them.
    @Test func theEmptyStateCountsByReason() async throws {
        let (path, clean) = Wiring.scratch("funnel-reasons")
        defer { clean() }
        let ledger = try Ledger(path: path)
        _ = try proposal(ledger, "fine")
        _ = try answerlessEntry(ledger, "hold")
        _ = try entryWithTheDictionarysText(ledger, "bank")
        let deleted = try proposal(ledger, "spring")
        try ledger.deleteReading(lookups: try ledger.lookupIDs(evidencing: deleted.id))
        let archived = try proposal(ledger, "well")
        try ledger.setEnrollment(.archived, of: archived.id)

        let review = ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                                 clock: { self.now }, defaults: TemporaryDefaults.suite(), finish: {},
                                 openInDictionary: { _ in false })
        await review.start()
        let waiting = StudyAttention(toConfirm: 1, toAnswer: 2, readingDeleted: 1)
        #expect(review.presentation.stage == .empty(.needsAttention(waiting)))
        #expect(review.presentation.offersFindUnconfirmed, "the empty state carries the way to Saved itself")
        #expect(waiting.total == (try ledger.collectedCount(dictionary: "noad", needingAttention: true)),
                "the reasons add up to the one count they replace")

        // The toolbar's "Find N Meanings to Confirm" counts what confirming fixes.
        let model = library(path)
        await model.refreshReviewCount()
        #expect(model.reviewUnconfirmed == 1, "the toolbar offers \(model.reviewUnconfirmed) to confirm; one can be")

        // And the report the `review` stage reads names each reason.
        let report = ReviewReport.describe(review.presentation)
        #expect(report["reason"] as? String == "needsAttention")
        #expect(report["count"] as? Int == 4)
        #expect(report["toConfirm"] as? Int == 1)
        #expect(report["toAnswer"] as? Int == 2)
        #expect(report["readingDeleted"] as? Int == 1)
    }

    // MARK: - (b) The route to an answer of the reader's own

    /// **An answerless entry note becomes askable when the reader writes an answer, and confirms.**
    /// The route is Review's empty state → Saved, with the first one needing an answer open in the
    /// inspector → its editor → Confirm, which only then is offered. Confirming first is not a route:
    /// it writes `confirmed_at` and the note is exactly as unreviewable as before.
    @Test func aReaderAnswerMakesAnEntryNoteAskableOnceConfirmed() async throws {
        let (path, clean) = Wiring.scratch("funnel-answer")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let entry = try answerlessEntry(ledger, "fine")
        // Older, so it is not the first the route opens.
        let confirmedFirst = try answerlessEntry(ledger, "hold", at: now.addingTimeInterval(-60))
        let review = ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                                 clock: { self.now }, defaults: TemporaryDefaults.suite(), finish: {},
                                 openInDictionary: { _ in false })
        await review.start()
        #expect(review.presentation.stage == .empty(.needsAttention(StudyAttention(toConfirm: 0, toAnswer: 2, readingDeleted: 0))))

        // **The control: confirming alone.** The fact is written and nothing else changes.
        try ledger.confirm(noteID: confirmedFirst.id, at: now)
        #expect(try ledger.notes().first { $0.id == confirmedFirst.id }?.confirmedAt != nil)
        #expect(try ledger.readiness(of: confirmedFirst.id) == .needsRepair)
        await review.start()
        #expect(review.presentation.stage == .empty(.needsAttention(StudyAttention(toConfirm: 0, toAnswer: 2, readingDeleted: 0))),
                "confirming an answerless note moved it out of \"to answer\"")

        // The route, as Review's "Write Answers" button takes it.
        let model = library(path)
        model.setInspector(false)
        model.findUnanswered()
        try await Wiring.settle("the route never opened the note") { model.presentation.inspector?.id == entry.id }
        #expect(model.pane == .saved)
        #expect(model.presentation.filter == .needsAttention)
        #expect(model.presentation.selection == [entry.id])
        #expect(model.inspectorShown, "the editor is in the inspector, so the route opens it")
        #expect(model.presentation.inspector?.closedAnswer == .write, "and what it offers is the editor")
        #expect(model.presentation.confirmable.isEmpty, "Confirm is not offered before there is an answer")

        model.act(.setAnswer(noteID: entry.id, text: "a sum paid as a penalty"))
        try await Wiring.settle { model.presentation.inspector?.isReaders == true }
        #expect(model.presentation.confirmable == [entry.id], "with an answer, confirming is what is left")

        model.act(.confirm)
        try await Wiring.settle { (try? Ledger(path: path).readiness(of: entry.id)) == .ready }
        await review.start()
        guard case .asking(let question) = review.presentation.stage else {
            Issue.record("the note the reader answered and confirmed is not asked: \(review.presentation.stage)")
            return
        }
        #expect(question.word == "fine")
    }

    /// How the entry note was kept, which is what decides its fate below.
    enum EntryKeep: String, CaseIterable, Sendable { case automatically, byTheReader }

    /// **Does "Choose a Meaning" retire the entry note? Pinned, as it is today** — the plan's open
    /// question (§8.3b, §11).
    ///
    /// **The answer: it depends on how the entry note was kept, and the note's row is never deleted.**
    /// Choosing a sense on a reopened reading keeps the sense as the reader's (`source: .manual`,
    /// confirmed), and `Ledger.keep` then drops *this reading's* link to every other note in that
    /// dictionary that is an untouched draft — `explicit_keep = 0`, `automatic` or `legacy`, never
    /// reviewed. So:
    /// - **kept automatically** (or a backfilled legacy draft): its link to the reading goes, and with no
    ///   other kept reading it is no longer collected — gone from Saved and from Review's count. Retired.
    /// - **saved by the reader** (History's Save, or any note from before schema 13, which the
    ///   migration marked explicit): kept, linked, answerless and `needsRepair`, beside the new sense
    ///   note. Choose a Meaning adds a target; it retires nothing the reader asked for.
    ///
    /// Nothing narrows the entry note to the sense in place: that is an ADR-0029 identity question.
    /// **This is the reader's option off, which is the default.** On (R1b, 2026-10-05), the word-only
    /// card the reader saved gives the meaning its answer and tags and is archived, never re-keyed —
    /// `WordCardReplacementWiringTests`.
    @Test(arguments: EntryKeep.allCases)
    func choosingAMeaningFromHistoryRetiresOrKeepsTheEntryNote(_ kept: EntryKeep) async throws {
        let (path, clean) = Wiring.scratch("funnel-choose")
        defer { clean() }
        let recorder = LookupRecorder()
        recorder.start { try LedgerStore(path: path) }
        let noad = DictionaryIdentity(name: "noad", identifier: "noad")
        // The entry rung the automatic path records: one entry, several senses, no sense claimed —
        // and so no gloss, and no answer.
        let entryRung = SenseEncounter(
            dictionary: noad, entryID: "e", senseKey: nil, senseKeyKind: .none, sensePath: nil,
            entrySenseCount: 2, senseHash: nil, gloss: nil, chosenBy: nil, chosenAt: nil)
        let first = LookupRecording(
            record: LookupRecord(surface: "fine", lemma: "fine", context: "A fine day.", language: "en",
                                 lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil),
            encounter: entryRung, keepPolicy: kept == .automatically ? .automatic : .manual,
            primaryDictionary: "noad")
        await recorder.record(first, request: 1)
        if kept == .byTheReader {
            // History's Save: `ArchiveAction.keep`, through the store the app uses.
            #expect(try await recorder.store?.value.keepHistory(1) != nil)
        }
        let ledger = try Ledger(path: path)
        let entry = try #require(try ledger.notes().first)
        #expect(entry.target == .entry(dictionary: "noad", entryID: "e"))
        #expect(try ledger.readiness(of: entry.id) == .needsRepair, "the premise: an answerless entry note")

        // Choose a Meaning: `reopenReading` hands the lookup's own identity over, and the reader taps a sense.
        let reading = try #require(try ledger.reading(ofLookup: 1))
        await recorder.record(LookupRecording(record: first.record.pending(), encounter: nil, lookup: reading.identity,
                                              keepPolicy: first.keepPolicy), request: 2)
        recorder.study(SenseEncounter(
            dictionary: noad, entryID: "e", senseKey: "e.1", senseKeyKind: .publisher, sensePath: nil,
            entrySenseCount: 2, senseHash: "h", gloss: "a sum paid as a penalty", chosenBy: .reader,
            chosenAt: now), request: 2)
        await recorder.settled(request: 2)

        let notes = try ledger.notes()
        let sense = try #require(notes.first { $0.target != entry.target }, "no note for the chosen sense")
        #expect(sense.confirmedAt != nil, "a sense the reader tapped is theirs")
        #expect(try ledger.readiness(of: sense.id) == .ready)
        #expect(notes.contains { $0.id == entry.id }, "Choose a Meaning deleted the entry note's row")
        switch kept {
        case .automatically:
            #expect(try ledger.lookupIDs(evidencing: entry.id).isEmpty, "the draft kept its link")
            #expect(try ledger.library(LibraryQuery()).map(\.id) == [sense.id], "the draft is still in Saved")
            #expect(try ledger.collectedCount(dictionary: "noad", needingAttention: true) == 0)
        case .byTheReader:
            #expect(try ledger.lookupIDs(evidencing: entry.id) == [1], "the reader's own save lost its reading")
            #expect(Set(try ledger.library(LibraryQuery()).map(\.id)) == [sense.id, entry.id])
            #expect(try ledger.readiness(of: entry.id) == .needsRepair, "and it is as answerless as it was")
            #expect(try ledger.collectedCount(dictionary: "noad", needingAttention: true) == 1)
        }
    }

    // MARK: - (c) The cooldown experiment, off unless switched on

    /// The defaults key that switches the experiment on. **Spelled here, not read from the type**: a
    /// renamed key is every reader who switched it on silently switched off, and this is what notices.
    private static let experimentKey = "reviewConfirmationCooldown"

    /// Whether the rule would hide this note's card after an answer-showing confirmation — the arm,
    /// asked of the public rule rather than restated here.
    private func inCooldownArm(_ id: UUID) -> Bool {
        ConfirmationCooldown().hiddenUntil(noteID: id, confirmedAt: now, exposure: .answerShown) != nil
    }

    /// A proposal whose id lands in the arm asked for. Ids are random, so it saves until one does;
    /// sixty-four misses in a row is a one-in-2⁶⁴ event, or a rule that is not parity.
    private func proposal(_ ledger: Ledger, inCooldownArm wanted: Bool, _ tag: String) throws -> StudyNote {
        for index in 0..<64 {
            let note = try proposal(ledger, "\(tag)\(index)")
            if inCooldownArm(note.id) == wanted { return note }
        }
        throw WiringTimeout(what: "no note landed in the \(wanted ? "cooldown" : "control") arm")
    }

    private func card(_ path: String, of id: UUID) throws -> StudyCard {
        try Ledger(path: path).card(of: id, at: now)
    }

    /// **Off by default, and off is today.** History's Confirm — the surface that shows the answer —
    /// on a note in the cooldown arm, with nothing in the reader's defaults: the card is exactly as it
    /// was, revision included.
    @Test func withTheExperimentOffAConfirmationHidesNothing() async throws {
        let (path, clean) = Wiring.scratch("funnel-cooldown-off")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try proposal(ledger, inCooldownArm: true, "fine")
        let before = try card(path, of: note.id)

        let model = library(path)
        model.actArchive(.confirm(note.id))
        try await Wiring.settle { confirmedAt(path, note.id) != nil }
        #expect(try card(path, of: note.id) == before, "a confirmation touched the card with the experiment off")
    }

    /// **On: History's Confirm hides the cooldown arm's card, and only that arm's.** The inspector
    /// draws Confirm beside the revealed meaning and nowhere else (`LearningLibraryView`), so a
    /// confirmation from there is one that showed the answer.
    @Test func aConfirmationThatShowedTheAnswerHidesTheCardInTheCooldownArmOnly() async throws {
        let (path, clean) = Wiring.scratch("funnel-cooldown-on")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let cooled = try proposal(ledger, inCooldownArm: true, "fine")
        let control = try proposal(ledger, inCooldownArm: false, "hold")
        let defaults = TemporaryDefaults.suite()
        defaults.set(true, forKey: Self.experimentKey)

        let model = library(path, defaults: defaults)
        model.actArchive(.confirm(cooled.id))
        model.actArchive(.confirm(control.id))
        try await Wiring.settle { confirmedAt(path, cooled.id) != nil && confirmedAt(path, control.id) != nil }

        let until = try #require(ConfirmationCooldown().hiddenUntil(noteID: cooled.id, confirmedAt: now, exposure: .answerShown))
        #expect(try card(path, of: cooled.id).hiddenUntil == until)
        #expect(try card(path, of: control.id).hiddenUntil == nil, "the control arm was hidden too")
        let asked = try Ledger(path: path).dueCards(at: now, limit: 10, dictionary: nil, newAllowance: .max,
                                                   dayStart: .distantPast).map(\.noteID)
        #expect(asked == [control.id], "the cooled card is still offered, or the control is not")
    }

    /// **Saved's Confirm hides nothing, even with the experiment on.** It is offered over a selection
    /// whose answers the reader may never have opened.
    @Test func theSavedPanesConfirmHidesNothingEvenWithTheExperimentOn() async throws {
        let (path, clean) = Wiring.scratch("funnel-cooldown-saved")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try proposal(ledger, inCooldownArm: true, "fine")
        let defaults = TemporaryDefaults.suite()
        defaults.set(true, forKey: Self.experimentKey)

        let model = library(path, defaults: defaults)
        await model.reload()
        model.act(.select([note.id]))
        try await Wiring.settle { model.presentation.confirmable == [note.id] }
        model.act(.confirm)
        try await Wiring.settle { confirmedAt(path, note.id) != nil }
        #expect(try card(path, of: note.id).hiddenUntil == nil)
    }

    /// **A status, and the same status after a refresh.** An entry rung saved from the card said
    /// "Saved, with no meaning chosen yet"; the next ledger change read readiness instead and said
    /// "Saved, not confirmed yet" — of a note that was confirmed as it was saved. What it lacks is a
    /// meaning narrower than the entry, which is what the first sentence said.
    @Test func aSavedEntryStillSaysNoMeaningIsChosenAfterARefresh() async throws {
        let (path, clean) = Wiring.scratch("funnel-status")
        defer { clean() }
        let recorder = LookupRecorder()
        recorder.start { try LedgerStore(path: path) }
        await recorder.record(LookupRecording(
            record: LookupRecord(surface: "fine", lemma: "fine", context: "A fine day.", language: "en",
                                 lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil),
            encounter: nil, keepPolicy: .manual, primaryDictionary: "noad"), request: 1)
        // What `LookupCardView` enrols for an entry with no sense it can key.
        recorder.enrol(SenseEncounter(
            dictionary: DictionaryIdentity(name: "noad", identifier: "noad"), entryID: "e", senseKey: nil,
            senseKeyKind: .none, sensePath: nil, entrySenseCount: 2, senseHash: nil,
            gloss: "the leading definition", chosenBy: nil, chosenAt: now), request: 1, language: "en")
        await recorder.settled(request: 1)
        #expect(recorder.states[1] == .needsMeaning, "positive control: the save's own status")

        await recorder.refreshStatus(request: 1)
        #expect(recorder.states[1] == .needsMeaning)
    }
}
