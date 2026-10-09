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
@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **"Did you mean …?" as `LookupRunner` delivers it** (plan-spelling-suggestion §3–§4): the miss is on the card first,
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

    static let the = SpellingSuggestion(term: "teh", word: "the")

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
            while state.withLock({ $0.held }) { try? await Task.sleep(for: .milliseconds(2)) }
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
        private let asked = Mutex<[String]>([])
        init(_ words: Set<String>) { self.words = words }
        var questions: [String] { asked.withLock { $0 } }
        func send(_ request: ServiceRequest) async throws -> ServiceReply {
            guard case .lookup(let lookup) = request else { return .dictionaries([]) }
            asked.withLock { $0.append(lookup.term) }
            guard words.contains(lookup.term) else { return .lookup(LookupAnswer(word: .notFound)) }
            let entry = DictionaryEntry(
                dictionary: DictionaryIdentity(name: "NOAD", identifier: "com.apple.dictionary.NOAD"),
                headword: lookup.term, lookedUp: lookup.term, html: "<p/>", document: nil)
            return .lookup(LookupAnswer(word: .entries(NonEmpty([entry])!, unreadable: [])))
        }
        func cancel(reason: String) {}
    }

    private func runner(_ panel: RecordingPanel, _ service: Service, _ checker: Checker) -> LookupRunner {
        LookupRunner(
            client: DictionaryClient(connect: { _ in service }, fallback: { _ in nil }), panel: panel,
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
    @Test(.timeLimit(.minutes(1))) func theMissIsShownFirstAndItsVerifiedSuggestionArrivesAfter() async throws {
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
        let cases: [(Selection, DictionaryClient.Connect, String?)] = [
            (Self.selection("the", in: "I saw the cat."), { _ in Service(["the"]) }, nil),
            (Self.selection("teh"), { _ in NeverReplies() }, "an article"),
            (Self.selection("teh"), { _ in NeverReplies() }, nil),
            (Self.selection("teh cat", in: "I saw teh cat."), { _ in Service([]) }, nil),
            (Self.selection("水", in: "我看见水。"), { _ in Service([]) }, nil),
        ]
        for (selection, connect, fallback) in cases {
            let panel = RecordingPanel(), checker = Checker(["teh": "the", "the": "they", "水": "the"])
            let runner = LookupRunner(
                client: DictionaryClient(deadline: .milliseconds(50), connect: connect, fallback: { _ in fallback }),
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
    @Test(.timeLimit(.minutes(1))) func aNewerLookupCancelsAPendingSuggestion() async throws {
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
    @Test(.timeLimit(.minutes(1))) func aSupersededLookupKeepsNoSuggestion() async throws {
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

    /// **Following the line looks the word up in the sentence and place it was read in** — a new reading of its own,
    /// never the miss rewritten — and only from the card it was offered on, for the word it offered.
    @Test func followingTheSuggestionLooksUpTheWordWhereTheTypoWasRead() async throws {
        let panel = RecordingPanel(), service = Service(["the"]), checker = Checker(["teh": "the"])
        let runner = runner(panel, service, checker)
        let ticket = panel.newRequest()
        _ = await runner.run(Self.typo, near: .zero, requestedAt: .now, ticket: ticket)

        let followed = try #require(runner.followUp(Self.the, from: ticket.number))
        #expect(followed.text == "the")
        #expect(followed.sentence == Self.typo.sentence, "the reader's sentence did not go with the word")
        #expect(followed.place == Self.typo.place)
        #expect(followed.quality == Self.typo.quality)
        // **No range**: the captured one is where *teh* sits, and nothing may mark *the* there.
        #expect(followed.rangeInSentence == nil)

        #expect(runner.followUp(Self.the, from: ticket.number + 1) == nil, "another card's press looked the word up")
        #expect(runner.followUp(SpellingSuggestion(term: "teh", word: "ten"), from: ticket.number) == nil,
                "a word that was never offered was looked up")
    }
}
