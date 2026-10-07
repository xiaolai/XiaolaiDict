import AppKit
import CaptureModel
import DictionaryModel
import SwiftUI
import Testing
import XiaolaiDictBase
import XiaolaiDictCore
@testable import XiaolaiDictUI

struct CompactLookupTests {
    private func sense(_ key: String, _ label: String, partOfSpeech: String = "verb",
                       standing: SenseStanding = .unclaimed) -> SensePresentation {
        SensePresentation(key: key, block: 1, ordinal: 1, partOfSpeech: partOfSpeech, label: label,
                          keyKind: .publisher, standing: standing, metBefore: false)
    }

    private func card(_ answer: LookupCard.Answer, alternatives: [SensePresentation]) -> LookupCard {
        LookupCard(term: "refused", lemma: "refuse", heading: "refuse", partOfSpeech: "verb",
                   pronunciation: "/rɪˈfjuːz/", answer: answer,
                   sentence: "They refused to sign.", alternatives: alternatives)
    }

    @Test func aConfirmedMeaningLeadsWithoutDiscardingOtherMeanings() {
        let chosen = sense("chosen", "拒绝", standing: .confirmed(.reader))
        let other = (1...6).map { sense("other-\($0)", "other meaning \($0)") }
        let original = card(.sense(chosen), alternatives: other)
        let quick = CompactLookupSummary(card: original)
        #expect(quick.senses.first == chosen)
        #expect(quick.senses.count == 3)
        #expect(quick.groups.map(\.partOfSpeech) == ["v."])
        #expect(quick.groups.first?.labels == ["拒绝", "other meaning 1", "other meaning 2"])
        #expect(!quick.isUncertain)
        #expect(original.alternatives == other, "the quick preview must not truncate the detailed card")
        #expect(original.senseToKeep?.standing == .confirmed)
    }

    @Test func anAbstentionShowsDictionaryMeaningsWithoutPromotingOne() {
        let original = card(.undecided(reason: nil), alternatives: [sense("a", "拒绝"), sense("b", "拒收")])
        let quick = CompactLookupSummary(card: original)
        #expect(quick.senses.map(\.label) == ["拒绝", "拒收"])
        #expect(quick.groups.first?.text == "拒绝；拒收")
        #expect(quick.isUncertain)
        #expect(original.leadingSense == nil)
        #expect(original.senseToKeep == nil)
    }

    /// **The separator belongs to the script of the meanings, not to the app.** A fullwidth semicolon between two
    /// English definitions reads as a typo; between two Chinese glosses it is the right mark.
    @Test func meaningsAreJoinedWithTheSemicolonTheirScriptUses() {
        let english = card(.undecided(reason: nil), alternatives: [sense("a", "to say no"), sense("b", "to turn down")])
        #expect(CompactLookupSummary(card: english).groups.first?.text == "to say no; to turn down")
        let chinese = card(.undecided(reason: nil), alternatives: [sense("a", "拒绝"), sense("b", "拒收")])
        #expect(CompactLookupSummary(card: chinese).groups.first?.text == "拒绝；拒收")
        // One CJK gloss among others is enough: the line is set in that script.
        let mixed = card(.undecided(reason: nil), alternatives: [sense("a", "拒绝"), sense("b", "to turn down")])
        #expect(CompactLookupSummary(card: mixed).groups.first?.text == "拒绝；to turn down")
    }

    @Test func guessesKeepTheirCaveatInTheQuickPreviewAndCopiedText() {
        let guess = sense("guess", "拒绝", standing: .proposed)
        for answer in [LookupCard.Answer.sense(guess), .ambiguous(guess, among: 2)] {
            let original = card(answer, alternatives: [sense("b", "拒收")])
            #expect(CompactLookupSummary(card: original).isUncertain)
            #expect(original.copyableText?.contains("a guess, not confirmed") == true)
        }
    }

    @Test func duplicateDefinitionsLeaveRoomForDistinctPartsOfSpeech() {
        let original = card(.undecided(reason: nil), alternatives: [
            sense("empty", "  "), sense("a", "继续", partOfSpeech: "transitive verb"),
            sense("repeat", " 继续 ", partOfSpeech: "intransitive verb"),
            sense("adj", "拒绝", partOfSpeech: "adjective"), sense("b", "拒收"),
        ])
        let quick = CompactLookupSummary(card: original)
        #expect(quick.senses.map(\.key) == ["a", "adj", "b"])
        #expect(quick.groups.map(\.partOfSpeech) == ["v.", "adj."])
        #expect(quick.groups.map(\.text) == ["继续；拒收", "拒绝"])
        #expect(original.alternatives[2].partOfSpeech == "intransitive verb")
        #expect(original.alternatives.count == 5)
    }

    @Test func proseAndMissingEntriesDoNotAcquireInventedSenses() {
        for answer in [LookupCard.Answer.prose("拒绝"), .absent] {
            let quick = CompactLookupSummary(card: card(answer, alternatives: []))
            #expect(quick.senses.isEmpty)
            #expect(!quick.isUncertain)
        }
    }
}

@MainActor
struct CompactLookupLayoutTests {
    private func presentation(sentence: String = "They refused to sign.") -> LookupPresentation {
        let senses = (1...6).map {
            DictionarySense(path: SensePath(block: 1, ordinal: $0), key: "sense-\($0)", keyKind: .publisher,
                            definition: "拒绝；不接受 \($0)",
                            text: "拒绝；不接受 \($0)。They refused to sign. 他们拒绝签字。")
        }
        let entry = DictionaryEntry(
            dictionary: DictionaryIdentity(name: "Example dictionary"), headword: "refuse",
            lookedUp: "refused", html: "<html/>", document: EntryDocument(
                isStyled: true, entryID: "refuse", homograph: nil,
                blocks: [SenseBlock(number: 1, partOfSpeech: "verb", senses: senses)],
                pronunciations: ["/rɪˈfjuːz/"]))
        return LookupPresentation(
            request: 1, term: "refused", lemma: Lemma(text: "refuse", basis: .tagger), source: nil,
            capture: .accessibility(.accessibilityTextRange, context: .complete), sentence: sentence,
            outcome: .entries(NonEmpty([entry])!, unreadable: []))
    }

    private func size(_ presentation: LookupPresentation, expanded: Bool = false,
                      textSize: TextSize = .standard, compact: Bool = true,
                      scheme: ColorScheme = .light) -> CGSize {
        let view = NSHostingView(rootView: LookupPanelContent(
            presentation: presentation, detailsInitiallyExpanded: expanded)
            .environment(\.scale, Scale(textSize))
            .environment(\.cardOptions, CardOptions(usesCompactLookup: compact))
            .environment(\.colorScheme, scheme))
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    @Test func theCompactCardIsNarrowerAndShorterThanItsDetails() {
        let quick = size(presentation()), detail = size(presentation(), expanded: true)
        #expect(quick.width > 0 && quick.height > 0)
        #expect(quick.width < detail.width)
        #expect(quick.height < detail.height)
    }

    @Test func theExistingReadingCardRemainsTheDefault() {
        #expect(!CardOptions().usesCompactLookup)
        let original = size(presentation(), compact: false)
        let quick = size(presentation())
        #expect(original.width > quick.width)
        #expect(original.height > quick.height)
    }

    @Test func darkAppearanceKeepsTheSameLayoutAtEveryTextSize() {
        for textSize in TextSize.allCases {
            #expect(size(presentation(), textSize: textSize, scheme: .light)
                    == size(presentation(), textSize: textSize, scheme: .dark))
        }
    }

    @Test func aLongContextDoesNotCrowdTheQuickLookup() {
        let short = size(presentation())
        let long = size(presentation(sentence: String(repeating: "They refused to sign. ", count: 60)))
        #expect(short == long)
    }

    @Test func largerTextRemainsReadableInsideABoundedPanel() {
        let standard = size(presentation())
        let large = size(presentation(), textSize: .large)
        #expect(large.width > standard.width)
        #expect(large.height > standard.height)
        #expect(large.height <= Scale(.large).space.cardMaxHeight + Token.Panel.cardChrome)
    }

    /// Optional review artifacts use synthetic senses, without copying a publisher's entry.
    @Test func originalCompactAndExpandedCardsRenderInBothAppearances() throws {
        let transitive = DictionarySense(
            path: SensePath(block: 1, ordinal: 1), key: "continue.vt", keyKind: .publisher,
            definition: "继续", text: "继续。She continues her research. 她继续开展研究。")
        let lasting = DictionarySense(
            path: SensePath(block: 2, ordinal: 1), key: "continue.vi.1", keyKind: .publisher,
            definition: "持续", text: "持续。The discussion continues. 讨论仍在继续。")
        let continuing = DictionarySense(
            path: SensePath(block: 2, ordinal: 2), key: "continue.vi.2", keyKind: .publisher,
            definition: "继续", text: "继续。The story continues tomorrow. 故事明天继续。")
        let entry = DictionaryEntry(
            dictionary: DictionaryIdentity(name: "Example dictionary"), headword: "continue",
            lookedUp: "continues", html: "<html/>", document: EntryDocument(
                isStyled: true, entryID: "continue", homograph: nil,
                blocks: [SenseBlock(number: 1, partOfSpeech: "transitive verb", senses: [transitive]),
                         SenseBlock(number: 2, partOfSpeech: "intransitive verb", senses: [lasting, continuing])],
                pronunciations: ["/kənˈtɪnjuː/"]))
        let example = LookupPresentation(
            request: 2, term: "continues", lemma: Lemma(text: "continue", basis: .tagger), source: nil,
            capture: .accessibility(.accessibilityTextRange, context: .complete),
            sentence: "The discussion continues.", outcome: .entries(NonEmpty([entry])!, unreadable: []))
        let directory = ProcessInfo.processInfo.environment["COMPACT_LOOKUP_ARTIFACTS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            for (kind, compact, expanded) in [("original", false, false), ("compact", true, false), ("expanded", true, true)] {
                let view = NSHostingView(rootView: LookupPanelContent(
                    presentation: example, detailsInitiallyExpanded: expanded)
                    .environment(\.scale, Scale.standard)
                    .environment(\.cardOptions, CardOptions(usesCompactLookup: compact))
                    .environment(\.colorScheme, scheme))
                view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                view.layoutSubtreeIfNeeded()
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 1000)
                if let directory {
                    try png.write(to: directory.appending(path: "\(kind)-\(name).png"))
                }
            }
        }
    }
}
