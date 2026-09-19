import AppKit
@testable import XiaolaiDict
import XiaolaiDictCore
import Synchronization
import Testing

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
        let shown = ContinuousClock.now - started

        // Bounded by the content deadline, not by the 1 s product promise. If the panel waited
        // for the dictionaries, `shown` would be the full deadline; anything under it means it
        // did not. The 1 s promise is a statement about a real machine and is measured on one —
        // e2e.sh stage 7 exists for exactly that. Asserting it here measures how many other tests
        // the runner happens to be executing in parallel, which is what made this fail.
        #expect(shown < DictionaryClient.defaultDeadline, "the panel waited for the dictionaries: \(shown)")
        #expect(panel.contents.count == 1)
        #expect(panel.contents[0].isWaitingLookup, "the first thing shown already had an outcome")
        // Still waiting: the content cannot have arrived, because the service never answers.
        #expect(panel.updates.isEmpty)

        _ = await lookup.value
        #expect(panel.updates.count == 1, "the panel was never filled in")
        #expect(panel.updates[0].isAnsweredLookup)
        #expect(ContinuousClock.now - started >= DictionaryClient.defaultDeadline, "the deadline was not the shipped one")
    }

    /// What it is waiting for, in words — not a blank panel that looks like an empty entry.
    @Test func theWaitingPanelSaysWhatItIsWaitingFor() {
        let waiting = PanelContent.lookup(LookupPresentation(
            term: "fine", lemma: Lemmatizer.lemma(of: "fine", in: nil), source: "Preview",
            capture: .accessibility(.accessibilityTextRange, context: .complete), outcome: nil))
        let detail = try! #require(waiting.waitingDescription)
        #expect(detail.contains("fine"))
        #expect(detail.localizedCaseInsensitiveContains("dictionar"))
    }

    /// Both states are one kind of panel, so filling it in cannot resize or reposition it.
    @Test func waitingAndAnsweredAreTheSameKindOfPanel() {
        let presentation = LookupPresentation(
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

    func show(_ content: PanelContent, near pointer: NSPoint, for ticket: PanelTicket) {
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
