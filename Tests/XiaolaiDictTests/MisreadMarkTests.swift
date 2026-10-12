import AppKit
import CaptureModel
import DictionaryModel
import Foundation
import StudyKit
import SwiftUI
import Testing
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictTestSupport
@testable import XiaolaiDictUI

/// **A sentence read off the screen with a misread's signs is said to be one wherever it is shown** (2026-10-11): the
/// lookup card says why it withheld the sentence, and History marks the sentence it keeps "Possibly misread from the
/// screen" — each **whatever the reader's "read off the screen" switch says**, which is off here in every test.
///
/// Seen by the height a notice adds to a hosted card, the way `SpellingSuggestionLineTests` sees its line: neither card
/// is glass or a grouped `Form`, so its fitting size is a measurement (AGENTS.md).
@MainActor
struct MisreadMarkTests {
    private static let garbled = "comfortable (1TÆ฿J)"
    private static let optical = CaptureQuality(source: .opticalRecognition, confidence: 1, context: .complete)!
    private static let switchOff = CardOptions(warnsAboutScreenReading: false)

    private func height(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view.environment(\.scale, Scale.standard)
            .environment(\.cardOptions, Self.switchOff))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func lookup(_ outcome: LookupOutcome, misread: Bool) -> some View {
        var presentation = LookupPresentation(
            request: 3, term: "comfortable", lemma: Lemma(text: "comfortable", basis: .surface), source: "Terminal",
            capture: Self.optical, sentence: nil, outcome: outcome)
        presentation.sentenceLooksMisread = misread
        return LookupPanelContent(presentation: presentation)
    }

    /// **On a miss and on an entry alike, with the switch off.** It was drawn only beside an entry: a miss withheld
    /// its sentence and said nothing.
    @Test(arguments: [false, true])
    func theLookupCardSaysTheSentenceLooksMisreadWithTheSwitchOff(found: Bool) {
        let outcome: LookupOutcome = found
            ? .entries(NonEmpty([sampleEntry("New Oxford American Dictionary")])!, unreadable: [])
            : .notFound(serviceFailure: nil)
        let clean = height(lookup(outcome, misread: false)), doubted = height(lookup(outcome, misread: true))
        #expect(clean > 0, "the card laid out to nothing")
        #expect(doubted > clean, "no notice with the switch off: \(clean) then \(doubted)")
    }

    private func history(_ sentence: String, quality: CaptureQuality) -> some View {
        let range = (sentence as NSString).range(of: "comfortable")
        return ReadingCardView(entry: ReadingEntry(
            id: 1, lemma: "comfortable", surface: "comfortable", sentence: sentence, sentenceRange: range,
            place: ReadingPlace(name: "Terminal"), at: .distantPast, result: .found, quality: quality))
            .frame(width: 360)
    }

    /// **History marks the sentence it keeps, with the switch off** — and the same characters from an app's own text
    /// are not marked: the label is the misread's, not the characters'.
    @Test func historyMarksAMisreadSentenceWithTheSwitchOff() {
        let marked = height(history(Self.garbled, quality: Self.optical))
        let ownText = height(history(Self.garbled, quality: .accessibility(.accessibilityTextRange, context: .complete)))
        #expect(ownText > 0, "the card laid out to nothing")
        #expect(marked > ownText, "no mark on a misread sentence: \(ownText) then \(marked)")
    }

    /// The label's words, read from the source as the catalog will carry them.
    @Test func theLabelSaysPossiblyMisreadFromTheScreen() throws {
        let source = try String(contentsOf: AppModules.repository.appending(path: "Sources/XiaolaiDictUI/ReadingCardComponents.swift"),
                                encoding: .utf8)
        #expect(source.contains("StatusLabel(.caution, \"Possibly misread from the screen\""))
    }
}
