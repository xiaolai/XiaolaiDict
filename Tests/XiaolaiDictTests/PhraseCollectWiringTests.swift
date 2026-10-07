import Capture
import CaptureModel
import DictionaryModel
import Foundation
import StudyKit
import StudyPresentation
import Testing
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictTestSupport
@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **Assert the wire** for *Save This Phrase* (ADR-0049): from the app's own hook, through the recorder
/// that knows which reading the card is, into the ledger — and back out as the control's state.
///
/// A ledger operation nothing calls is not a feature, and every test in `PhraseCollectionTests` would pass
/// over a button that reaches nothing. What is checked here is the path a press takes, at the seam the
/// app builds: the panel's hook set in `XiaolaiDictApp.init`, not a recorder a test wired by hand.
struct PhraseCollectWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "2.6")
    private static let spelling = "take something into account"
    private static let meaning = "consider something along with other factors before reaching a decision"

    private static let phrase = PhraseCollection(
        dictionary: noad, spelling: spelling, answer: meaning,
        filings: [PhraseFiling(dictionary: noad, parentEntryID: "m_en_gbus0005190",
                               blockID: "m_en_gbus0005190.081", definitions: [meaning],
                               contentVersion: "2.6:aa:bb", formatVersion: "phrases/6")],
        ownEntryKeys: [], isProposal: false)

    private func scratch() -> (String, () -> Void) {
        let path = ScratchFile.path("phrase")
        return (path, { ScratchFile.remove(path) })
    }

    private func recording(_ lemma: String = "take") -> LookupRecording {
        LookupRecording(record: LookupRecord(
            surface: lemma, lemma: lemma, context: "They took what people thought into account.",
            lemmaBasis: .tagger, language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil),
            encounter: nil)
    }

    /// How many readings there are: every one, kept or not, through the reading the drawer uses.
    private static func lookups(at path: String) throws -> Int {
        let ledger = try Ledger(path: path)
        return try ledger.readingArchiveCount(ReadingArchiveQuery(text: "", disposition: .kept))
            + ledger.readingArchiveCount(ReadingArchiveQuery(text: "", disposition: .discarded))
    }

    // MARK: - The app's own wire

    /// **The press the reader makes reaches the ledger through the hook the app sets**, keyed by the
    /// lookup's language like every other save, and writes a note — never a reading.
    @MainActor
    @Test func savingAPhraseFromThePanelWritesItsCardThroughTheAppsWire() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let suite = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                 models: .temporary(defaults: suite))
        app.recorder.start { try LedgerStore(path: path) }
        _ = try await #require(app.recorder.store).value
        await app.recorder.record(recording(), request: 1)
        #expect(try Self.lookups(at: path) == 1)

        let save = try #require(app.panelController.onCollectPhrase, "the phrase's Save reaches nothing")
        #expect(save(Self.phrase, 1), "the app refused a save it could make")
        await app.recorder.settled(request: 1)

        let notes = try Ledger(path: path).notes()
        #expect(notes.map(\.target) == [.phrase(dictionary: Self.noad.key, text: Self.spelling)])
        #expect(notes.map(\.issuer) == [.inventory])
        #expect(notes.map(\.language) == ["en"], "saved under \(notes.map(\.language)), not the lookup's language")
        #expect(try Self.lookups(at: path) == 1, "saving a phrase wrote a reading")
        #expect(app.recorder.phraseStates[1]?[Self.spelling] == .collected)
    }

    /// **A save made before the reading's row exists waits for its own row** — the race the sense tap
    /// lost once. Hung off whatever was recorded last, the card would be filed under the previous word.
    @Test func aSaveMadeBeforeItsRowExistsWaitsForItsOwnReading() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let recorder = await LookupRecorder()
        await recorder.start { try LedgerStore(path: path) }
        _ = try await #require(recorder.store).value

        #expect(await recorder.collect(Self.phrase, request: 7, language: "en"))
        #expect(await recorder.phraseStates[7]?[Self.spelling] == .collecting)
        await recorder.record(recording("hold"), request: 6)
        #expect(try Ledger(path: path).notes().isEmpty, "the save attached itself to another word")

        await recorder.record(recording(), request: 7)
        await recorder.settled(request: 7)
        let ledger = try Ledger(path: path)
        let note = try #require(try ledger.notes().first)
        let seven = try #require(try ledger.recentLookups(since: .distantPast, limit: 10, studying: [])
            .first { $0.surface == "take" })
        #expect(try ledger.lookupIDs(evidencing: note.id) == [seven.id])
        #expect(await recorder.phraseStates[7]?[Self.spelling] == .collected)
    }

    /// **Saving it again says so**, from another reading: one note, and the control says *already saved*.
    @Test func savingItAgainSaysAlreadySaved() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let recorder = await LookupRecorder()
        await recorder.start { try LedgerStore(path: path) }
        _ = try await #require(recorder.store).value
        await recorder.record(recording(), request: 1)
        await recorder.record(recording(), request: 2)
        _ = await recorder.collect(Self.phrase, request: 1, language: "en")
        await recorder.settled(request: 1)
        _ = await recorder.collect(Self.phrase, request: 2, language: "en")
        await recorder.settled(request: 2)
        #expect(try Ledger(path: path).notes().count == 1)
        #expect(await recorder.phraseStates[2]?[Self.spelling] == .alreadyCollected)
    }

    /// **A discarded reading refuses the save at once**, rather than taking the press and writing
    /// nothing: the control is told false and says the save did not happen.
    @Test func aDiscardedReadingRefusesTheSave() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let recorder = await LookupRecorder()
        await recorder.start { try LedgerStore(path: path) }
        _ = try await #require(recorder.store).value
        await recorder.record(recording(), request: 1)
        await recorder.discard(request: 1)
        await recorder.settled(request: 1)
        #expect(await recorder.collect(Self.phrase, request: 1, language: "en") == false)
        #expect(try Ledger(path: path).notes().isEmpty)
    }

    // MARK: - The view's half of the wire

    /// **The card reaches the hook under its own request, and reads its state back**: the panel forwards
    /// the environment's save to the controller and hands the card the recorder's states for its request.
    /// Read from the source because the hop is a view modifier, which no test can call.
    @Test func thePanelForwardsTheSaveUnderTheCardsOwnRequest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appending(path: path), encoding: .utf8)
        }
        let panel = try source("Sources/XiaolaiDict/LookupPanel.swift")
        #expect(panel.contains(".environment(\\.collectPhrase)"), "the card's Save is not wired to the panel")
        #expect(panel.contains("controller.onCollectPhrase"), "the panel does not hand the Save to the app")
        #expect(panel.contains(".environment(\\.phraseCollectStatuses"), "the card never hears what the save did")
        let notice = try source("Sources/XiaolaiDictUI/PhraseNotice.swift")
        #expect(notice.contains("collectPhrase(offered)"), "the control does not call the hook it is given")
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        #expect(app.contains("panel.onCollectPhrase = "), "the app never sets the panel's Save")
    }

    // MARK: - The card is offered it

    /// **A lookup's phrase arrives saveable, in the study dictionary.** The runner knows which dictionary
    /// this lookup studies from; the card does not, so the runner must hand it over with the phrase.
    @MainActor
    @Test func aLookupsPhraseArrivesSaveableInTheStudyDictionary() async throws {
        let panel = RecordingPanel()
        let word = DictionaryEntry(
            dictionary: Self.noad, headword: "take", lookedUp: "take", html: "<p/>",
            document: EntryDocument(isStyled: true, entryID: "take-1", homograph: nil, blocks: [SenseBlock(
                number: 1, partOfSpeech: "verb", senses: [DictionarySense(
                    path: SensePath(block: 1, ordinal: 1), key: "take-1.1", keyKind: .publisher,
                    definition: "lay hold of", text: "lay hold of")])]))
        let filing = PhraseFiling(dictionary: Self.noad, parentEntryID: "account-1", blockID: "account-1.081",
                                  definitions: [Self.meaning], contentVersion: "2.6:aa:bb",
                                  formatVersion: "phrases/6")
        let sentence = "They took it into account."
        let hit = PhraseHit(phrase: Self.spelling, location: 5, length: 20, separation: .marked(1),
                            meaning: PhraseMeaning(filings: [filing]))
        let runner = LookupRunner(
            client: DictionaryClient(connect: { _ in AnswersWithAPhrase(entry: word, hit: hit) }), panel: panel,
            primary: { PrimaryDictionary(chosen: Self.noad.key) }, selector: AbstainsFromChoosing())
        let selection = Selection(
            text: "took", sentence: sentence, rangeInSentence: NSRange(location: 5, length: 4),
            quality: .accessibility(.accessibilityTextRange, context: .complete), place: ReadingPlace())
        _ = await runner.run(selection, near: .zero, requestedAt: now, ticket: panel.newRequest())
        guard case .lookup(let shown)? = panel.updates.last else {
            Issue.record("the panel was never updated")
            return
        }
        #expect(shown.phrase?.collecting == .offered(PhraseCollection(
            dictionary: Self.noad, spelling: Self.spelling, answer: Self.meaning, filings: [filing],
            ownEntryKeys: [], isProposal: false)))
    }

    // MARK: - One phrase, one card (the final closing pass, finding 1)

    /// *That is a red herring.* — the reader hovers *herring*, and NOAD gives *red herring* an entry of its own.
    private static let herringSentence = "That is a red herring."
    private static let herringWord = DictionaryEntry(
        dictionary: noad, headword: "herring", lookedUp: "herring", html: "<p/>",
        document: EntryDocument(isStyled: true, entryID: "herring-1", homograph: nil, blocks: [SenseBlock(
            number: 1, partOfSpeech: "noun", senses: [DictionarySense(
                path: SensePath(block: 1, ordinal: 1), key: "herring-1.1", keyKind: .publisher,
                definition: "a silvery fish", text: "a silvery fish")])]))
    /// The phrase's own entry, two senses: the selector can pick the one the sentence means.
    private static let redHerring = DictionaryEntry(
        dictionary: noad, headword: "red herring", lookedUp: "red herring", html: "<p/>",
        document: EntryDocument(isStyled: true, entryID: "red-herring-1", homograph: nil, blocks: [SenseBlock(
            number: 1, partOfSpeech: "noun", senses: [
                DictionarySense(path: SensePath(block: 1, ordinal: 1), key: "red-herring-1.1", keyKind: .publisher,
                                definition: "a dried smoked herring", text: "a dried smoked herring"),
                DictionarySense(path: SensePath(block: 1, ordinal: 2), key: "red-herring-1.2", keyKind: .publisher,
                                definition: "a clue that is intended to mislead",
                                text: "a clue that is intended to mislead"),
            ])]))
    private static let ownEntryHit = PhraseHit(
        phrase: "red herring", location: 10, length: 11, separation: .none,
        meaning: PhraseMeaning(ownEntries: [redHerring]))
    /// What the ladder says when it reads the sentence as the phrase.
    private static let choosesThePhrase = Chooses(answer: .chose(key: "red-herring-1.2", margin: nil,
                                                                 entryID: "red-herring-1"))

    /// One hover of *herring*, through the runner the app builds and into the recorder it records with — the
    /// rows a lookup writes before and after its sense, as `XiaolaiDictApp.lookUp` writes them. Answers the
    /// card the panel was left with and the request it was drawn under.
    ///
    /// **One panel for every hover of a test**, as the app has one: its requests are numbered by it, and a
    /// panel per hover numbered each one 1 — the recorder's key — so the second hover reopened the first's
    /// reading instead of making its own.
    @MainActor
    private func hover(_ app: XiaolaiDictApp, on panel: RecordingPanel, word: DictionaryEntry = herringWord,
                       hit: PhraseHit = ownEntryHit, sentence: String = herringSentence,
                       term: NSRange = NSRange(location: 14, length: 7),
                       selector: some SenseSelecting) async throws -> (LookupPresentation, Int) {
        let runner = LookupRunner(
            client: DictionaryClient(connect: { _ in AnswersWithAPhrase(entry: word, hit: hit) }), panel: panel,
            primary: { PrimaryDictionary(chosen: Self.noad.key) }, selector: selector,
            keepPolicy: { .automatic },
            initialRecording: { [recorder = app.recorder] row, request in recorder.begin(row, request: request) })
        let selection = Selection(
            text: (sentence as NSString).substring(with: term), sentence: sentence, rangeInSentence: term,
            quality: .accessibility(.accessibilityTextRange, context: .complete), place: ReadingPlace())
        let ticket = panel.newRequest()
        let row = try #require(await runner.run(selection, near: .zero, requestedAt: now, ticket: ticket))
        await app.recorder.record(row, request: ticket.number)
        guard case .lookup(let shown)? = panel.updates.last else {
            Issue.record("the panel was never updated")
            throw CancellationError()
        }
        return (shown, ticket.number)
    }

    /// The app, its recorder on a scratch ledger.
    @MainActor
    private func app(at path: String) async throws -> XiaolaiDictApp {
        let suite = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                 models: .temporary(defaults: suite))
        app.recorder.start { try LedgerStore(path: path) }
        _ = try await #require(app.recorder.store).value
        return app
    }

    /// *Save This Phrase* on the card the reader was shown, through the app's own hook.
    @MainActor
    private func save(_ shown: LookupPresentation, request: Int, in app: XiaolaiDictApp) async throws {
        guard case .offered(let phrase)? = shown.phrase?.collecting else {
            Issue.record("the card offered no save: \(String(describing: shown.phrase?.collecting))")
            throw CancellationError()
        }
        let save = try #require(app.panelController.onCollectPhrase)
        #expect(save(phrase, request), "the app refused a save it could make")
        await app.recorder.settled(request: request)
    }

    /// Every note that stands for *red herring*: the phrase card, and any note on its own entry.
    private static func herringNotes(at path: String) throws -> [StudyNote] {
        try Ledger(path: path).notes().filter { note in
            switch note.target {
            case .phrase(_, let text): text == "red herring"
            case .sense(_, let entry, _, _), .entry(_, let entry): entry == "red-herring-1"
            case .custom: false
            }
        }
    }

    /// **Kept automatically as its entry's sense, then saved: one card.** The ladder reads *herring* as the
    /// phrase and automatic keeping keeps that sense of the phrase's own entry — what it always did (ADR-0028).
    /// The reader then presses *Save This Phrase*: the card it would make already exists, so the save says so
    /// and writes nothing — not a second card for the same phrase, one of them made without a gesture.
    @MainActor
    @Test func aPhraseKeptAsItsOwnEntrysSenseIsAlreadySaved() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let app = try await app(at: path)
        let (shown, request) = try await hover(app, on: RecordingPanel(), selector: Self.choosesThePhrase)
        let kept = try Self.herringNotes(at: path)
        #expect(kept.map(\.target) == [.sense(dictionary: Self.noad.key, entryID: "red-herring-1",
                                              senseKey: "red-herring-1.2", senseKeyKind: .publisher)],
                "premise: automatic keeping kept the phrase's own entry's sense")

        try await save(shown, request: request, in: app)
        let after = try Self.herringNotes(at: path)
        #expect(after.map(\.id) == kept.map(\.id), "a second card for one phrase: \(after.map(\.target))")
        #expect(app.recorder.phraseStates[request]?["red herring"] == .alreadyCollected)
    }

    /// **Saved first, then met again: still one card.** The reader saves the phrase from a hover the selector
    /// could not decide; the next hover's ladder reads the phrase, and automatic keeping must not add its
    /// entry's sense beside the card the reader made.
    @MainActor
    @Test func aSavedPhraseIsNotKeptAgainAsItsOwnEntrysSense() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let app = try await app(at: path)
        let panel = RecordingPanel()
        let (first, request) = try await hover(app, on: panel, selector: AbstainsFromChoosing())
        try await save(first, request: request, in: app)
        let saved = try Self.herringNotes(at: path)
        #expect(saved.map(\.target) == [.phrase(dictionary: Self.noad.key, text: "red herring")],
                "premise: the save made the phrase card")

        let (_, again) = try await hover(app, on: panel, selector: Self.choosesThePhrase)
        #expect(again != request, "premise: the second hover is a request of its own")
        let after = try Self.herringNotes(at: path)
        #expect(after.map(\.id) == saved.map(\.id), "a second card for one phrase: \(after.map(\.target))")
        // **The reading still records what the ladder chose**: only the card is not made twice.
        let ledger = try Ledger(path: path)
        let met = try ledger.recentLookups(since: .distantPast, limit: 10, studying: [.latin])
            .flatMap { try ledger.encounters(ofLookup: $0.id) }
        #expect(met.contains { $0.entryID == "red-herring-1" && $0.senseKey == "red-herring-1.2" },
                "the sense the ladder chose was not recorded on the reading")
        #expect(app.recorder.phraseStates[again]?["red herring"] == .alreadyCollected,
                "the card does not say the phrase it drew is saved already")
    }

    /// **A phrase filed inside another word's entry has no entry of its own to keep**: automatic keeping keeps
    /// the word, Save makes the phrase card, and nothing else stands for the phrase — not its parent's entry.
    @MainActor
    @Test func aPhraseFiledInsideAnotherWordIsACardOnlyWhenSaved() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let app = try await app(at: path)
        let take = DictionaryEntry(
            dictionary: Self.noad, headword: "take", lookedUp: "take", html: "<p/>",
            document: EntryDocument(isStyled: true, entryID: "take-1", homograph: nil, blocks: [SenseBlock(
                number: 1, partOfSpeech: "verb", senses: [
                    DictionarySense(path: SensePath(block: 1, ordinal: 1), key: "take-1.1", keyKind: .publisher,
                                    definition: "lay hold of", text: "lay hold of"),
                    DictionarySense(path: SensePath(block: 1, ordinal: 2), key: "take-1.2", keyKind: .publisher,
                                    definition: "consider", text: "consider"),
                ])]))
        let filing = PhraseFiling(dictionary: Self.noad, parentEntryID: "account-1", blockID: "account-1.081",
                                  definitions: [Self.meaning], contentVersion: "2.6:aa:bb", formatVersion: "phrases/6")
        let filed = PhraseHit(phrase: Self.spelling, location: 5, length: 20, separation: .marked(1),
                              meaning: PhraseMeaning(filings: [filing]))
        func phraseNotes() throws -> [StudyNote] {
            try Ledger(path: path).notes().filter { note in
                switch note.target {
                case .phrase(_, let text): text == Self.spelling
                case .sense(_, let entry, _, _), .entry(_, let entry): entry == "account-1"
                case .custom: false
                }
            }
        }
        let read = (sentence: "They took it into account.", term: NSRange(location: 5, length: 4))
        let choosesTheWord = Chooses(answer: .chose(key: "take-1.2", margin: nil, entryID: "take-1"))
        let panel = RecordingPanel()
        let (shown, request) = try await hover(app, on: panel, word: take, hit: filed, sentence: read.sentence,
                                               term: read.term, selector: choosesTheWord)
        #expect(try phraseNotes().isEmpty, "automatic keeping made a card for a phrase nobody saved")
        #expect(try Ledger(path: path).notes().map(\.target).contains(
                    .sense(dictionary: Self.noad.key, entryID: "take-1", senseKey: "take-1.2", senseKeyKind: .publisher)),
                "premise: automatic keeping kept the word")

        try await save(shown, request: request, in: app)
        #expect(try phraseNotes().map(\.target) == [.phrase(dictionary: Self.noad.key, text: Self.spelling)])
        _ = try await hover(app, on: panel, word: take, hit: filed, sentence: read.sentence, term: read.term,
                            selector: choosesTheWord)
        #expect(try phraseNotes().map(\.target) == [.phrase(dictionary: Self.noad.key, text: Self.spelling)],
                "a later hover added a card for the phrase")
    }
}

/// A selector that always gives the same answer, so what the runner and the recorder do with it is under test.
private struct Chooses: SenseSelecting {
    let answer: SenseSelection
    func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection { answer }
}

private struct AnswersWithAPhrase: DictionaryTransport {
    let entry: DictionaryEntry
    let hit: PhraseHit
    func send(_ request: ServiceRequest) async throws -> ServiceReply {
        .lookup(LookupAnswer(word: .entries(NonEmpty([entry])!, unreadable: []), phrase: .found([hit])))
    }
    func cancel(reason: String) {}
}

private struct AbstainsFromChoosing: SenseSelecting {
    func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection { .abstained(.tooClose) }
}
