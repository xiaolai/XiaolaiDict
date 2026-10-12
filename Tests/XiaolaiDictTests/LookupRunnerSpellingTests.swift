import Capture
import CaptureModel
import DictionaryModel
import Foundation
import MacCapture
import StudyKit
import Synchronization
@testable import StudyModels
import Testing
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictTestSupport
@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **"Look up “X”" as `LookupRunner` delivers it** (plan-spelling-suggestion §3–§4): the miss is on the card first,
/// and final-looking; the line arrives after, only once the dictionaries have the word; a lookup the reader has moved on
/// from draws no line and offers nothing to follow — through the real `DictionaryClient`, over a transport that answers
/// from a word list and counts what it was asked.
@MainActor
struct LookupRunnerSpellingTests {
    /// What the reader selected: a typo, inside the sentence it was read in — **a sentence `NLLanguageRecognizer` reads
    /// as Catalan** (0.37, measured 2026-10-09), because of the typo. A refusal by the sentence's language was tried and
    /// refused this, the case the feature exists for; these tests are what would see it come back.
    static let typo = Selection(
        text: "teh", sentence: "I saw teh cat.", rangeInSentence: NSRange(location: 6, length: 3),
        quality: .accessibility(.accessibilityTextRange, context: .complete),
        place: ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"))

    static let the = SpellingSuggestion(term: "teh", word: "the", evidence: .correction(.transposition))

    private static func selection(_ text: String, in sentence: String? = nil) -> Selection {
        Selection(text: text, sentence: sentence, rangeInSentence: nil,
                  quality: .accessibility(.accessibilityTextRange, context: .complete), place: ReadingPlace())
    }

    /// A checker that answers from a table — once released, where a test holds it — and counts what it was asked.
    final class Checker: SpellingSuggesting {
        private let answers: [String: String]
        private let state = Mutex((asked: [String](), held: false))
        /// One element each time the checker is asked — **the event, never a clock**: a bounded wait of two seconds was
        /// outrun by a full parallel suite, where this runner shares the main actor with every other test's.
        private let asked: AsyncStream<Void>
        private let ask: AsyncStream<Void>.Continuation
        init(_ answers: [String: String], held: Bool = false) {
            self.answers = answers
            (asked, ask) = AsyncStream<Void>.makeStream()
            state.withLock { $0.held = held }
        }
        var questions: [String] { state.withLock { $0.asked } }
        func release() { state.withLock { $0.held = false } }
        func suggestion(for term: String, language: String?) async -> String? {
            state.withLock { $0.asked.append(term) }
            ask.yield()
            if await !Patience.until(every: .milliseconds(2), { !state.withLock({ $0.held }) }), !Task.isCancelled {
                Issue.record("the checker was never released")
            }
            return answers[term]
        }
        /// Returns once the checker has been asked — at once where it already was. A checker never asked is held to the
        /// test's own time limit, which fails it by name rather than hanging the run.
        func waitUntilAsked() async {
            for await _ in asked { return }
        }
    }

    /// The dictionary service, answering the words it has and missing every other — and counting every word it is
    /// asked about, which is how a verification lookup that should not have happened is seen.
    final class Service: DictionaryTransport {
        let words: Set<String>
        /// Whether each entry has two senses — the least that makes the sense selector be asked at all.
        let twoSenses: Bool
        private let asked = Mutex<[String]>([])
        init(_ words: Set<String>, twoSenses: Bool = false) {
            self.words = words
            self.twoSenses = twoSenses
        }
        var questions: [String] { asked.withLock { $0 } }
        func send(_ request: ServiceRequest) async throws -> ServiceReply {
            guard case .lookup(let lookup) = request else { return .dictionaries([]) }
            asked.withLock { $0.append(lookup.term) }
            guard words.contains(lookup.term) else { return .lookup(LookupAnswer(word: .notFound)) }
            let document = twoSenses ? EntryDocument(
                isStyled: true, entryID: "m1", homograph: nil,
                blocks: [SenseBlock(number: 1, partOfSpeech: "noun", senses: [1, 2].map {
                    DictionarySense(path: SensePath(block: 1, ordinal: $0), key: "m1.00\($0)", keyKind: .publisher,
                                    definition: "meaning \($0)", text: "meaning \($0)")
                })]) : nil
            let entry = DictionaryEntry(
                dictionary: DictionaryIdentity(name: "NOAD", identifier: "com.apple.dictionary.NOAD"),
                headword: lookup.term, lookedUp: lookup.term, html: "<p/>", document: document)
            return .lookup(LookupAnswer(word: .entries(NonEmpty([entry])!, unreadable: [])))
        }
        func cancel(reason: String) {}
    }

    /// A selector that abstains, and remembers the part of speech each question came with.
    final class PartOfSpeechSelector: SenseSelecting {
        private let given = Mutex<[String?]>([])
        var partsOfSpeech: [String?] { given.withLock { $0 } }
        func choose(
            from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
            partOfSpeech: String?
        ) async -> SenseSelection {
            given.withLock { $0.append(partOfSpeech) }
            return .abstained(.tooClose)
        }
    }

    private func runner(_ panel: RecordingPanel, _ service: Service, _ checker: Checker) -> LookupRunner {
        LookupRunner(
            client: DictionaryClient(deadline: Patience.wait, connect: { _ in service }, fallback: { _ in nil }), panel: panel,
            spelling: checker, readerEnglish: { nil })
    }

    private static func lookups(_ contents: [PanelContent]) -> [LookupPresentation] {
        contents.compactMap { content -> LookupPresentation? in
            guard case .lookup(let presentation) = content else { return nil }
            return presentation
        }
    }

    /// **The miss first, final-looking; the line after, once verified** (§3). While the checker is still answering, the
    /// card already holds the miss and no line; once the dictionaries have the word, the same card gains it.
    @Test(.timeLimit(.minutes(Patience.limitMinutes))) func theMissIsShownFirstAndItsVerifiedSuggestionArrivesAfter() async throws {
        let panel = RecordingPanel(), service = Service(["the"]), checker = Checker(["teh": "the"], held: true)
        let runner = runner(panel, service, checker)
        let ticket = panel.newRequest()
        let lookup = Task { await runner.run(Self.typo, near: .zero, requestedAt: .now, ticket: ticket) }
        await checker.waitUntilAsked()

        let beforeTheLine = try #require(Self.lookups(panel.updates).last, "the miss was not on the card")
        #expect(beforeTheLine.outcome == .notFound(serviceFailure: nil))
        #expect(beforeTheLine.suggestion == nil, "a line was drawn before the checker answered")

        checker.release()
        let recording = await lookup.value
        let shown = Self.lookups(panel.updates)
        #expect(shown.last?.suggestion == Self.the, "the verified suggestion never reached the card")
        #expect(shown.last?.outcome == .notFound(serviceFailure: nil), "the line replaced the miss")
        #expect(checker.questions == ["teh"])
        #expect(service.questions == ["teh", "the"], "the word was not verified before it was offered")
        // **Never automatic**: the line is offered, and nothing looks the word up in the reader's place — the one panel
        // shown is the miss's own, and the only lookup of the word was the verification.
        #expect(panel.contents.count == 1, "a suggestion opened a panel of its own")
        // **The miss stays a miss** — the row the reader's ledger gets is the miss, whatever was suggested under it.
        #expect(recording?.record.result == .notFound)
        #expect(recording?.record.surface == "teh")
    }

    /// **The dictionary form, where the checker has nothing** (plan-card-refinements WI-3): the lemma the lookup already
    /// worked out, verified against the dictionaries, offered as a line of its own kind — and nothing looked up in the
    /// reader's place.
    ///
    /// *cat*'s entry is a noun's (`twoSenses` gives it a noun block), which is what licenses *cats* as its regular plural
    /// (D1, 2026-10-10): a dictionary form is offered only where its own entry could inflect so.
    @Test func aMissedInflectionIsOfferedItsVerifiedDictionaryForm() async {
        let panel = RecordingPanel(), service = Service(["cat"], twoSenses: true), checker = Checker([:])
        let cats = Selection(
            text: "cats", sentence: "The cats sat on the mat.", rangeInSentence: NSRange(location: 4, length: 4),
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            place: ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"))
        let recording = await runner(panel, service, checker).run(cats, near: .zero, requestedAt: .now, ticket: panel.newRequest())
        #expect(Self.lookups(panel.updates).last?.suggestion
                == SpellingSuggestion(term: "cats", word: "cat", evidence: .regular(.s)))
        #expect(service.questions == ["cats", "cat"], "the dictionary form was not verified before it was offered")
        #expect(panel.contents.count == 1, "the dictionary form opened a panel of its own")
        #expect(recording?.record.result == .notFound, "the miss stopped being a miss")
    }

    /// **Verify before offering**: a correction no dictionary of the reader's has never reaches the card.
    @Test func aSuggestionNoDictionaryHasIsNeverShown() async {
        let panel = RecordingPanel(), service = Service([]), checker = Checker(["teh": "the"])
        _ = await runner(panel, service, checker).run(Self.typo, near: .zero, requestedAt: .now, ticket: panel.newRequest())
        #expect(Self.lookups(panel.updates).allSatisfy { $0.suggestion == nil })
        #expect(service.questions == ["teh", "the"], "the correction was never put to the dictionaries")
    }

    /// **Only the service's own miss of one Latin word asks the checker**: a found word, a fallback's prose, a miss the
    /// service could not answer, a phrase and CJK are offered nothing, and the checker never hears of them.
    @Test func nothingButAMissOfOneLatinWordAsksTheChecker() async {
        // A service that answers is given `Patience.wait`, and one that never does the short deadline it is about: the
        // 50 ms all five had was a deadline the answering services missed on a loaded Mac, turning a found word and a
        // miss into "the service could not answer" — a case this test lists separately.
        let answers = Patience.wait, never = Duration.milliseconds(50)
        let cases: [(Selection, DictionaryClient.Connect, Duration, String?)] = [
            (Self.selection("the", in: "I saw the cat."), { _ in Service(["the"]) }, answers, nil),
            (Self.selection("teh"), { _ in NeverReplies() }, never, "an article"),
            (Self.selection("teh"), { _ in NeverReplies() }, never, nil),
            (Self.selection("teh cat", in: "I saw teh cat."), { _ in Service([]) }, answers, nil),
            (Self.selection("水", in: "我看见水。"), { _ in Service([]) }, answers, nil),
        ]
        for (selection, connect, deadline, fallback) in cases {
            let panel = RecordingPanel(), checker = Checker(["teh": "the", "the": "they", "水": "the"])
            let runner = LookupRunner(
                client: DictionaryClient(deadline: deadline, connect: connect, fallback: { _ in fallback }),
                panel: panel, spelling: checker, readerEnglish: { nil })
            _ = await runner.run(selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())
            #expect(checker.questions.isEmpty, "\(selection.text) asked the checker")
            #expect(Self.lookups(panel.updates).allSatisfy { $0.suggestion == nil }, "\(selection.text) was offered a line")
            #expect(!Self.lookups(panel.updates).isEmpty, "\(selection.text) never reached the card, so nothing was tested")
        }
    }

    /// **A newer lookup cancels a pending suggestion** (§4): the reader pressed again while the checker answered, so the
    /// task was cancelled — no line lands on any card, the dictionaries are never asked to verify, and nothing is left
    /// to follow.
    @Test(.timeLimit(.minutes(Patience.limitMinutes))) func aNewerLookupCancelsAPendingSuggestion() async throws {
        let panel = RecordingPanel(), service = Service(["the"]), checker = Checker(["teh": "the"], held: true)
        let runner = runner(panel, service, checker)
        let ticket = panel.newRequest()
        let lookup = Task { await runner.run(Self.typo, near: .zero, requestedAt: .now, ticket: ticket) }
        await checker.waitUntilAsked()
        _ = panel.newRequest()
        lookup.cancel()
        checker.release()
        _ = await lookup.value
        #expect(Self.lookups(panel.updates).allSatisfy { $0.suggestion == nil })
        #expect(service.questions == ["teh"], "a cancelled suggestion was still verified: \(service.questions)")
        #expect(runner.followUp(Self.the, from: ticket.number) == nil)
    }

    /// **A lookup the reader moved on from, though nobody cancelled it, offers nothing to follow.** A hover's claim
    /// supersedes without cancelling, so the runner's own question — is this still the card on screen? — is what keeps
    /// a late line off a card it was not made for, and a press on a stale card from looking anything up.
    @Test(.timeLimit(.minutes(Patience.limitMinutes))) func aSupersededLookupKeepsNoSuggestion() async throws {
        let panel = RecordingPanel(), service = Service(["the"]), checker = Checker(["teh": "the"], held: true)
        let runner = runner(panel, service, checker)
        let ticket = panel.newRequest()
        let lookup = Task { await runner.run(Self.typo, near: .zero, requestedAt: .now, ticket: ticket) }
        await checker.waitUntilAsked()
        _ = panel.newRequest()
        checker.release()
        _ = await lookup.value
        #expect(Self.lookups(panel.updates).allSatisfy { $0.suggestion == nil })
        #expect(runner.followUp(Self.the, from: ticket.number) == nil, "a suggestion was kept for a card no longer shown")
    }

    /// **The term again, up to case, is no line** (§3) — the checker answered, and the dictionaries were never asked to
    /// verify a word the reader already looked up.
    @Test func aCorrectionThatIsTheTermAgainDrawsNoLine() async {
        let panel = RecordingPanel(), service = Service(["TEH"]), checker = Checker(["teh": "TEH"])
        _ = await runner(panel, service, checker).run(Self.typo, near: .zero, requestedAt: .now, ticket: panel.newRequest())
        #expect(checker.questions == ["teh"], "the checker was not asked, so nothing was tested")
        #expect(Self.lookups(panel.updates).allSatisfy { $0.suggestion == nil })
        #expect(service.questions == ["teh"], "the term itself was looked up again as its own correction")
    }

    /// **A followed correction is not in the reader's sentence, and nothing may look for it there** (audit, 2026-10-09).
    /// "They record it, and the recrod shows." holds *record* once — the verb, not the noun the reader misspelt — so a
    /// search for the word binds the correction to it: the card marked it, and the selector was told "verb". The
    /// follow-up's placement says it is in no position of the sentence, the card is told so, and the word is tagged
    /// alone.
    @Test func aFollowedCorrectionIsNeverBoundToAnotherOccurrenceOfIt() async throws {
        let sentence = "They record it, and the recrod shows."
        let bound = Lemmatizer.partOfSpeech(of: "record", in: sentence, at: nil)
        let alone = Lemmatizer.partOfSpeech(of: "record", in: nil, at: nil)
        try #require(bound != alone, "the fixture no longer tells the other occurrence from the word: \(String(describing: bound))")
        let typo = Selection(
            text: "recrod", sentence: sentence, rangeInSentence: (sentence as NSString).range(of: "recrod"),
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            place: ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"))
        let panel = RecordingPanel(), selector = PartOfSpeechSelector()
        let runner = LookupRunner(
            client: DictionaryClient(deadline: Patience.wait, connect: { _ in Service(["record"], twoSenses: true) }, fallback: { _ in nil }),
            panel: panel, selector: selector, spelling: Checker(["recrod": "record"]), readerEnglish: { nil })
        let missed = panel.newRequest()
        _ = await runner.run(typo, near: .zero, requestedAt: .now, ticket: missed)
        let followed = try #require(runner.followUp(SpellingSuggestion(term: "recrod", word: "record", evidence: .correction(.transposition)),
                                                       from: missed.number))

        _ = await runner.run(followed, near: .zero, requestedAt: .now, ticket: panel.newRequest(), placement: .notInSentence)
        let shown = try #require(Self.lookups(panel.updates).last)
        #expect(shown.term == "record")
        #expect(shown.sentence == sentence, "the reader's sentence did not go with the word")
        #expect(shown.termPlacement == .notInSentence, "the card was not told the word is not in the sentence")
        #expect(selector.partsOfSpeech == [alone], "the word was tagged as the sentence's other occurrence")
    }

    /// **A followed correction is recorded as a word the reader named, without the sentence it is not in** (audit round
    /// 2, 2026-10-09). The ledger keeps where `surface` sits in `context` and nothing that says a word is in no position
    /// of it, so a correction recorded with the reader's sentence and no range came back as an unrecorded range — and
    /// reopened, the card searched again and marked another occurrence. Recorded the way a named word already is —
    /// itself as its context, the context `missing` ("none consistent with the selection"), source and confidence kept
    /// — it reopens with no sentence to search. The miss it came from keeps its sentence: that word was in it.
    @Test func aFollowedCorrectionIsRecordedAndReopenedWithoutTheSentenceItIsNotIn() async throws {
        let sentence = "They record it, and the recrod shows."
        let typo = Selection(
            text: "recrod", sentence: sentence, rangeInSentence: (sentence as NSString).range(of: "recrod"),
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            place: ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"))
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(deadline: Patience.wait, connect: { _ in Service(["record"]) }, fallback: { _ in nil }),
            panel: panel, spelling: Checker(["recrod": "record"]), readerEnglish: { nil })
        let missed = panel.newRequest()
        let miss = try #require(await runner.run(typo, near: .zero, requestedAt: .now, ticket: missed))
        #expect(miss.record.context == sentence, "the miss lost the sentence its word was read in")
        let followed = try #require(runner.followUp(
            SpellingSuggestion(term: "recrod", word: "record", evidence: .correction(.transposition)), from: missed.number))
        let word = try #require(await runner.run(followed, near: .zero, requestedAt: .now, ticket: panel.newRequest(),
                                                 placement: .notInSentence))
        #expect(word.record.surface == "record")
        #expect(word.record.context == "record", "the correction was recorded with a sentence it is not in")
        #expect(word.record.contextRange == nil)
        #expect(word.record.quality?.context == .missing)
        #expect(word.record.quality?.source == .accessibilityTextRange, "how the reading was captured was not kept")

        // **And reopened through the ledger**, the way History and the Library reopen a reading.
        let path = ScratchFile.path("spelling-reopen")
        defer { ScratchFile.remove(path) }
        let recorder = LookupRecorder()
        recorder.start { try LedgerStore(path: path) }
        await recorder.record(miss, request: 1)
        await recorder.record(word, request: 2)
        let entries = try Ledger(path: path).recentLookups(
            since: .distantPast, limit: 10, studying: Set(ProbeScript.allCases))
        let reopened = XiaolaiDictApp.selection(reopening: try #require(entries.first { $0.surface == "record" }))
        #expect(reopened.text == "record")
        #expect(reopened.sentence == nil, "reopened, the correction is looked for in a sentence it is not in")
        let reopenedMiss = XiaolaiDictApp.selection(reopening: try #require(entries.first { $0.surface == "recrod" }))
        #expect(reopenedMiss.sentence == sentence, "the positive control: a reading of a word in its sentence keeps it")
    }

    /// **A followed correction keeps one language, recorded and reopened, so saving it twice is one note** (audit round
    /// 3, 2026-10-09). Recorded as a named word, it kept the language recognised from the sentence it is not recorded
    /// with: "I saw teh cat." reads as Catalan, "the" alone as English — so reopened, the same reading was keyed under
    /// another language, and a note's language is part of its identity (ADR-0029): Save made a second note and split the
    /// word's progress. Judged from what is recorded, the word alone, it is the same both times.
    @Test func aFollowedCorrectionSavedReopenedAndSavedAgainIsOneNote() async throws {
        let sentence = try #require(Self.typo.sentence)
        let fromSentence = Lemmatizer.language(of: "the", in: sentence)
        let alone = Lemmatizer.language(of: "the", in: nil)
        try #require(fromSentence != alone, "the fixture's sentence no longer reads as another language than its word")
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(deadline: Patience.wait, connect: { _ in Service(["the"], twoSenses: true) }, fallback: { _ in nil }),
            panel: panel, selector: PartOfSpeechSelector(), spelling: Checker(["teh": "the"]), readerEnglish: { nil })
        let missed = panel.newRequest()
        _ = await runner.run(Self.typo, near: .zero, requestedAt: .now, ticket: missed)
        let followed = try #require(runner.followUp(Self.the, from: missed.number))
        let first = try #require(await runner.run(followed, near: .zero, requestedAt: .now, ticket: panel.newRequest(),
                                                  placement: .notInSentence))
        let answered = Self.lookups(panel.updates).compactMap { shown -> DictionaryEntry? in
            guard case .entries(let found, _)? = shown.outcome else { return nil }
            return Array(found).first
        }
        let entry = try #require(answered.last)
        let encounter = try #require(SenseEncounter.of(entry, senseKey: "m1.001", chosenBy: .reader, at: .now))

        let path = ScratchFile.path("spelling-language")
        defer { ScratchFile.remove(path) }
        let recorder = LookupRecorder()
        recorder.start { try LedgerStore(path: path) }
        await recorder.record(first, request: 1)
        recorder.enrol(encounter, request: 1, language: recorder.language(of: 1))
        await recorder.settled(request: 1)

        let reading = try #require(try Ledger(path: path).recentLookups(
            since: .distantPast, limit: 10, studying: Set(ProbeScript.allCases)).first { $0.surface == "the" })
        let reopened = try #require(await runner.run(
            XiaolaiDictApp.selection(reopening: reading), near: .zero, requestedAt: reading.at,
            ticket: panel.newRequest(), existingLookup: reading.identity))
        #expect(reopened.record.language == first.record.language, """
            reopened under \(String(describing: reopened.record.language)), recorded under \(String(describing: first.record.language))
            """)
        await recorder.record(reopened, request: 2)
        recorder.enrol(encounter, request: 2, language: recorder.language(of: 2))
        await recorder.settled(request: 2)

        let notes = try Ledger(path: path).notes()
        #expect(notes.count == 1, "saving again after reopening made \(notes.count) notes, under \(notes.map(\.language))")
    }

    /// **Following the line looks the word up in the sentence and place it was read in** — a new reading of its own,
    /// never the miss rewritten — and only from the card it was offered on, for the word it offered.
    @Test func followingTheSuggestionLooksUpTheWordWhereTheTypoWasRead() async throws {
        let panel = RecordingPanel(), service = Service(["the"]), checker = Checker(["teh": "the"])
        let runner = runner(panel, service, checker)
        let ticket = panel.newRequest()
        _ = await runner.run(Self.typo, near: .zero, requestedAt: .now, ticket: ticket)

        // Refusals first: a press that is followed spends the offer, so a refusal checked after it would hold for
        // that reason alone.
        #expect(runner.followUp(Self.the, from: ticket.number + 1) == nil, "another card's press looked the word up")
        #expect(runner.followUp(SpellingSuggestion(term: "teh", word: "ten", evidence: .correction(.substitution)),
                                from: ticket.number) == nil,
                "a word that was never offered was looked up")

        let followed = try #require(runner.followUp(Self.the, from: ticket.number))
        #expect(followed.text == "the")
        #expect(followed.sentence == Self.typo.sentence, "the reader's sentence did not go with the word")
        #expect(followed.place == Self.typo.place)
        #expect(followed.quality == Self.typo.quality)
        // **No range**: the captured one is where *teh* sits, and nothing may mark *the* there.
        #expect(followed.rangeInSentence == nil)
    }

    /// **An offer is followed only from the card on screen** (audit, 2026-10-09). Published, then superseded by a newer
    /// lookup or put away by the reader, its card is gone — and a press arriving late from it would launch a lookup,
    /// which cancels the newer one. Both refused, each with the same offer that a current card would follow.
    @Test(arguments: [false, true])
    func anOfferIsNotFollowedOnceItsCardIsGone(closed: Bool) async throws {
        let panel = RecordingPanel(), service = Service(["the"]), checker = Checker(["teh": "the"])
        let runner = runner(panel, service, checker)
        let ticket = panel.newRequest()
        _ = await runner.run(Self.typo, near: .zero, requestedAt: .now, ticket: ticket)
        try #require(Self.lookups(panel.updates).last?.suggestion == Self.the, "no offer was published, so nothing is tested")
        if closed { panel.close() } else { _ = panel.newRequest() }
        #expect(runner.followUp(Self.the, from: ticket.number) == nil,
                "a press on a card \(closed ? "the reader closed" : "a newer lookup replaced") was followed")
    }

    /// **A regular form and a credible rival leave the card with no button, and nothing to follow** (the owner's ruling of
    /// 2026-10-11): *cats* is *cat*'s regular plural, printed nowhere here, and the checker's *cuts* is verified one edit
    /// away — two credible readings, so silence, where the card once offered both. The miss stays on the card as it was.
    @Test func aRegularFormAndARivalCorrectionOfferNothing() async throws {
        let panel = RecordingPanel(), service = Service(["cat", "cuts"], twoSenses: true), checker = Checker(["cats": "cuts"])
        let runner = runner(panel, service, checker)
        let cats = Selection(
            text: "cats", sentence: "The cats sat on the mat.", rangeInSentence: NSRange(location: 4, length: 4),
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            place: ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"))
        let ticket = panel.newRequest()
        _ = await runner.run(cats, near: .zero, requestedAt: .now, ticket: ticket)
        #expect(checker.questions == ["cats"], "the checker was not asked, so no rival was weighed")
        #expect(service.questions == ["cats", "cat", "cuts"], "both candidates were not verified: \(service.questions)")
        let shown = try #require(Self.lookups(panel.updates).last)
        #expect(shown.offeredSuggestion == nil, "a contested word was offered: \(String(describing: shown.offeredSuggestion))")
        #expect(shown.outcome == .notFound(serviceFailure: nil), "the miss did not stay on the card")
        for word in ["cat", "cuts"] {
            let evidence: SpellingSuggestion.Evidence = word == "cat" ? .regular(.s) : .correction(.substitution)
            #expect(runner.followUp(SpellingSuggestion(term: "cats", word: word, evidence: evidence), from: ticket.number) == nil,
                    "\(word) could be followed though it was never offered")
        }
    }

    /// **An offer is spent by the press that follows it**: a second press — a double click, a press landing while the
    /// panel changes over — looks nothing up again.
    @Test func anOfferIsFollowedOnce() async throws {
        let panel = RecordingPanel(), service = Service(["the"]), checker = Checker(["teh": "the"])
        let runner = runner(panel, service, checker)
        let ticket = panel.newRequest()
        _ = await runner.run(Self.typo, near: .zero, requestedAt: .now, ticket: ticket)
        #expect(runner.followUp(Self.the, from: ticket.number) != nil, "the positive control: the first press is followed")
        #expect(runner.followUp(Self.the, from: ticket.number) == nil, "a second press followed the same offer again")
    }
}
