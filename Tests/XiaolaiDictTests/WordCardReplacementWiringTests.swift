import DictionaryModel
import Foundation
import ReviewKit
@testable import StudyKit
@testable import StudyModels
import StudyPresentation
import Testing
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **"When I choose a meaning for a word I saved, replace the word-only card with it"** — R1b, a
/// reader option in Settings › General › Study, off by default.
///
/// At the real seam: History's Choose a Meaning hands `LookupRecorder` the reading's own identity and
/// the reader taps a sense, exactly as `FunnelWiringTests.choosingAMeaningFromHistoryRetiresOrKeepsTheEntryNote`
/// pins it for the option off. On, the ledger's `replaceWordCards` runs in the same transaction as the
/// keep, and the card says what became of the word-only card.
@MainActor
struct WordCardReplacementWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let noad = DictionaryIdentity(name: "noad", identifier: "noad")

    private var first: LookupRecording {
        LookupRecording(
            record: LookupRecord(surface: "fine", lemma: "fine", context: "A fine day.", language: "en",
                                 lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil),
            encounter: SenseEncounter(
                dictionary: Self.noad, entryID: "e", senseKey: nil, senseKeyKind: .none, sensePath: nil,
                entrySenseCount: 2, senseHash: nil, gloss: nil, chosenBy: nil, chosenAt: nil),
            keepPolicy: .manual, primaryDictionary: "noad")
    }

    private var tapped: SenseEncounter {
        SenseEncounter(dictionary: Self.noad, entryID: "e", senseKey: "e.1", senseKeyKind: .publisher,
                       sensePath: nil, entrySenseCount: 2, senseHash: "h", gloss: "a sum paid as a penalty",
                       chosenBy: .reader, chosenAt: now)
    }

    private func suite(replacing: Bool) -> UserDefaults {
        let suite = TemporaryDefaults.suite()
        if replacing { WordCardReplacementSetting(defaults: suite).save(true) }
        return suite
    }

    /// The word the reader saved from History — `ArchiveAction.keep`, through the store the app uses —
    /// with an answer of their own and a tag, as Saved lets them give it.
    private func savedWord(_ recorder: LookupRecorder, _ path: String, answer: String? = "a penalty",
                           tags: [String] = ["law"]) async throws -> StudyNote {
        await recorder.record(first, request: 1)
        _ = try #require(try await recorder.store?.value.keepHistory(1))
        let ledger = try Ledger(path: path)
        let word = try #require(try ledger.notes().first)
        #expect(word.target == .entry(dictionary: "noad", entryID: "e"), "the premise: a word-only card")
        if let answer { try ledger.setReaderAnswer(answer, of: word.id, at: now) }
        for tag in tags { try ledger.tag(noteID: word.id, tag) }
        return word
    }

    /// Choose a Meaning: the reading reopened by its identity, and a sense tapped on it.
    private func chooseAMeaning(_ recorder: LookupRecorder, _ path: String, request: Int = 2) async throws {
        let reading = try #require(try Ledger(path: path).reading(ofLookup: 1))
        await recorder.record(LookupRecording(record: first.record.pending(), encounter: nil, lookup: reading.identity,
                                              keepPolicy: first.keepPolicy), request: request)
        recorder.study(tapped, request: request)
        await recorder.settled(request: request)
    }

    private func meaning(_ path: String) throws -> StudyNote? {
        try Ledger(path: path).notes().first { if case .sense = $0.target { true } else { false } }
    }

    private func enrollment(_ path: String, _ id: UUID) throws -> StudyEnrollment? {
        try Ledger(path: path).enrollments(ofNotes: [id])[id]
    }

    // MARK: - Off: today

    /// **Off by default, and off is today.** A recorder given the reader's suite with nothing in it
    /// keeps both cards, exactly as the pinned WI-4 test records.
    @Test func offTheSavedWordCardStaysBesideTheMeaning() async throws {
        let (path, clean) = Wiring.scratch("wordcard-off")
        defer { clean() }
        let recorder = LookupRecorder(wordCards: WordCardReplacementSetting(defaults: suite(replacing: false)))
        recorder.start { try LedgerStore(path: path) }
        let word = try await savedWord(recorder, path)
        try await chooseAMeaning(recorder, path)

        let sense = try #require(try meaning(path))
        #expect(try enrollment(path, word.id) == .active)
        #expect(try Ledger(path: path).answer(of: sense.id)?.origin == .dictionary)
        #expect(try Ledger(path: path).tags(of: sense.id).isEmpty)
        #expect(recorder.states[2] == .kept)
    }

    // MARK: - On

    /// **On: the meaning takes the word's answer and tags, the word-only card is archived, and the card
    /// says so** — and goes on saying so after the refresh every ledger change starts.
    @Test func onChoosingAMeaningReplacesTheSavedWordCard() async throws {
        let (path, clean) = Wiring.scratch("wordcard-on")
        defer { clean() }
        let recorder = LookupRecorder(wordCards: WordCardReplacementSetting(defaults: suite(replacing: true)))
        recorder.start { try LedgerStore(path: path) }
        let word = try await savedWord(recorder, path, answer: "a penalty, like a parking one", tags: ["law", "money"])
        try await chooseAMeaning(recorder, path)

        let ledger = try Ledger(path: path)
        let sense = try #require(try meaning(path))
        #expect(try ledger.answer(of: sense.id) == StudyAnswer(origin: .reader, text: "a penalty, like a parking one"))
        #expect(try ledger.tags(of: sense.id) == ["law", "money"])
        #expect(try ledger.readiness(of: sense.id) == .ready)
        #expect(try enrollment(path, word.id) == .archived, "the word-only card is still in study")
        #expect(try ledger.lookupIDs(evidencing: word.id) == [1], "archiving took the word-only card's reading")
        #expect(recorder.states[2] == .replacedWordCard)

        await recorder.refreshStatus(request: 2)
        #expect(recorder.states[2] == .replacedWordCard, "a refresh forgot what became of the word-only card")
    }

    /// **A word-only card with reviews is kept beside the meaning, and the card says why.**
    @Test func onAReviewedWordCardIsKeptAndTheCardSaysSo() async throws {
        let (path, clean) = Wiring.scratch("wordcard-reviewed")
        defer { clean() }
        let recorder = LookupRecorder(wordCards: WordCardReplacementSetting(defaults: suite(replacing: true)))
        recorder.start { try LedgerStore(path: path) }
        let word = try await savedWord(recorder, path)
        let ledger = try Ledger(path: path)
        let card = try ledger.card(of: word.id, at: now)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: card.revision, at: now,
                             using: try MemoryScheduler())
        try await chooseAMeaning(recorder, path)

        let sense = try #require(try meaning(path))
        #expect(try enrollment(path, word.id) == .active, "a reviewed word-only card was retired")
        #expect(try ledger.answer(of: sense.id)?.origin == .dictionary, "the meaning took half a merge")
        #expect(try ledger.tags(of: sense.id).isEmpty)
        #expect(recorder.states[2] == .keptReviewedWordCard)
        await recorder.refreshStatus(request: 2)
        #expect(recorder.states[2] == .keptReviewedWordCard)
    }

    /// **A damaged word-only card fails the choice as a whole**: no meaning saved over a card still
    /// standing, nothing archived, and Retry on the card — the failure is the reader's to see.
    @Test func onADamagedWordCardFailsTheChoiceAndChangesNothing() async throws {
        let (path, clean) = Wiring.scratch("wordcard-damaged")
        defer { clean() }
        let recorder = LookupRecorder(wordCards: WordCardReplacementSetting(defaults: suite(replacing: true)))
        recorder.start { try LedgerStore(path: path) }
        let word = try await savedWord(recorder, path)
        try Ledger(path: path).execute("""
            PRAGMA ignore_check_constraints = ON;
            UPDATE study_answers SET origin = 'scribble' WHERE note_id = '\(word.id.uuidString)';
            PRAGMA ignore_check_constraints = OFF;
            """)
        try await chooseAMeaning(recorder, path)

        #expect(recorder.states[2] == .failed)
        #expect(try meaning(path) == nil, "the meaning was saved without what it was meant to replace")
        #expect(try enrollment(path, word.id) == .active)
    }

    /// **Choosing the same meaning again changes nothing** — a second Choose a Meaning, or a Retry.
    @Test func choosingTheSameMeaningAgainChangesNothing() async throws {
        let (path, clean) = Wiring.scratch("wordcard-twice")
        defer { clean() }
        let recorder = LookupRecorder(wordCards: WordCardReplacementSetting(defaults: suite(replacing: true)))
        recorder.start { try LedgerStore(path: path) }
        _ = try await savedWord(recorder, path)
        try await chooseAMeaning(recorder, path, request: 2)
        let once = try Self.state(path)
        try await chooseAMeaning(recorder, path, request: 3)
        #expect(try Self.state(path) == once, "choosing the same meaning again wrote again")
    }

    /// **An automatic draft is retired as it is today**, option on or off: `keep` unlinks it from the
    /// reading, so it is no word-only card of this reading, and nothing archives it.
    @Test func onAnAutomaticDraftIsRetiredAsBefore() async throws {
        let (path, clean) = Wiring.scratch("wordcard-draft")
        defer { clean() }
        let recorder = LookupRecorder(wordCards: WordCardReplacementSetting(defaults: suite(replacing: true)))
        recorder.start { try LedgerStore(path: path) }
        let automatic = LookupRecording(record: first.record, encounter: first.encounter, keepPolicy: .automatic,
                                        primaryDictionary: "noad")
        await recorder.record(automatic, request: 1)
        let draft = try #require(try Ledger(path: path).notes().first)
        try await chooseAMeaning(recorder, path)

        #expect(try Ledger(path: path).lookupIDs(evidencing: draft.id).isEmpty, "the draft kept its link")
        #expect(try enrollment(path, draft.id) == .active, "the option archived a draft nobody saved")
        #expect(recorder.states[2] == .kept)
    }

    // MARK: - The app's wire

    /// **The switch in Settings is what the app's recorder reads.** Through the choice Settings draws,
    /// in the suite the app was given — and a control with the default suite keeps both cards.
    @Test func theAppsRecorderReadsTheSettingsSwitch() async throws {
        for replacing in [false, true] {
            let (path, clean) = Wiring.scratch("wordcard-app")
            defer { clean() }
            let suite = TemporaryDefaults.suite()
            let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                     models: .temporary(defaults: suite), reminders: FakeReminderCenter())
            #expect(!app.studyOptions.choice.replacesWordCards, "the option is on by default")
            if replacing { app.studyOptions.choice.setReplacesWordCards(true) }
            #expect(app.studyOptions.choice.replacesWordCards == replacing)
            app.lookupRecorder.start { try LedgerStore(path: path) }
            let word = try await savedWord(app.lookupRecorder, path)
            try await chooseAMeaning(app.lookupRecorder, path)
            #expect(try enrollment(path, word.id) == (replacing ? .archived : .active),
                    "with the switch \(replacing ? "on" : "off")")
        }
    }

    /// Every note's enrollment, answer, tags and links — what a second application must leave alone.
    private static func state(_ path: String) throws -> [String] {
        let ledger = try Ledger(path: path)
        return try ledger.notes().map { note in
            let answer = try ledger.answer(of: note.id)
            return "\(note.id) \(note.enrollment) \(answer?.origin.rawValue ?? "-") \(answer?.text ?? "-") "
                + "\(try ledger.tags(of: note.id)) \(try ledger.lookupIDs(evidencing: note.id)) "
                + "\(try ledger.existingCard(of: note.id)?.revision ?? -1)"
        }
    }
}
