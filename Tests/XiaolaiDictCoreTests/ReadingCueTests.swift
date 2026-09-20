import Foundation
import XiaolaiDictCore
import Testing

/// What a card may say about the context stored beside a word.
///
/// The ledger stores **the selection itself** when nothing surrounded the word, so the text alone
/// cannot tell a sentence from the word echoed back — and a card that renders both the same way
/// prints the word twice and calls the second copy a sentence. That is the failure
/// `CaptureQuality` exists to prevent: a degraded capture must never read as confidently as a
/// clean one.
struct ReadingCueTests {
    private func entry(
        _ surface: String, sentence: String, quality: CaptureQuality?,
        result: LookupResult = .found
    ) -> ReadingEntry {
        let found = (sentence as NSString).range(of: surface)
        return ReadingEntry(
            id: 1, lemma: surface, surface: surface, sentence: sentence,
            sentenceRange: found.location == NSNotFound ? nil : found,
            place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: result,
            quality: quality)
    }

    private func quality(_ context: CaptureQuality.Context) -> CaptureQuality {
        .accessibility(.accessibilityTextRange, context: context)
    }

    @Test func aCompleteCaptureShowsTheSentenceItWasReadIn() {
        let read = entry("hold", sentence: "The ship's hold was full.", quality: quality(.complete))
        #expect(read.cue == .sentence)
    }

    /// Shown, because a cut sentence is still a cue — but never as a whole one.
    @Test func aSentenceThatMayBeCutIsShownAsCut() {
        let read = entry("hold", sentence: "The ship's hold was", quality: quality(.mayBeCut))
        #expect(read.cue == .truncatedSentence)
    }

    /// The card in the screenshot: `qqqq` printed twice, the second copy marked up as a sentence.
    @Test func aMissingContextIsNotASentenceHoweverItWasStored() {
        let read = entry("qqqq", sentence: "qqqq", quality: quality(.missing))
        #expect(read.cue == .none)
    }

    /// `.missing` is about what was captured, not about what the word happens to be. A lookup on a
    /// word the app could say nothing around is still nothing to show, even when the stored text is
    /// longer than the word.
    @Test func aMissingContextStaysNothingEvenWhenItIsLongerThanTheWord() {
        let read = entry("hold", sentence: "hold the line", quality: quality(.missing))
        #expect(read.cue == .none)
    }

    @Test func nothingCapturedAtAllShowsNothing() {
        #expect(entry("hold", sentence: "", quality: quality(.complete)).cue == .none)
        #expect(entry("hold", sentence: "   ", quality: quality(.complete)).cue == .none)
        #expect(entry("hold", sentence: "", quality: nil).cue == .none)
    }

    // MARK: - Rows written before the quality column existed

    /// Schema-1 rows carry no quality, so the only thing left is to compare the text — and a
    /// sentence that is just the word again is the echo, whatever wrote it.
    @Test func aRowWithoutQualityFallsBackToComparingTheTextWithTheWord() {
        #expect(entry("qqqq", sentence: "qqqq", quality: nil).cue == .none)
        #expect(entry("hold", sentence: "The ship's hold was full.", quality: nil).cue == .sentence)
    }

    @Test func theFallbackIgnoresCaseAndSurroundingSpace() {
        #expect(entry("Temper", sentence: "  temper \n", quality: nil).cue == .none)
    }

    /// The echo is of the *surface* — the word as it was on screen — and the lemma is what the
    /// drawer labels the card with. Either one repeated under itself is the same non-cue.
    @Test func theFallbackCatchesAnEchoOfEitherTheSurfaceOrTheLemma() {
        let inflected = ReadingEntry(
            id: 1, lemma: "hold", surface: "holding", sentence: "holding", sentenceRange: nil,
            place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: .found, quality: nil)
        #expect(inflected.cue == .none)

        let lemmaEcho = ReadingEntry(
            id: 2, lemma: "hold", surface: "holding", sentence: "hold", sentenceRange: nil,
            place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: .found, quality: nil)
        #expect(lemmaEcho.cue == .none)
    }

    /// A known-good capture is believed over the text: the reader really did read the word in a
    /// one-word sentence, and the ledger says so.
    @Test func aCompleteCaptureIsBelievedOverTheTextComparison() {
        let read = entry("Stop", sentence: "Stop.", quality: quality(.complete))
        #expect(read.cue == .sentence)
    }

    /// A miss is still a lookup, and its sentence is still the reader's own. Whether there is a
    /// cue to show has nothing to do with whether the word was found.
    @Test func aMissKeepsTheSentenceItWasMissedIn() {
        let read = entry(
            "teh", sentence: "I wrote teh instead of the.", quality: quality(.complete),
            result: .notFound)
        #expect(read.cue == .sentence)
    }
}
