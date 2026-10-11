import AppKit
import Capture
import CaptureModel
import DictionaryModel
import MacCapture
@testable import StudyModels
@testable import XiaolaiDict
@testable import XiaolaiDictUI
import StudyKit
import Synchronization
import Testing
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictTestSupport

/// **The card first, then the sentence** (C1, decided 2026-10-11). A pixel read answers with the first strip's word at
/// once and goes on reading a taller strip; the dictionary content must not wait for it, and the automatic sense
/// proposal must not be made on the interim sentence — mark, never jump.
@MainActor
struct PendingContextRunnerTests {
    /// The first strip's reading: the sentence ran off its bottom edge.
    nonisolated static let interim = Selection(
        text: "fine", sentence: "He paid the fine and", rangeInSentence: NSRange(location: 12, length: 4),
        quality: CaptureQuality(source: .opticalRecognition, confidence: 1, context: .mayBeCut)!,
        place: ReadingPlace(bundleID: "com.mitchellh.ghostty", name: "Ghostty"), sentenceCut: .end)

    /// What the taller strip read: the same word, in the whole sentence.
    nonisolated static let grown = Selection(
        text: "fine", sentence: "Before leaving, he paid the fine and went home.",
        rangeInSentence: NSRange(location: 28, length: 4),
        quality: CaptureQuality(source: .opticalRecognition, confidence: 1, context: .complete)!,
        place: ReadingPlace(bundleID: "com.mitchellh.ghostty", name: "Ghostty"))

    nonisolated static var twoSenses: DictionaryEntry {
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

    @MainActor
    private final class Harness {
        let panel = RecordingPanel()
        let selector = ProposingSelector()
        let gate = ContextGate()
        let rows = Recorder<[LookupRecording]>([])
        let sentences = Recorder<[String?]>([])
        let runner: LookupRunner

        init() {
            let rows = rows
            let sentences = sentences
            runner = LookupRunner(
                client: DictionaryClient(
                    deadline: Patience.wait,
                    connect: { [entry = PendingContextRunnerTests.twoSenses] _ in
                        SentenceRecordingTransport(entry: entry, sentences: sentences)
                    },
                    fallback: { _ in nil }),
                panel: panel, selector: selector,
                initialRecording: { row, _ in rows.withLock { $0.append(row) } })
        }

        /// The lookups the panel was shown and updated with, in order.
        var lookups: [LookupPresentation] {
            (panel.contents + panel.updates).compactMap { content in
                guard case .lookup(let lookup) = content else { return nil }
                return lookup
            }
        }

        func context() -> PendingContext {
            let gate = gate
            return PendingContext {
                await gate.held()
                return Task.isCancelled ? nil : PendingContextRunnerTests.grown
            }
        }
    }

    /// **The acceptance test.** With the second read held, the reader already has the dictionary's content, the card
    /// says the sentence is still being read, and no proposal has been made on the interim sentence. Once it settles,
    /// the sentence is whole, the proposal is made on it alone, and one reading is recorded with it.
    @Test func theCardComesFirstAndTheProposalWaitsForTheWholeSentence() async throws {
        let harness = Harness()
        let run = Task { await harness.runner.run(Self.interim, near: .zero, requestedAt: .now,
                                                  ticket: harness.panel.newRequest(), context: harness.context()) }
        #expect(await Patience.until { harness.lookups.contains { $0.outcome != nil } },
                "the dictionary's content waited for the second read")
        #expect(await Patience.until { harness.gate.isWaiting }, "the second read was never asked for")
        let early = harness.lookups
        #expect(early.allSatisfy { $0.sentenceStillBeingRead }, "a card said the sentence was settled while it was read")
        #expect(early.allSatisfy { $0.sense == nil }, "a proposal was drawn on the interim sentence")
        #expect(early.allSatisfy { $0.sentence == Self.interim.sentence })
        #expect(harness.selector.sentences.isEmpty, "the selector was asked about the interim sentence")
        #expect(harness.rows.withLock { $0 }.isEmpty, "a reading was recorded before its context settled")

        harness.gate.open()
        let recording = try #require(await run.value)
        let last = try #require(harness.lookups.last)
        #expect(!last.sentenceStillBeingRead)
        #expect(last.sentence == Self.grown.sentence, "the card kept the interim sentence")
        #expect(last.sentenceCut.isEmpty)
        #expect(last.termPlacement == .at(NSRange(location: 28, length: 4)))
        #expect(last.sense != nil, "the proposal never arrived")
        #expect(harness.selector.sentences == [Self.grown.sentence], "the selector was given \(harness.selector.sentences)")
        // **No card ever drew a proposal beside the interim sentence.**
        #expect(harness.lookups.allSatisfy { $0.sense == nil || $0.sentence == Self.grown.sentence })
        // **One reading, with the context its proposal was made on** — every write of it, and the row returned.
        #expect(recording.record.context == Self.grown.sentence)
        #expect(recording.record.contextRange == NSRange(location: 28, length: 4))
        #expect(recording.record.quality?.context == .complete)
        let rows = harness.rows.withLock { $0 }
        #expect(!rows.isEmpty, "the answered row was never begun")
        #expect(rows.allSatisfy { $0.record.context == Self.grown.sentence }, "a row carried \(rows.map(\.record.context))")
        // **The phrase is asked about the sentence the proposal is made on**, after the interim one.
        #expect(harness.sentences.withLock { $0 }.last == Self.grown.sentence)
    }

    /// **A lookup the reader moved on from stops reading for its context**, and is recorded as it was shown: the
    /// interim sentence, annotated, with no proposal and no abstention.
    @Test func cancellingTheLookupCancelsTheContextAndRecordsTheInterimReading() async throws {
        let harness = Harness()
        let run = Task { await harness.runner.run(Self.interim, near: .zero, requestedAt: .now,
                                                  ticket: harness.panel.newRequest(), context: harness.context()) }
        #expect(await Patience.until { harness.gate.isWaiting && harness.lookups.contains { $0.outcome != nil } })
        run.cancel()
        let recording = try #require(await run.value, "a lookup whose entry was shown was not recorded")
        #expect(await Patience.until { harness.gate.sawCancellation }, "the context went on being read")
        #expect(harness.selector.sentences.isEmpty, "a proposal was asked for a cancelled lookup")
        #expect(recording.record.context == Self.interim.sentence)
        #expect(recording.record.quality?.context == .mayBeCut)
        #expect(recording.record.senseAbstention == nil)
        #expect(recording.encounter == nil)
    }

    /// **An older capture never updates a newer lookup.** Superseded while its context was read, the lookup draws
    /// nothing more — not the grown sentence, not a proposal — and asks nobody for one.
    @Test func aLookupSupersededWhileItsContextIsReadUpdatesNothing() async throws {
        let harness = Harness()
        let run = Task { await harness.runner.run(Self.interim, near: .zero, requestedAt: .now,
                                                  ticket: harness.panel.newRequest(), context: harness.context()) }
        #expect(await Patience.until { harness.gate.isWaiting && harness.lookups.contains { $0.outcome != nil } })
        let drawn = harness.lookups.count
        _ = harness.panel.newRequest()  // the reader pressed the shortcut, and that lookup has the panel
        harness.gate.open()
        _ = await run.value
        #expect(harness.lookups.count == drawn, "a superseded lookup updated the panel")
        #expect(harness.selector.sentences.isEmpty, "a superseded lookup asked for a proposal")
    }

    /// **A reader's tap during the wait outranks the proposal that arrives after it**: the card draws the reader's
    /// sense, and the proposal reaches only what the reader has not chosen.
    @Test func aTapDuringTheWaitIsNotReplacedByTheProposal() async throws {
        let harness = Harness()
        let run = Task { await harness.runner.run(Self.interim, near: .zero, requestedAt: .now,
                                                  ticket: harness.panel.newRequest(), context: harness.context()) }
        #expect(await Patience.until { harness.gate.isWaiting && harness.lookups.contains { $0.outcome != nil } })
        var tapped = PanelSelection()
        tapped.choose("m1.002", in: Self.twoSenses)  // the reader taps the second sense while the sentence is read
        harness.gate.open()
        _ = await run.value
        let last = try #require(harness.lookups.last)
        #expect(last.sense?.key == "m1.001", "the positive control: the selector proposed the first sense")
        let drawn = tapped.mark(for: Self.twoSenses, proposing: last.sense, ownedBy: last.senseOwner)
        #expect(drawn == .chosen(key: "m1.002", by: .reader), "the proposal replaced the reader's tap: \(String(describing: drawn))")
    }

    /// **A lookup with nothing left to read is unchanged**: no pending line, and the proposal as before.
    @Test func aLookupWithNoContextPendingIsNeverMarkedAsBeingRead() async throws {
        let harness = Harness()
        _ = await harness.runner.run(Self.grown, near: .zero, requestedAt: .now, ticket: harness.panel.newRequest())
        #expect(!harness.lookups.isEmpty)
        #expect(harness.lookups.allSatisfy { !$0.sentenceStillBeingRead })
        #expect(harness.selector.sentences == [Self.grown.sentence])
    }
}

/// The second read, held until the test opens it — and whether it was given up on.
private final class ContextGate: Sendable {
    private let state = Mutex((waiting: false, open: false, cancelled: false))
    var isWaiting: Bool { state.withLock { $0.waiting } }
    var sawCancellation: Bool { state.withLock { $0.cancelled } }
    func open() { state.withLock { $0.open = true } }

    func held() async {
        state.withLock { $0.waiting = true }
        _ = await Patience.until { self.state.withLock { $0.open } || Task.isCancelled }
        if Task.isCancelled { state.withLock { $0.cancelled = true } }
    }
}

/// A service that answers every lookup with one entry and remembers the sentence each was asked about.
private struct SentenceRecordingTransport: DictionaryTransport {
    let entry: DictionaryEntry
    let sentences: Recorder<[String?]>
    func send(_ request: ServiceRequest) async throws -> ServiceReply {
        if case .lookup(let lookup) = request { sentences.withLock { $0.append(lookup.sentence) } }
        return .lookup(LookupAnswer(word: .entries(NonEmpty([entry])!, unreadable: [])))
    }
    func cancel(reason: String) {}
}

/// A selector that proposes the first candidate and remembers the sentence it was asked by.
private final class ProposingSelector: SenseSelecting, Sendable {
    private let asked = Mutex<[String?]>([])
    var sentences: [String?] { asked.withLock { $0 } }
    func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection {
        asked.withLock { $0.append(sentence) }
        return .chose(key: candidates[0].key, margin: 1, entryID: candidates[0].entryID)
    }
}
