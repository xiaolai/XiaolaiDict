import AppKit
import DictionaryModel
import SwiftUI
import Testing
import XiaolaiDictCore
@testable import XiaolaiDictUI

/// **The WI-4 text on the default card, behind a disclosure of its own** (the owner's decision of 2026-10-09; D5: never
/// shown by default). What the disclosure holds is a value, `SenseDetails`, so its rules are asked here; the view is
/// measured only for what a test can see of it — that the text is not drawn while the disclosure is closed, and is
/// drawn when it is open.
@MainActor
struct SenseDetailsTests {
    private static let rich = SenseDisplay(
        translations: [.init(text: "公平的", indicator: "(just)"), .init(text: "公正的", indicator: nil)],
        indicators: [], englishDefinition: "treating people equally", notes: ["［作表語］"])
    /// A bilingual sense whose one translation is its label: nothing beyond it.
    private static let bare = SenseDisplay(
        translations: [.init(text: "美好的", indicator: nil)], indicators: [], englishDefinition: nil, notes: [])

    private static func sense(
        _ block: Int, _ ordinal: Int, _ label: String, display: SenseDisplay?, part: String = "adjective"
    ) -> DictionarySense {
        DictionarySense(path: SensePath(block: block, ordinal: ordinal), key: "e1.\(block).\(ordinal)",
                        keyKind: .position, definition: label, text: "\(label) — an example", display: display)
    }

    private static func entry(_ blocks: [(String, [DictionarySense])], name: String = "牛津英汉汉英词典") -> DictionaryEntry {
        let document = EntryDocument(
            isStyled: true, entryID: "e1", homograph: nil,
            blocks: blocks.enumerated().map { SenseBlock(number: $0.offset + 1, partOfSpeech: $0.element.0, senses: $0.element.1) })
        return DictionaryEntry(dictionary: DictionaryIdentity(name: name, identifier: name), headword: "fair",
                               lookedUp: "fair", html: "<p/>", document: document)
    }

    private static func card(_ entry: DictionaryEntry, mark: SenseMark? = nil) -> LookupCard {
        LookupCard(presentation: EntryPresentation(entry: entry, mark: mark, met: []), term: "fair",
                   sentence: "It was a fair price.", mark: mark)
    }

    /// **A lone translation the label cuts short is in the details**, its whole text (audit of 2026-10-10) — while one the
    /// label shows whole is not.
    @Test func aLoneTranslationTheLabelCutsShortIsInTheDetails() {
        let long = String(repeating: "公平合理而不偏不倚的", count: 8)
        let lone = SenseDisplay(translations: [.init(text: long, indicator: nil)], indicators: [], englishDefinition: nil,
                                notes: [])
        let entry = Self.entry([("adjective", [Self.sense(1, 1, long, display: lone), Self.sense(1, 2, "美好的", display: Self.bare)])])
        let details = Self.card(entry).details
        #expect(details.groups.flatMap(\.rows).map(\.ordinal) == [1])
        #expect(details.groups.first?.rows.first?.lines == SenseDisplayLines.of(lone))
    }

    /// **Every sense with something beyond its label, the leading one included, in the entry's order and blocks** —
    /// and nothing for a sense with no display data or with only its label again.
    @Test func theDetailsHoldEverySenseWithSomethingBeyondItsLabel() {
        let entry = Self.entry([
            ("adjective", [Self.sense(1, 1, "公平的", display: Self.rich), Self.sense(1, 2, "美好的", display: Self.bare)]),
            ("adverb", [Self.sense(2, 1, "公正地", display: Self.rich), Self.sense(2, 2, "顺利地", display: nil)]),
        ])
        let card = Self.card(entry, mark: .chosen(key: "e1.1.1", by: .reader))
        #expect(card.leadingSense?.key == "e1.1.1")
        let details = card.details
        #expect(details.groups.map(\.block) == [1, 2])
        #expect(details.groups.map { $0.rows.map(\.ordinal) } == [[1], [1]])
        #expect(details.groups[0].rows[0].lines == SenseDisplayLines.of(Self.rich))
        #expect(details.namesGroups)
    }

    @Test func aMonolingualEntryHasNoDetails() {
        let entry = Self.entry([("noun", [Self.sense(1, 1, "a sense", display: nil), Self.sense(1, 2, "another", display: nil)])],
                               name: "New Oxford American Dictionary")
        #expect(Self.card(entry).details.isEmpty)
        #expect(Self.card(entry).detailsDisclosure(inCompactExpansion: false) == nil)
    }

    /// **Not twice**: the compact card's expansion already draws the same text in `DictionaryDetailsView`.
    @Test func theCompactExpansionDoesNotOfferItAgain() {
        let card = Self.card(Self.entry([("adjective", [Self.sense(1, 1, "公平的", display: Self.rich)])]))
        #expect(card.detailsDisclosure(inCompactExpansion: false) == card.details)
        #expect(card.detailsDisclosure(inCompactExpansion: true) == nil)
    }

    /// **Labels, keys and hashes unchanged** — the display data is beside them and never in them.
    @Test func theDetailsChangeNoLabelKeyOrHash() {
        let with = Self.sense(1, 1, "公平的", display: Self.rich), without = Self.sense(1, 1, "公平的", display: nil)
        #expect(with.label == without.label && with.key == without.key && with.textHash == without.textHash)
        let a = EntryPresentation(entry: Self.entry([("adjective", [with])]), mark: nil, met: []).senses[0]
        let b = EntryPresentation(entry: Self.entry([("adjective", [without])]), mark: nil, met: []).senses[0]
        #expect(a.label == b.label && a.key == b.key && a.keyKind == b.keyKind)
        #expect(a.display == Self.rich && b.display == nil, "the presentation dropped the display data")
    }

    private func height<V: View>(_ view: V) -> CGFloat {
        let hosted = NSHostingView(rootView: view.environment(\.scale, Scale.standard).frame(width: 396))
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize.height
    }

    /// **Closed, nothing of it is drawn**: however much the details hold, the closed card is the same height — and the
    /// card with details is taller than the one without by its disclosure row alone.
    @Test func closedTheCardDrawsNoneOfTheDetails() {
        let long = SenseDisplay(
            translations: (1...12).map { .init(text: "译名\($0)", indicator: "(sense \($0))") },
            indicators: ["a long indicator"], englishDefinition: "a definition", notes: ["a note", "another note"])
        func card(_ display: SenseDisplay?) -> LookupCardView {
            LookupCardView(card: Self.card(Self.entry([("adjective", [Self.sense(1, 1, "公平的", display: display)])])))
        }
        let none = height(card(nil)), short = height(card(Self.rich)), longer = height(card(long))
        #expect(none > 0, "the card laid out to nothing, so nothing below measures anything")
        #expect(short > none, "the card with details has no disclosure row")
        #expect(short == longer, "the closed card drew some of its details: \(short) against \(longer)")
    }

    /// **Open, it draws the lines** — more lines, a taller view; and a positive control that it draws at all.
    @Test func openTheDetailsDrawTheirLines() {
        let one = SenseDetails(senses: EntryPresentation(
            entry: Self.entry([("adjective", [Self.sense(1, 1, "公平的", display: Self.rich)])]), mark: nil, met: []).senses)
        let two = SenseDetails(senses: EntryPresentation(
            entry: Self.entry([("adjective", [Self.sense(1, 1, "公平的", display: Self.rich),
                                              Self.sense(1, 2, "公正的", display: Self.rich)])]), mark: nil, met: []).senses)
        let a = height(SenseDetailsView(details: one)), b = height(SenseDetailsView(details: two))
        #expect(a > 0)
        #expect(b > a, "a second sense's lines drew nothing: \(a) then \(b)")
    }
}
