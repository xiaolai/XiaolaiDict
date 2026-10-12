import AppKit
import DictionaryModel
import SwiftUI
import Testing
@testable import XiaolaiDictUI

/// **What the expand draws from a bilingual sense's display data** (plan-card-refinements WI-4, D5): every translation
/// with its indicator, then the English definition, then the sense's indicators and notes — and nothing where the sense
/// has no display data, so a monolingual expand is today's.
struct SenseDisplayLinesTests {
    @Test func translationsAreJoinedWithTheirIndicatorsThenTheRest() {
        let display = SenseDisplay(
            translations: [.init(text: "甲", indicator: "(just)"), .init(text: "乙", indicator: nil)],
            indicators: ["just, reasonable"], englishDefinition: "Treating people equally", notes: ["［後接to-v］"])
        #expect(SenseDisplayLines.of(display) == [
            "(just) 甲；乙", "Treating people equally", "just, reasonable", "［後接to-v］",
        ])
    }

    @Test func anEnglishOnlyJoinIsPlain() {
        let display = SenseDisplay(
            translations: [.init(text: "bueno", indicator: nil), .init(text: "justo", indicator: nil)],
            indicators: [], englishDefinition: nil, notes: [])
        #expect(SenseDisplayLines.of(display) == ["bueno; justo"])
    }

    @Test func noDisplayDataDrawsNothing() {
        #expect(SenseDisplayLines.of(nil).isEmpty)
    }
}

/// **The expand draws the display data, and only behind the expand** (D5): the details view grows by it, and a sense
/// without it is drawn exactly as before.
@MainActor
struct SenseDisplayExpandTests {
    private func entry(_ display: SenseDisplay?) -> DictionaryEntry {
        let sense = DictionarySense(path: SensePath(block: 1, ordinal: 1), key: "e1.001", keyKind: .publisher,
                                    definition: "甲", text: "① (just) 甲 an example 例", display: display)
        let document = EntryDocument(isStyled: true, entryID: "e1", homograph: nil,
                                     blocks: [SenseBlock(number: 1, partOfSpeech: "adjective", senses: [sense])])
        return DictionaryEntry(dictionary: DictionaryIdentity(name: "牛津英汉汉英词典", identifier: "hans"),
                               headword: "fair", lookedUp: "fair", html: "<p/>", document: document)
    }

    private func height(_ entry: DictionaryEntry) -> CGFloat {
        let view = NSHostingView(rootView: DictionaryDetailsView(entry: entry).environment(\.scale, Scale.standard)
            .frame(width: 396))
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.height
    }

    @Test func theExpandGrowsByTheDisplayDataAndNothingElseChanges() {
        let display = SenseDisplay(translations: [.init(text: "甲", indicator: "(just)"), .init(text: "乙", indicator: nil)],
                                   indicators: [], englishDefinition: nil, notes: [])
        let without = height(entry(nil)), with = height(entry(display))
        #expect(without > 0, "the details laid out to nothing, so nothing below measures anything")
        #expect(with > without, "the display data drew nothing: \(without) then \(with)")
    }
}
