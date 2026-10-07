import AppKit
import CaptureModel
import StudyKit
@testable import XiaolaiDict
@testable import XiaolaiDictUI
import DictionaryModel
import XiaolaiDictBase
import XiaolaiDictCore
import Synchronization
import Testing
import XiaolaiDictTestSupport

/// The order a lookup reaches the reader in. The panel is a container that fills in, not a payload
/// that is awaited: `feature-ledger-ux.md` B3 asks for a panel within 1 s, and the deadline that
/// governs the *content* is three seconds.
@MainActor
struct LookupRunnerTests {
    static let selection = Selection(
        text: "fine", sentence: "He paid the fine.", rangeInSentence: NSRange(location: 12, length: 4),
        quality: .accessibility(.accessibilityTextRange, context: .complete),
        place: ReadingPlace(
            bundleID: "com.apple.Preview", name: "Preview", document: "file:///tmp/paper.pdf",
            page: nil, title: "paper", rawTitle: "paper.pdf"))

    /// The shipped deadline itself, pinned against a literal.
    ///
    /// **Separated from the behaviour below on purpose.** That test used to end by asserting its own
    /// elapsed wall clock was `>= DictionaryClient.defaultDeadline` under the message "the deadline
    /// was not the shipped one" — a bound taken from the very constant it claimed to check, so
    /// shrinking the deadline shrank the bound with it and the assertion went on passing. It could
    /// not fail for the reason its message named, and it spent three seconds of wall clock on every
    /// run to say so. A literal here fails the moment the constant moves, and costs nothing.
    @Test func theShippedDeadlineIsThreeSeconds() {
        #expect(DictionaryClient.defaultDeadline == .seconds(3))
    }

    /// **The wire:** a lookup waits for the study dictionary to be derived, and only then reads the
    /// primary — after the panel is up, never before.
    @Test func theLookupSettlesTheStudyDictionaryBeforeFreezingItsPrimary() async throws {
        let panel = RecordingPanel()
        let order = Mutex<[String]>([])
        let runner = LookupRunner(
            client: DictionaryClient(
                deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in nil }),
            panel: panel,
            primary: { order.withLock { $0.append("primary") }; return PrimaryDictionary() },
            settle: { order.withLock { $0.append("settle") } })
        _ = await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())
        #expect(order.withLock { $0 } == ["settle", "primary"])
        #expect(!panel.contents.isEmpty, "the panel was shown")
    }

    /// The promise: a service that never replies holds the content, and the panel must not wait
    /// with it.
    ///
    /// Run at a deadline of its own rather than the shipped three seconds. The runner's ordering
    /// does not depend on how long the deadline is — the same code path either way — so the
    /// magnitude is pinned once, above, and the behaviour is measured where it is cheap.
    @Test func thePanelIsShownBeforeTheDictionariesAnswer() async throws {
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(
                deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in nil }),
            panel: panel)
        let ticket = panel.newRequest()

        _ = await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: ticket)

        // **Counted, not timed.** This used to also assert the elapsed time was under the content
        // deadline, and it failed under a full parallel run — an upper bound on wall clock measures
        // how many other tests the runner happens to be executing, which is what this project's
        // test rules say not to do. It was also redundant: against a service that never replies,
        // a panel holding a waiting lookup with no updates *is* a panel that did not wait for the
        // dictionaries, however long the machine took to get there. The 1 s product promise is a
        // statement about a real machine and is measured on one — e2e.sh stage 7 exists for that.
        //
        // The clock is no longer read here at all: the *lower* bound that used to close this test
        // was taken from the constant it was checking, so it could not see that constant move.
        #expect(panel.contents.count == 1)
        #expect(panel.contents[0].isWaitingLookup, "the first thing shown already had an outcome")
        // Shown before anything arrived — recorded at the show, not observed against the deadline,
        // which a busy run let pass before the old assertion was reached.
        #expect(panel.updatesWhenFirstShown == 0, "the panel waited for the dictionaries")
        #expect(panel.updates.count == 1, "the panel was never filled in")
        #expect(panel.updates[0].isAnsweredLookup)
    }

    /// The local model is loaded while the dictionaries are asked, so the sense question after them
    /// does not pay for the load — and the lookup never waits on it.
    @Test func theModelIsPrewarmedBesideTheLookup() async throws {
        let prewarmed = Recorder(0)
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in nil }),
            panel: panel, prewarm: { prewarmed.withLock { $0 += 1 } })
        // A ticket the panel handed out. `PanelTicket(number: 0)` stood here and was current only
        // because the stand-in's counter happened to start at 0 — a request nobody made.
        _ = await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())
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
        // **The positive control.** `kind` switches on the case alone, so the equality above reads
        // as a constant compared with itself unless something shows that `kind` can tell two
        // contents apart at all. A message is the other kind, and it is the comparison that makes
        // the first line a measurement: without it, a `kind` that answered `.lookup` to everything
        // would pass here and resize the panel on being filled in.
        #expect(PanelContent.lookup(presentation).kind
                != PanelContent.message(title: "no selection", detail: "…").kind)
    }

    /// A lookup superseded while it waited was never seen: it neither fills the newer panel nor
    /// leaves a record behind.
    ///
    /// **The order is the test's, not a race against a deadline.** This used the shipped three-second
    /// deadline against a service that never answers, and superseded the lookup once the panel had
    /// been shown — so under a loaded parallel run, with the main actor starved past three seconds,
    /// the deadline fired first, the fallback answered a lookup that was still current, and it filled
    /// the panel and was recorded, correctly (2026-10-04, `make e2e`: failed after 10.9 s, passed in
    /// the `make test` before it). The service now answers — with entries, which would fill the panel
    /// — only once the reader has pressed again, and the deadline is one no starvation reaches.
    @Test func aSupersededLookupNeitherFillsThePanelNorIsRecorded() async throws {
        let panel = RecordingPanel()
        let gate = ReplyGate()
        let runner = LookupRunner(
            client: DictionaryClient(deadline: .seconds(600),
                                     connect: { [entry = Self.twoSenses] _ in RepliesWhenReleased(gate: gate, entry: entry) },
                                     fallback: { _ in nil }),
            panel: panel)
        let ticket = panel.newRequest()
        let lookup = Task { await runner.run(Self.selection, near: .zero, requestedAt: .now, ticket: ticket) }
        try await panel.waitForShow()
        _ = panel.newRequest()  // the reader pressed the shortcut again
        gate.open()             // and only then does the dictionary answer

        let recording = await lookup.value
        #expect(gate.wasAsked, "the service was never asked, so nothing was superseded while it waited")
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
            panel: panel,
            priorEncounters: { _, _, language in
                // The ledger is asked in the language the sentence was read in.
                #expect(language == "en")
                return earlier
            })
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
        // **A run that produced no lookup would pass this loop without executing one assertion.**
        // The `continue` skips every other kind of content, so the floor is what makes the loop
        // below evidence of anything — the same guard two other tests in this directory carry.
        let lookups = (panel.contents + panel.updates).compactMap { content -> LookupPresentation? in
            guard case .lookup(let lookup) = content else { return nil }
            return lookup
        }
        #expect(lookups.count >= 2,
                "\(lookups.count) lookup contents reached the panel; expected the waiting card and the answered one")
        for lookup in lookups {
            #expect(lookup.memory == nil)
            #expect(lookup.met.isEmpty)
        }
    }
}

/// A transport that accepts the request and never answers — the hung service the deadline exists
/// for. It must outlast the deadline, so it sleeps well past it rather than racing it.
struct NeverReplies: DictionaryTransport {
    func send(_ request: ServiceRequest) async throws -> ServiceReply {
        try await Task.sleep(for: .seconds(60))
        return .lookup(LookupAnswer(word: .notFound))
    }

    func cancel(reason: String) {}
}

/// When a gated service may answer, opened by the test — so what happens while a lookup waits is
/// ordered by the test rather than raced against a deadline.
private final class ReplyGate: Sendable {
    private let state = Mutex((asked: false, open: false))
    func open() { state.withLock { $0.open = true } }
    var wasAsked: Bool { state.withLock { $0.asked } }
    fileprivate func ask() { state.withLock { $0.asked = true } }
    fileprivate var isOpen: Bool { state.withLock { $0.open } }
}

/// A service that answers with one entry once its gate is opened, and not before.
private struct RepliesWhenReleased: DictionaryTransport {
    let gate: ReplyGate
    let entry: DictionaryEntry
    func send(_ request: ServiceRequest) async throws -> ServiceReply {
        gate.ask()
        while !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) }
        return .lookup(LookupAnswer(word: .entries(NonEmpty([entry])!, unreadable: [])))
    }
    func cancel(reason: String) {}
}

/// A service that answers every lookup with one entry.
private struct AnswersWith: DictionaryTransport {
    let entry: DictionaryEntry
    func send(_ request: ServiceRequest) async throws -> ServiceReply {
        .lookup(LookupAnswer(word: .entries(NonEmpty([entry])!, unreadable: [])))
    }
    func cancel(reason: String) {}
}

private struct AnswersWithPhrase: DictionaryTransport {
    let entry: DictionaryEntry
    let hit: PhraseHit
    func send(_ request: ServiceRequest) async throws -> ServiceReply {
        .lookup(LookupAnswer(word: .entries(NonEmpty([entry])!, unreadable: []), phrase: .found([hit])))
    }
    func cancel(reason: String) {}
}

private struct Abstains: SenseSelecting {
    func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection { .abstained(.tooClose) }
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
/// Shared with `WindowActionsWiringTests`, which drives the same runner with `canShow` off.
final class RecordingPanel: LookupPanelPresenting {
    private(set) var contents: [PanelContent] = []
    private(set) var updates: [PanelContent] = []
    /// The controller's own rule, so this stand-in cannot drift from it.
    private var requests = RequestSequence()

    func newRequest() -> PanelTicket { PanelTicket(number: requests.next()) }
    func begin() -> Int { requests.begin() }
    func claim(_ request: Int) -> PanelTicket? { requests.claim(request) ? PanelTicket(number: request) : nil }
    func isCurrent(_ ticket: PanelTicket) -> Bool { requests.isCurrent(ticket.number) }

    /// Whether the panel can be drawn at all. The real controller answers `false` when the window
    /// actions have not been captured; a test sets this to drive that branch.
    var canShow = true

    /// How many updates had arrived when the panel was first shown — **the order, recorded where it
    /// happens**, so a test need not race a deadline to see it.
    private(set) var updatesWhenFirstShown: Int?

    @discardableResult
    func show(_ content: PanelContent, near pointer: UpPoint, for ticket: PanelTicket) -> Bool {
        guard isCurrent(ticket), canShow else { return false }
        if updatesWhenFirstShown == nil { updatesWhenFirstShown = updates.count }
        contents.append(content)
        return true
    }

    func update(_ content: PanelContent, for ticket: PanelTicket) {
        guard isCurrent(ticket) else { return }
        updates.append(content)
    }

    /// Whether the compositor would list it: shown is drawn, unless a test says the window never was.
    var drawn = true
    func seenOnScreen(_ ticket: PanelTicket) async -> Bool { canShow && drawn }

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

@MainActor
struct AutomaticKeepWiringTests {
    @Test func displayedWaitingLookupStartsRecordingBeforeDictionaryReply() async throws {
        let panel = RecordingPanel()
        var received: [LookupRecording] = []
        var answeredWhenRecorded: [Int] = []
        let runner = LookupRunner(client: DictionaryClient(deadline: .milliseconds(30),
            connect: { _ in NeverReplies() }, fallback: { _ in nil }), panel: panel,
            initialRecording: { row, _ in received.append(row); answeredWhenRecorded.append(panel.updates.count) })
        let selection = Selection(text: "fine", sentence: "A fine day.", rangeInSentence: nil,
            quality: .accessibility(.accessibilityTextRange, context: .complete), place: ReadingPlace())
        _ = await runner.run(selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())
        // The pending row comes first, before the dictionaries' answer was drawn — once the
        // compositor has said the panel is on screen, which is the only evidence the reader saw it.
        #expect(received.first?.encounter == nil)
        #expect(answeredWhenRecorded.first == 0, "the first row waited for the dictionaries")
    }
    @Test(arguments: [nil, "unavailable", "noad"] as [String?])
    func effectivePrimaryUsesFrozenChoiceAndOnlyFallsBackWhenUnset(_ chosen: String?) async throws {
        let panel = RecordingPanel()
        let entry = DictionaryEntry(dictionary:DictionaryIdentity(name:"NOAD",identifier:"noad"),headword:"fine",lookedUp:"fine",html:"<p/>",
            document:EntryDocument(isStyled:true,entryID:"e",homograph:nil,blocks:[SenseBlock(number:1,partOfSpeech:"noun",
                senses:[DictionarySense(path:SensePath(block:1,ordinal:1),key:"s",keyKind:.publisher,definition:"meaning",text:"meaning")])]))
        var preference = PrimaryDictionary(chosen:chosen)
        var received: [LookupRecording] = []
        let runner = LookupRunner(client:DictionaryClient(connect:{ _ in AnswersWith(entry:entry) }),panel:panel,
            primary:{ preference },keepPolicy:{ .automatic },initialRecording:{ row,_ in
                received.append(row); preference = PrimaryDictionary(chosen:"changed-in-flight")
            })
        let selection = Selection(text:"fine",sentence:"A fine day.",rangeInSentence:nil,
            quality:.accessibility(.accessibilityTextRange,context:.complete),place:ReadingPlace())
        let result = await runner.run(selection,near:.zero,requestedAt:.now,ticket:panel.newRequest())
        #expect(result?.primaryDictionary == (chosen ?? "noad"))
        #expect(received.last?.primaryDictionary == (chosen ?? "noad"))
        #expect(result?.keepPolicy == .automatic)
    }

    /// **The early recording claims no more than the resolver will.** A word with one sense inside a
    /// phrase the primary also defines is two readings; recorded before the selector answered as
    /// `.onlySense`, automatic keeping confirmed the word's sense while the card was still deciding.
    @Test func earlyRecordingBesideAPhraseClaimsNoSense() async throws {
        let panel = RecordingPanel()
        func entry(_ id: String, _ key: String) -> DictionaryEntry {
            DictionaryEntry(dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad"), headword: "fine",
                lookedUp: "fine", html: "<p/>", document: EntryDocument(isStyled: true, entryID: id, homograph: nil,
                    blocks: [SenseBlock(number: 1, partOfSpeech: "noun", senses: [DictionarySense(
                        path: SensePath(block: 1, ordinal: 1), key: key, keyKind: .publisher,
                        definition: "meaning", text: "meaning")])]))
        }
        let hit = PhraseHit(phrase: "fine print", location: 2, length: 10, separation: .none,
                            meaning: PhraseMeaning(ownEntries: [entry("p", "p.1")]))
        let word = entry("e", "s")
        var received: [LookupRecording] = []
        let runner = LookupRunner(
            client: DictionaryClient(connect: { _ in AnswersWithPhrase(entry: word, hit: hit) }), panel: panel,
            selector: Abstains(), keepPolicy: { .automatic }, initialRecording: { row, _ in received.append(row) })
        let selection = Selection(text: "fine", sentence: "A fine print day.", rangeInSentence: NSRange(location: 2, length: 4),
            quality: .accessibility(.accessibilityTextRange, context: .complete), place: ReadingPlace())
        let result = await runner.run(selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())
        let early = try #require(received.last?.encounter)
        #expect(early.entryID == "e")
        #expect(early.chosenBy == nil, "the word's only sense was recorded before the phrase was weighed")
        #expect(result?.encounter?.chosenBy == nil)
    }

}

/// The runner notes each stage a lookup reaches, under its request (WI-6).
@MainActor
struct LookupRunnerTimingTests {
    /// Panel, dictionary, sense — in that order, each once, under the lookup's own request. Red if a
    /// stage stops being marked, or is marked under another request.
    @Test func eachStageIsMarkedUnderItsRequest() async {
        let panel = RecordingPanel()
        var marks: [(LookupTimeline.Stage, Int)] = []
        let runner = LookupRunner(
            client: DictionaryClient(deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in "plain" }),
            panel: panel, mark: { stage, request, _ in marks.append((stage, request)) })
        let ticket = panel.newRequest()
        _ = await runner.run(LookupRunnerTests.selection, near: .zero, requestedAt: .now, ticket: ticket)
        #expect(marks.map(\.0) == [.panelShown, .dictionaryAnswered, .senseResolved])
        #expect(marks.allSatisfy { $0.1 == ticket.number })
    }
}

/// Which phrase the winning sense belongs to.
struct PhraseSenseAttributionTests {
    /// `sense` is the sense's own id — **the same in two entries** where a test needs a key that
    /// does not tell them apart, as a positional key does not.
    private static func entry(_ id: String, headword: String, definition: String, sense: String = "s") -> DictionaryEntry {
        let markup = """
            <d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng" id="\(id)" \
            d:title="\(headword)"><span class="hg x_xh0"><span class="hw">\(headword)</span></span>\
            <span id="\(sense).001" class="se1 x_xd0"><span id="\(sense).002" class="se2 x_xd1 hasSn">\
            <span d:def="1" class="df">\(definition)</span></span></span></d:entry>
            """
        return DictionaryEntry(
            dictionary: DictionaryIdentity(name: "Test", identifier: "test", version: "1"),
            headword: headword, lookedUp: headword, html: markup, document: EntryDocument.parse(markup))
    }

    private static func hit(_ phrase: String, _ entries: [DictionaryEntry]) -> PhraseHit {
        PhraseHit(phrase: phrase, location: 0, length: phrase.utf16.count, separation: .none,
                  meaning: PhraseMeaning(ownEntries: entries, filings: []))
    }

    /// **The sense is found in the entry the mark is about, in the phrase that owns it.** Two
    /// phrases' entries share a positional key; the mark is about the second phrase's entry. Red if
    /// the key is matched across every phrase entry, which answered with the first.
    @Test func theSenseIsTheOwnersAndSoIsThePhrase() throws {
        let first = Self.entry("p1", headword: "red herring", definition: "a fish")
        let second = Self.entry("p2", headword: "herring bone", definition: "a pattern")
        let key = try #require(second.blocks.first?.senses.first?.key)
        #expect(first.blocks.first?.senses.first?.key == key, "the fixture must share the key")
        let found = try #require(LookupRunner.phraseSense(
            key: key, owner: PanelSelection.identity(of: second),
            in: [Self.hit("red herring", [first]), Self.hit("herring bone", [second])]))
        #expect(found.0 == 1, "the sense was attributed to the leading phrase")
        #expect((found.1.definition ?? found.1.text).contains("pattern"))
    }

    /// A mark about none of the phrases' entries is the word's: nothing is attributed.
    @Test func aWordsSenseIsNoPhrases() throws {
        let entry = Self.entry("p1", headword: "red herring", definition: "a fish")
        let key = try #require(entry.blocks.first?.senses.first?.key)
        #expect(LookupRunner.phraseSense(key: key, owner: "someone-else", in: [Self.hit("red herring", [entry])]) == nil)
    }
}


/// **A panel that was asked for and never drawn records nothing** — the compositor is the evidence.
@MainActor
struct LookupRunnerSeenTests {
    @Test func aPanelNeverDrawnRecordsNothing() async {
        let panel = RecordingPanel()
        panel.drawn = false
        var recorded = 0
        let runner = LookupRunner(
            client: DictionaryClient(deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in "plain" }),
            panel: panel, initialRecording: { _, _ in recorded += 1 })
        let row = await runner.run(LookupRunnerTests.selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())
        #expect(row == nil, "a lookup nobody saw was returned for recording")
        #expect(recorded == 0, "a lookup nobody saw wrote a pending row")
    }

    /// **"Panel" is timed by the compositor, not by the request** (audit round 3, #28). Marked when
    /// the window was asked for, it under-stated the latency a reader sees and timed panels that
    /// never drew at all.
    @Test func aPanelNeverDrawnIsNeverMarkedShown() async {
        let panel = RecordingPanel()
        panel.drawn = false
        var marks: [LookupTimeline.Stage] = []
        let runner = LookupRunner(
            client: DictionaryClient(deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in "plain" }),
            panel: panel, mark: { stage, _, _ in marks.append(stage) })
        _ = await runner.run(LookupRunnerTests.selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())
        #expect(!marks.contains(.panelShown), "a panel the compositor never listed was timed as shown")
    }

    /// **The compositor's verdict reaches whoever delivered the word** (#38), once, either way.
    @Test func theCompositorsVerdictIsReported() async {
        for drawn in [true, false] {
            let panel = RecordingPanel()
            panel.drawn = drawn
            var verdicts: [Bool] = []
            let runner = LookupRunner(
                client: DictionaryClient(deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in "plain" }),
                panel: panel)
            _ = await runner.run(LookupRunnerTests.selection, near: .zero, requestedAt: .now,
                                 ticket: panel.newRequest(), seen: { verdicts.append($0) })
            #expect(verdicts == [drawn])
        }
    }
}
