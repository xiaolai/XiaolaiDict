import AppKit
@testable import XiaolaiDict
@testable import XiaolaiDictUI
import XiaolaiDictCore
import Synchronization
import Testing
import XiaolaiDictTestSupport

/// The order a lookup reaches the reader in. The panel is a container that fills in, not a payload
/// that is awaited: `feature-ledger-ux.md` B3 asks for a panel within 1 s, and the deadline that
/// governs the *content* is three seconds.
@MainActor
struct LookupRunnerTests {
    private static let selection = Selection(
        text: "fine", sentence: "He paid the fine.", rangeInSentence: NSRange(location: 12, length: 4),
        quality: .accessibility(.accessibilityTextRange, context: .complete),
        place: ReadingPlace(
            bundleID: "com.apple.Preview", name: "Preview", document: "file:///tmp/paper.pdf",
            page: nil, title: "paper", rawTitle: "paper.pdf"))

    /// The promise, at the deadline the app actually ships. A service that never replies holds the
    /// content for the full three seconds; the panel must not wait with it.
    @Test func thePanelIsShownBeforeTheDictionariesAnswer() async throws {
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(connect: { _ in NeverReplies() }, fallback: { _ in nil }), panel: panel)
        let ticket = panel.newRequest()

        let started = ContinuousClock.now
        let lookup = Task { await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: ticket) }
        try await panel.waitForShow()

        // **Counted, not timed.** This used to also assert the elapsed time was under the content
        // deadline, and it failed under a full parallel run — an upper bound on wall clock measures
        // how many other tests the runner happens to be executing, which is what this project's
        // test rules say not to do. It was also redundant: against a service that never replies,
        // a panel holding a waiting lookup with no updates *is* a panel that did not wait for the
        // dictionaries, however long the machine took to get there. The 1 s product promise is a
        // statement about a real machine and is measured on one — e2e.sh stage 7 exists for that.
        //
        // The clock is still read below, for the *lower* bound on the whole lookup. A floor is
        // safe where a ceiling is not: a loaded machine can only ever take longer.
        #expect(panel.contents.count == 1)
        #expect(panel.contents[0].isWaitingLookup, "the first thing shown already had an outcome")
        // Still waiting: the content cannot have arrived, because the service never answers.
        #expect(panel.updates.isEmpty)

        _ = await lookup.value
        #expect(panel.updates.count == 1, "the panel was never filled in")
        #expect(panel.updates[0].isAnsweredLookup)
        #expect(ContinuousClock.now - started >= DictionaryClient.defaultDeadline, "the deadline was not the shipped one")
    }

    /// The local model is loaded while the dictionaries are asked, so the sense question after them
    /// does not pay for the load — and the lookup never waits on it.
    @Test func theModelIsPrewarmedBesideTheLookup() async throws {
        let prewarmed = Recorder(0)
        let runner = LookupRunner(
            client: DictionaryClient(deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in nil }),
            panel: RecordingPanel(), prewarm: { prewarmed.withLock { $0 += 1 } })
        _ = await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: PanelTicket(number: 0))
        for _ in 0..<200 where prewarmed.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(prewarmed.withLock { $0 } == 1)
    }

    /// What it is waiting for, in words — not a blank panel that looks like an empty entry.
    @Test func theWaitingPanelSaysWhatItIsWaitingFor() {
        let waiting = PanelContent.lookup(LookupPresentation(
            request: 1,
            term: "fine", lemma: Lemmatizer.lemma(of: "fine", in: nil), source: "Preview",
            capture: .accessibility(.accessibilityTextRange, context: .complete), outcome: nil))
        let detail = try! #require(waiting.waitingDescription)
        #expect(detail.contains("fine"))
        #expect(detail.localizedCaseInsensitiveContains("dictionar"))
    }

    /// Both states are one kind of panel, so filling it in cannot resize or reposition it.
    @Test func waitingAndAnsweredAreTheSameKindOfPanel() {
        let presentation = LookupPresentation(
            request: 2,
            term: "fine", lemma: Lemmatizer.lemma(of: "fine", in: nil), source: nil,
            capture: .accessibility(.accessibilityTextRange, context: .complete), outcome: nil)
        var answered = presentation
        answered.outcome = .notFound(serviceFailure: nil)
        #expect(PanelContent.lookup(presentation).kind == PanelContent.lookup(answered).kind)
    }

    /// A lookup superseded while it waited was never seen: it neither fills the newer panel nor
    /// leaves a record behind.
    @Test func aSupersededLookupNeitherFillsThePanelNorIsRecorded() async throws {
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(connect: { _ in NeverReplies() }, fallback: { _ in nil }), panel: panel)
        let ticket = panel.newRequest()
        let lookup = Task { await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: ticket) }
        try await panel.waitForShow()
        _ = panel.newRequest()  // the reader pressed the shortcut again

        let recording = await lookup.value
        #expect(recording == nil, "a lookup nobody saw was recorded")
        #expect(panel.updates.isEmpty, "a superseded lookup filled the newer panel")
    }

    /// **A lookup whose entry was shown is recorded, even if superseded while its sense was decided.**
    /// The rule is "a lookup nobody saw is not recorded", and this one was seen: the entry was on
    /// screen. What was never shown is the mark, and the mark is not what makes it the reader's.
    @Test func aLookupSupersededWhileItsSenseIsDecidedIsStillRecorded() async throws {
        let panel = RecordingPanel()
        let supersede = SupersedingSelector(panel: panel)
        let runner = LookupRunner(
            client: DictionaryClient(connect: { [entry = Self.twoSenses] _ in AnswersWith(entry: entry) }, fallback: { _ in nil }),
            panel: panel, selector: supersede)
        let recording = await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())
        #expect(supersede.asked, "the selector never ran, so nothing was superseded during it")
        #expect(recording != nil, "a lookup the reader saw was dropped from the ledger")
        #expect(panel.updates.count == 1, "the mark was drawn into the newer panel")
    }

    /// Each lookup's panel content carries its request, which is what gives it a view of its own.
    @Test func theShownLookupCarriesItsRequest() async throws {
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(deadline: .milliseconds(10), connect: { _ in NeverReplies() }, fallback: { _ in nil }),
            panel: panel)
        let ticket = panel.newRequest()
        _ = await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: ticket)
        guard case .lookup(let presentation) = panel.contents.first else { Issue.record("nothing shown"); return }
        #expect(presentation.request == ticket.number)
    }

    private static var twoSenses: DictionaryEntry {
        DictionaryEntry(
            dictionary: DictionaryIdentity(name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "1.0"),
            headword: "fine", lookedUp: "fine", html: "<p/>",
            document: EntryDocument(
                isStyled: true, entryID: "m1", homograph: nil,
                blocks: [SenseBlock(number: 1, partOfSpeech: "noun", senses: [1, 2].map {
                    DictionarySense(path: SensePath(block: 1, ordinal: $0), key: "m1.00\($0)", keyKind: .publisher,
                                    definition: "meaning \($0)", text: "meaning \($0)")
                })]))
    }

    /// The answered lookup is what gets recorded, with the sentence it was read in.
    @Test func theAnsweredLookupIsRecorded() async throws {
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(connect: { _ in NeverReplies() }, fallback: { _ in "plain text" }), panel: panel)
        let recording = try #require(await runner.run(
            Self.selection, near: .zero, requestedAt: .now, ticket: panel.newRequest()))
        let record = recording.record
        // The service never answers, so the fallback did — and a fallback has no entries, so there
        // is no entry and no sense to record.
        #expect(recording.encounter == nil)
        #expect(record.surface == "fine")
        #expect(record.context == "He paid the fine.")
        #expect(record.place.bundleID == "com.apple.Preview")
        #expect(record.place.document == "file:///tmp/paper.pdf")
        #expect(record.place.precision == .document)
        #expect(record.result == LookupResult.found)
        #expect(record.answeredBy == AnswerSource.publicFallback, "a fallback answer was recorded as the service's")
        // All four were captured and thrown away at the ledger before schema 4.
        #expect(record.lemmaBasis != nil)
        #expect(record.language == "en")
        #expect(record.contextRange == NSRange(location: 12, length: 4))
    }

    /// **What the word cost the reader before reaches the panel.** `MemoryStrip` and the met senses
    /// were built, tested and never wired: the runner took a ledger reader and never called it, so
    /// every panel showed a first lookup. The same shape as the hover pause that shipped complete
    /// and unreachable — a dependency nothing reads is invisible to every test of the value itself.
    @Test func thePanelIsToldWhatTheReaderMetBefore() async throws {
        let panel = RecordingPanel()
        let met = StudyItem(
            dictionary: "NOAD", entryID: "m_en_gbus0123456", senseKey: "4", senseKeyKind: .publisher)
        let earlier = PriorEncounters(
            occasions: [PriorEncounter(at: .now.addingTimeInterval(-86_400), where: "Preview", title: "paper")],
            met: [met])
        let runner = LookupRunner(
            client: DictionaryClient(connect: { _ in NeverReplies() }, fallback: { _ in "plain text" }),
            panel: panel, priorEncounters: { _, _ in earlier })
        _ = await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())

        let shown = try #require(panel.updates.compactMap { content -> LookupPresentation? in
            guard case .lookup(let lookup) = content else { return nil }
            return lookup
        }.last)
        #expect(shown.memory?.occasion == 2, "the memory strip never reached the panel")
        #expect(shown.met == [met], "the senses already met never reached the panel")
    }

    /// A first lookup has nothing to remember, and an empty strip is noise on the commonest case.
    @Test func aFirstLookupIsShownNoMemoryStrip() async throws {
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(connect: { _ in NeverReplies() }, fallback: { _ in "plain text" }),
            panel: panel)
        _ = await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())
        for content in panel.contents + panel.updates {
            guard case .lookup(let lookup) = content else { continue }
            #expect(lookup.memory == nil)
            #expect(lookup.met.isEmpty)
        }
    }
}

/// A transport that accepts the request and never answers — the hung service the deadline exists
/// for. It must outlast the deadline, so it sleeps well past it rather than racing it.
private struct NeverReplies: DictionaryTransport {
    func send(_ request: ServiceRequest) async throws -> ServiceReply {
        try await Task.sleep(for: .seconds(60))
        return .lookup(.notFound)
    }

    func cancel(reason: String) {}
}

/// A service that answers every lookup with one entry.
private struct AnswersWith: DictionaryTransport {
    let entry: DictionaryEntry
    func send(_ request: ServiceRequest) async throws -> ServiceReply {
        .lookup(.entries(NonEmpty([entry])!, unreadable: []))
    }
    func cancel(reason: String) {}
}

/// A selector during which the reader presses the shortcut again.
private final class SupersedingSelector: SenseSelecting, @unchecked Sendable {
    let panel: RecordingPanel
    private(set) var asked = false
    init(panel: RecordingPanel) { self.panel = panel }

    func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection {
        asked = true
        await MainActor.run { _ = panel.newRequest() }
        return .chose(key: candidates[0].key, margin: 1, entryID: candidates[0].entryID)
    }
}

/// Stands in for the panel and remembers what it was asked to do, and in which order.
@MainActor
private final class RecordingPanel: LookupPanelPresenting {
    private(set) var contents: [PanelContent] = []
    private(set) var updates: [PanelContent] = []
    private var current = 0

    func newRequest() -> PanelTicket {
        current += 1
        return PanelTicket(number: current)
    }

    func isCurrent(_ ticket: PanelTicket) -> Bool { ticket.number == current }

    func show(_ content: PanelContent, near pointer: UpPoint, for ticket: PanelTicket) {
        guard isCurrent(ticket) else { return }
        contents.append(content)
    }

    func update(_ content: PanelContent, for ticket: PanelTicket) {
        guard isCurrent(ticket) else { return }
        updates.append(content)
    }

    /// Waits for the panel to be presented, rather than assuming it already has been.
    func waitForShow() async throws {
        for _ in 0..<2_000 {
            if !contents.isEmpty { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("the panel was never shown")
    }
}

extension PanelContent {
    /// A lookup panel that is still waiting for its dictionaries.
    var isWaitingLookup: Bool {
        guard case .lookup(let presentation) = self else { return false }
        return presentation.outcome == nil
    }

    var isAnsweredLookup: Bool {
        guard case .lookup(let presentation) = self else { return false }
        return presentation.outcome != nil
    }
}
