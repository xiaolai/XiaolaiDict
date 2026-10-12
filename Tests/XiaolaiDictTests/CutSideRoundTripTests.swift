import Capture
import CaptureModel
import DictionaryModel
import Foundation
import MacCapture
import StudyKit
@testable import StudyModels
import Testing
@testable import XiaolaiDict
@testable import XiaolaiDictUI
import XiaolaiDictCore
import XiaolaiDictTestSupport

/// **The side a sentence was cut on, from the capture to the ledger and back onto a reopened card** (schema 14).
///
/// Reopened from History or the Library, a reading was rebuilt with no side at all, so the card drew an ellipsis at
/// both ends — or none — whatever the capture had said; and a reading recorded before the side was kept must say only
/// that it may be cut, never where.
@MainActor
struct CutSideRoundTripTests {
    private struct Misses: DictionaryTransport {
        func send(_ request: ServiceRequest) async throws -> ServiceReply { .lookup(LookupAnswer(word: .notFound)) }
        func cancel(reason: String) {}
    }

    private struct NoCorrection: SpellingSuggesting {
        func suggestion(for term: String, language: String?) async -> String? { nil }
    }

    private static let sentence = "the chair stood by the window and"

    private func selection(_ context: CaptureQuality.Context, cut: TextSegmenter.Clipping) throws -> Selection {
        Selection(
            text: "chair", sentence: Self.sentence, rangeInSentence: NSRange(location: 4, length: 5),
            quality: try #require(CaptureQuality(source: .opticalRecognition, confidence: 1, context: context)),
            place: ReadingPlace(bundleID: "com.mitchellh.ghostty", name: "Ghostty"), sentenceCut: cut)
    }

    private func runner(_ panel: RecordingPanel) -> LookupRunner {
        LookupRunner(
            client: DictionaryClient(deadline: Patience.wait, connect: { _ in Misses() }, fallback: { _ in nil }),
            panel: panel, spelling: NoCorrection(), readerEnglish: { nil })
    }

    private func shown(_ panel: RecordingPanel) -> LookupPresentation? {
        guard case .lookup(let shown)? = panel.contents.first else { return nil }
        return shown
    }

    /// **A side the capture did not know stays unknown** — not both ends, which is what the selection made of it.
    @Test func aPossibleCutOnAnUnknownSideStaysUnknown() throws {
        let unknown = try selection(.mayBeCut, cut: [])
        #expect(unknown.sentenceCut == [], "an unknown side was drawn as \(unknown.sentenceCut)")
        #expect(try selection(.complete, cut: [.end]).sentenceCut == [], "a whole sentence was given a cut side")
    }

    /// Start, end, both and unknown: recorded, read back through the ledger the way History and the Library read it,
    /// reopened, and drawn — each as itself.
    @Test(arguments: [TextSegmenter.Clipping.start, .end, [.start, .end], []])
    func eachSideSurvivesBeingRecordedAndReopened(cut: TextSegmenter.Clipping) async throws {
        let path = ScratchFile.path("cut-side")
        defer { ScratchFile.remove(path) }
        let first = RecordingPanel()
        let recording = try #require(await runner(first).run(
            try selection(.mayBeCut, cut: cut), near: .zero, requestedAt: .now, ticket: first.newRequest()))
        #expect(recording.record.contextCut == cut, "the recording carried \(recording.record.contextCut)")

        let recorder = LookupRecorder()
        recorder.start { try LedgerStore(path: path) }
        await recorder.record(recording, request: 1)
        let entries = try Ledger(path: path).recentLookups(
            since: .distantPast, limit: 10, studying: Set(ProbeScript.allCases))
        let reading = try #require(entries.first)
        #expect(reading.sentenceCut == cut, "History read back \(reading.sentenceCut)")
        #expect(reading.cutSideUnknown == cut.isEmpty)

        let reopened = XiaolaiDictApp.selection(reopening: reading)
        #expect(reopened.sentenceCut == cut, "reopened as \(reopened.sentenceCut)")
        #expect(reopened.quality.context == .mayBeCut, "reopened, the possible cut was forgotten")
        let second = RecordingPanel()
        _ = await runner(second).run(reopened, near: .zero, requestedAt: reading.at, ticket: second.newRequest(),
                                     existingLookup: reading.identity)
        let card = try #require(shown(second))
        #expect(card.sentenceCut == cut, "the reopened card was told \(card.sentenceCut)")
        #expect(card.sentenceCutSideUnknown == cut.isEmpty, "unknown and known were not told apart on the card")
    }

    /// **The ellipsis goes on the known side, and nowhere for an unknown one** — and where the card's own window already
    /// cut the start off, its `…` is the one there.
    @Test func theEllipsisIsDrawnOnTheKnownSideOnly() {
        func drawn(_ cut: TextSegmenter.Clipping, startAlreadyCut: Bool = false) -> String {
            String(CutEllipsis.applied(to: AttributedString("words"), cut: cut, startAlreadyCut: startAlreadyCut).characters)
        }
        #expect(drawn(.start) == "…words")
        #expect(drawn(.end) == "words…")
        #expect(drawn([.start, .end]) == "…words…")
        #expect(drawn([]) == "words", "an unknown side was drawn as a cut")
        #expect(drawn(.start, startAlreadyCut: true) == "words", "two ellipses at the start")
    }
}
