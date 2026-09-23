import Foundation
import Testing
@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// The translation pane says which engine answered. Apple's framework is measured to be the weaker
/// engine, and an answer of its drawn unlabelled would look exactly as sure as the model's.
struct TranslationPaneTests {
    /// **The weaker-engine label appears whenever the fallback answered, and never otherwise** —
    /// every outcome, both ways.
    @Test(arguments: [
        (TranslationOutcome.translated("船的船满了。", by: .appleTranslation), true),
        (.translated("这艘船的货舱装满了。", by: .localModel), false),
        (.needsLanguagePack(source: "en", target: "zh-Hans"), false),
        (.sameLanguage, false),
        (.unavailable, false),
    ])
    func theWeakerEngineIsLabelledExactlyWhenItAnswered(outcome: TranslationOutcome, labelled: Bool) {
        let pane = TranslationPane(outcome, of: Self.key)
        #expect((pane.caveat != nil) == labelled, "\(outcome)")
    }

    /// The label says what it means for this sentence, in the reader's terms.
    @Test func theLabelSaysWhatTheWeakerEngineCannotDo() throws {
        let caveat = try #require(TranslationPane(.translated("x", by: .appleTranslation), of: Self.key).caveat)
        #expect(caveat.contains("which sense"))
        #expect(caveat.contains("misreads"))
    }

    /// The download sits beside Apple's answer — and nowhere near the model's, which is the model.
    /// Whether one can be started is read live at the button; this says only which answers invite it.
    @Test func theDownloadIsOfferedBesideTheFallbackOnly() {
        #expect(TranslationPane(.translated("x", by: .appleTranslation), of: Self.key).offersDownload)
        #expect(TranslationPane(.unavailable, of: Self.key).offersDownload)
        #expect(!TranslationPane(.translated("x", by: .localModel), of: Self.key).offersDownload)
        #expect(!TranslationPane(.sameLanguage, of: Self.key).offersDownload)
    }

    /// **A pane belongs to one card.** Switching dictionaries, or a sense arriving late, makes a
    /// different card — and a translation about the old one is not about this one.
    @Test func aPaneKnowsWhichCardItIsAbout() {
        let pane = TranslationPane(.translated("货舱", by: .localModel), of: Self.key)
        #expect(pane.of == Self.key)
        for other in [
            TranslationPane.Key(sentence: "another sentence", target: "zh-Hans", dictionary: "NOAD", sense: "cargo"),
            TranslationPane.Key(sentence: "s", target: "ja", dictionary: "NOAD", sense: "cargo"),
            TranslationPane.Key(sentence: "s", target: "zh-Hans", dictionary: "Longman", sense: "cargo"),
            TranslationPane.Key(sentence: "s", target: "zh-Hans", dictionary: "NOAD", sense: nil),
        ] {
            #expect(pane.of != other)
        }
    }

    /// A missing language pack is said **and offered**: the pane takes the reader to where it is
    /// added, and no other outcome does.
    @Test func aMissingLanguagePackIsOffered() throws {
        #expect(TranslationPane(.needsLanguagePack(source: "en", target: "zh-Hans"), of: Self.key).opensLanguageSettings)
        for outcome in [TranslationOutcome.translated("x", by: .appleTranslation), .translated("x", by: .localModel),
                        .sameLanguage, .unavailable] {
            #expect(!TranslationPane(outcome, of: Self.key).opensLanguageSettings)
        }
        #expect(try #require(TranslationPane.languageSettings).scheme == "x-apple.systempreferences")
    }

    /// Each lookup is its own view: what the reader revealed for one word — a translation — must not
    /// be drawn under the next. Read from the source, because SwiftUI cannot be asked a view's id.
    @Test func eachLookupIsItsOwnView() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appending(path: "Sources/XiaolaiDictUI/LookupPanelViews.swift"), encoding: .utf8)
        #expect(panel.contains(".id(presentation.request)"), "a lookup's view outlives it into the next")
    }

    private static let key = TranslationPane.Key(
        sentence: "s", target: "zh-Hans", dictionary: "NOAD", sense: "cargo")

    private static func card(_ answer: LookupCard.Answer) -> LookupCard {
        LookupCard(term: "hold", heading: "hold", partOfSpeech: "noun", pronunciation: nil,
                   answer: answer, sentence: "The ship's hold was full.", alternatives: [])
    }

    private static var cargo: SensePresentation {
        SensePresentation(
            key: "m_en_gbus0472980.005", ordinal: 1, partOfSpeech: "noun",
            label: "a large space in the lower part of a ship in which cargo is stored",
            keyKind: .publisher, standing: .proposed, metBefore: false)
    }

    /// **The chosen sense reaches the translator** — the sense the card leads with, in its own words.
    @Test func theQuestionCarriesTheSenseTheCardLeadsWith() {
        let question = TranslationQuestion.reading(
            Self.card(.sense(Self.cargo)), sentence: "The ship's hold was full.", target: "zh-Hans")
        #expect(question.met?.sense == Self.cargo.label)
        #expect(question.met?.term == "hold")
        #expect(question.target == "zh-Hans")
        #expect(question.sentence == "The ship's hold was full.")
    }

    /// A card that admitted it does not know hands the translator no guess.
    @Test func anUnsureCardHandsTheTranslatorNoSense() {
        for answer in [LookupCard.Answer.ambiguous(Self.cargo, among: 3), .undecided(reason: nil), .absent] {
            #expect(TranslationQuestion.reading(Self.card(answer), sentence: "s", target: "zh-Hans").met == nil)
        }
    }
}
