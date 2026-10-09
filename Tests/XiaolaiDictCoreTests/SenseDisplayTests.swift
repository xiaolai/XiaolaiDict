import DictionaryModel
import Foundation
import Testing

/// **What a bilingual sense says beyond its label, kept apart from what keys it** (plan-card-refinements WI-4).
///
/// Measured (§6): the card's label is the first `d:def`, so 牛津英汉汉英 and 譯典通 show one translation of several in 18%
/// and 40% of senses, 牛津粵英雙語 never shows its English definition, and the English sense indicators are dropped in 78%.
/// `label`, `text`, `definition` and `textHash` feed the saved gloss and the hash and may not change, so the rest is
/// read in the same walk into separate display data. The fixtures are each dictionary's sense skeleton, measured, with
/// stand-in words.
struct SenseDisplayTests {
    private static func entry(_ sense: String) -> String {
        """
        <d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng" id="e1" d:title="fair">\
        <span class="x_xd0"><span class="x_xd1" id="e1.001">\(sense)</span></span></d:entry>
        """
    }

    private static func sense(_ sense: String) throws -> DictionarySense {
        try #require(EntryDocument.parse(entry(sense))?.senses.first)
    }

    /// 牛津英汉汉英: a translation group per reading, each with its own indicator and its pinyin; examples after.
    static let simplified = """
        <span class="sn">①</span>\
        <span class="trg x_xd2"><span class="ind">(just)</span><span class="trans" d:def="1">甲</span>\
        <span class="trans ty_pinyin">jiǎ</span></span>\
        <span class="trg x_xd2"><span class="ind">(honest)</span><span class="trans">乙</span></span>\
        <span class="exg x_xd2"><span class="ex">an example</span><span class="trg x_xd3"><span class="trans">例</span></span></span>
        """

    /// 牛津粵英雙語: the indicator and the English definition beside one translation group.
    static let cantonese = """
        <span class="sn">1</span><span class="msDict x_xd2"><span class="x_xdh"><span class="ind">just, reasonable</span>\
        <span class="cg"><span class="co">trial</span></span></span>\
        <span class="df x_xd3">Treating people equally</span>\
        <span class="eg x_xd3"><span class="ex">They did</span></span>\
        <span class="trg x_xd3" d:def="1"><span class="trans">丙</span></span>\
        <span class="eg x_xd3"><span class="ex">it is not</span><span class="trg x_xd4"><span class="trans">例</span></span></span></span>
        """

    /// 譯典通: one group per translation, separated by "；", and a grammar note.
    static let traditional = """
        <span class="sn x_xdh">1</span><span class="msDict x_xd2"><span class="x_xdh">\
        <span class="trg"><span class="trans" d:def="1">丁</span><span>；</span></span>\
        <span class="trg"><span class="trans">戊</span><span>；</span></span>\
        <span class="trg"><span class="trans">己</span></span></span>\
        <span class="gg">［後接to-v］</span>\
        <span class="eg x_xd3"><span class="ex">That is</span><span class="trg x_xd4"><span class="trans">例</span></span></span></span>
        """

    @Test func everyTranslationIsKeptWithItsOwnIndicatorAndNoPinyinOrExample() throws {
        let display = try #require(try Self.sense(Self.simplified).display)
        #expect(display.translations == [
            SenseDisplay.Translation(text: "甲", indicator: "(just)"),
            SenseDisplay.Translation(text: "乙", indicator: "(honest)"),
        ])
        #expect(display.englishDefinition == nil)
    }

    @Test func theEnglishDefinitionAndIndicatorAreKept() throws {
        let display = try #require(try Self.sense(Self.cantonese).display)
        #expect(display.englishDefinition == "Treating people equally")
        #expect(display.indicators == ["just, reasonable"])
        #expect(display.translations == [SenseDisplay.Translation(text: "丙", indicator: nil)])
    }

    @Test func eachSeparatedTranslationAndTheGrammarNoteAreKept() throws {
        let display = try #require(try Self.sense(Self.traditional).display)
        #expect(display.translations.map(\.text) == ["丁", "戊", "己"])
        #expect(display.notes == ["［後接to-v］"])
    }

    /// **Nothing that keys the reader's history moves**: the label, definition, text and hash are what they were
    /// before the display data existed — the first `d:def`, and the whole sense as text.
    @Test func theKeyLabelTextAndHashAreUnchanged() throws {
        let sense = try Self.sense(Self.simplified)
        #expect(sense.definition == "甲")
        #expect(sense.label == "甲")
        #expect(sense.key == "e1.001")
        #expect(sense.text == "①(just)甲jiǎ(honest)乙an example例")
        #expect(sense.textHash == DictionarySense(path: sense.path, key: sense.key, keyKind: sense.keyKind,
                                                  definition: sense.definition, text: sense.text).textHash)
    }

    /// A monolingual sense has nothing beyond its label to show: no display data, so the card is today's.
    @Test func aMonolingualSenseHasNoDisplayData() throws {
        let sense = try Self.sense(#"<span class="df" d:def="1">a meaning</span>"#)
        #expect(sense.display == nil)
        // NOAD's subsense definitions are `df` without `d:def`, and its grammar is `gg`: measured, 849 of 4,417 senses
        // in its first 3,000 entries would have carried display data the monolingual card has no use for.
        let noad = try Self.sense(#"<span class="gg">[with object]</span><span class="df" d:def="1">a meaning</span>"#
            + #"<span class="x_xd1sub"><span class="df">a narrower meaning</span></span>"#)
        #expect(noad.display == nil, "a monolingual sense was given display data")
    }

    /// **Backward compatible on the wire**: a sense encoded before the field existed decodes with none, and one with
    /// it round-trips.
    @Test func displayDataDecodesWhenAbsentAndRoundTrips() throws {
        let sense = try Self.sense(Self.traditional)
        let encoded = try JSONEncoder().encode(sense)
        #expect(try JSONDecoder().decode(DictionarySense.self, from: encoded) == sense)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["display"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DictionarySense.self, from: old)
        #expect(decoded.display == nil)
        #expect(decoded.textHash == sense.textHash && decoded.label == sense.label)
    }
}
