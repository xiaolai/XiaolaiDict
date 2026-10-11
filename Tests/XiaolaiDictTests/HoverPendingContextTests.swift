import AppKit
import Capture
import CaptureModel
import DictionaryModel
@testable import MacCapture
import Synchronization
import Testing
import XiaolaiDictTestSupport

/// **A pixel read answers with its first strip, and the rest of the sentence follows** (C1, 2026-10-11). The capture
/// guard is held until the taller strip is read — never two captures at once — and the reading is let go when the
/// context is.
@MainActor
struct HoverPendingContextTests {
    static let window = ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 5)

    nonisolated static func recognition(_ sentence: String, mayBeCut: Bool) -> Recognition {
        let range = (sentence as NSString).range(of: "fine")
        return Recognition(
            word: WordAtPoint(word: "fine", sentence: SentenceContext(
                text: sentence, mayBeCut: mayBeCut, selection: range, cut: mayBeCut ? .end : [])!),
            confidence: 1, mayBeCut: mayBeCut, appName: "Ghostty", bundleID: "com.mitchellh.ghostty")
    }

    private func reader(_ screen: ScriptedScreenWords, released: @escaping @MainActor () -> Void = {}) -> HoverReader {
        let reader = HoverReader(policy: { .shipped }, captureDeadline: HoverFixtures.patient, source: screen)
        reader.onCaptureReleased = released
        return reader
    }

    private func read(_ reader: HoverReader) async -> HoverReader.Outcome {
        await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                          pointerStillFor: .seconds(1), begin: { 1 })
    }

    private func screen(growing gate: GrowthGate?) -> ScriptedScreenWords {
        let screen = ScriptedScreenWords()
        screen.windows = [Self.window]
        var first = Self.recognition("He paid the fine and", mayBeCut: true)
        if let gate {
            first.growth = {
                await gate.held()
                return Task.isCancelled ? nil : Self.recognition("Before leaving, he paid the fine and went home.", mayBeCut: false)
            }
        }
        screen.recognition = .success(first)
        return screen
    }

    /// **The word is delivered while the taller strip is still being read**, and no other capture starts until it is.
    @Test func theFirstStripAnswersAndTheCaptureIsHeldUntilTheContextSettles() async throws {
        let gate = GrowthGate()
        var releases = 0
        let reader = reader(screen(growing: gate)) { releases += 1 }
        guard case .selection(let selection, _, _, _, let context) = await read(reader) else {
            Issue.record("the first strip's word was not delivered while the context was read")
            return
        }
        #expect(selection.sentence == "He paid the fine and")
        let pending = try #require(context, "a reading still growing was delivered with nothing to wait for")
        #expect(await Patience.until { gate.isWaiting }, "the taller strip was never read")
        guard case .quiet(.captureInFlight) = await read(reader) else {
            Issue.record("a second capture was let start while the taller strip was read")
            return
        }
        #expect(releases == 0)
        gate.open()
        let settled = try #require(await pending.settled(), "the grown reading never arrived")
        #expect(settled.text == "fine")
        #expect(settled.sentence == "Before leaving, he paid the fine and went home.")
        #expect(settled.rangeInSentence == NSRange(location: 28, length: 4))
        #expect(settled.quality.context == .complete)
        #expect(await Patience.until { releases == 1 }, "the capture was never let go")
    }

    /// **A context nobody will show is not read on**: cancelling it lets the capture go.
    @Test func cancellingTheContextLetsTheCaptureGo() async throws {
        let gate = GrowthGate()
        var releases = 0
        let reader = reader(screen(growing: gate)) { releases += 1 }
        guard case .selection(_, _, _, _, let context?) = await read(reader) else {
            Issue.record("no context to cancel")
            return
        }
        #expect(await Patience.until { gate.isWaiting })
        context.cancel()
        #expect(await Patience.until { gate.sawCancellation }, "the taller strip went on being read")
        #expect(await Patience.until { releases == 1 }, "the capture was held for a context nobody will show")
        #expect(await context.settled() == nil)
    }

    /// **A reading with nothing left to read has no context**, and lets the capture go as it always did.
    @Test func aWholeReadingHasNoContext() async throws {
        var releases = 0
        let reader = reader(screen(growing: nil)) { releases += 1 }
        guard case .selection(_, _, _, _, let context) = await read(reader) else {
            Issue.record("no word")
            return
        }
        #expect(context == nil)
        #expect(await Patience.until { releases == 1 })
    }
}

/// The taller strip's read, held until the test opens it — and whether it was given up on.
final class GrowthGate: Sendable {
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
