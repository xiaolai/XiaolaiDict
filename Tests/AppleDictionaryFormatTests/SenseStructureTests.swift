import Foundation
import Testing
@testable import AppleDictionaryFormat

/// What the indexer makes of an entry's structure, on invented markup shaped like the real thing.
struct SenseStructureTests {
    static let profile = DictionaryProfile(identifier: "test", senseDepth: 1)
    static func index(_ xml: String) -> IndexedEntry? {
        EntryIndexer(dictionary: "test", profile: profile).index(xml)
    }

    /// **A part of speech belongs to its own block.**
    ///
    /// `currentPOS` was set when a `d:pos` element closed and never cleared, so a second `x_xd0` block
    /// declaring no part of speech inherited the first one's — reporting a verb sense as a noun. Silent,
    /// and wrong in the direction that matters: anything narrowing candidates by part of speech would
    /// narrow to the wrong ones rather than to none.
    @Test func partOfSpeechIsScopedToItsOwnBlock() {
        let xml = """
            <d:entry id="e1" d:title="wibble"><span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span d:pos="1" class="pos">noun</span>\
            <span id="e1.1" class="x_xd1"><span d:def="1" class="df">a small device</span></span></span>\
            <span class="x_xd0">\
            <span id="e1.2" class="x_xd1"><span d:def="1" class="df">to move unsteadily</span></span></span>\
            </d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.count == 2)
        #expect(senses.first?.partOfSpeech == "noun")
        #expect(senses.last?.partOfSpeech == nil, "the second block inherited the first block's part of speech")
    }

    /// Two blocks that each declare one keep their own.
    @Test func eachBlockKeepsItsOwnPartOfSpeech() {
        let xml = """
            <d:entry id="e1" d:title="wibble"><span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span d:pos="1" class="pos">noun</span>\
            <span id="e1.1" class="x_xd1"><span d:def="1" class="df">a small device</span></span></span>\
            <span class="x_xd0"><span d:pos="1" class="pos">verb</span>\
            <span id="e1.2" class="x_xd1"><span d:def="1" class="df">to move unsteadily</span></span></span>\
            </d:entry>
            """
        #expect(Self.index(xml)?.senses.map(\.partOfSpeech) == ["noun", "verb"])
    }

    /// **Subsenses are joined, and the numbering is not kept.** Recorded rather than asserted as desirable:
    /// a numbered sense holding several `x_xd1sub` definitions becomes one sense whose text is their join,
    /// so `1a` and `1b` cannot be told apart and the number `1` is nowhere in the result. Joining is the
    /// right call over dropping — the alternative destroyed five of six glosses in one real entry — but the
    /// hierarchy is lost, and anything that wants to show "sense 1: a, b" cannot get it from here.
    @Test func subsensesAreJoinedAndTheirNumberingIsLost() {
        let xml = """
            <d:entry id="e2" d:title="frob"><span class="x_xh0">frob</span>\
            <span class="x_xd0"><span d:pos="1" class="pos">verb</span>\
            <span id="e2.1" class="se2 x_xd1 hasSn"><span class="gp sn">1</span>\
            <span id="e2.2" class="msDict x_xd1sub"><span d:def="1" class="df">to adjust</span></span>\
            <span id="e2.3" class="msDict x_xd1sub"><span d:def="1" class="df">to fiddle with</span></span></span>\
            <span id="e2.4" class="se2 x_xd1 hasSn"><span class="gp sn">2</span>\
            <span id="e2.5" class="msDict x_xd1sub"><span d:def="1" class="df">to tweak</span></span></span></span>\
            </d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.count == 2, "the two subsenses of sense 1 became one sense")
        #expect(senses.first?.definition == "to adjust; to fiddle with")
        #expect(senses.first?.key.value == "e2.1", "the id is the numbered sense's, not either subsense's")
        // Nothing carries the number, and nothing carries a parent.
        #expect(senses.allSatisfy { !$0.definition.contains("1") || $0.definition.contains("to") })
    }

    /// **Sub-entries are not read at all.** Phrasal verbs and idioms live in `x_xo*`, a namespace this
    /// indexer never looks at: `x_xo1` is the sub-entry, `x_xo2` a numbered sense inside it, `x_xo2sub` the
    /// subsense holding the definition. Their definitions also carry `class="df"` **without** a `d:def`
    /// attribute, which is why a retention figure counting `d:def=` reported 100% while a quarter of NOAD's
    /// definitions were never reached.
    @Test func subEntriesArePresentInTheMarkupAndNotRead() {
        let xml = """
            <d:entry id="e3" d:title="wibble"><span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span d:pos="1" class="pos">verb</span>\
            <span id="e3.1" class="x_xd1"><span d:def="1" class="df">to move unsteadily</span></span></span>\
            <span id="e3.9" class="subEntry x_xo1"><span class="l x_xoh">wibble out </span>\
            <span id="e3.10" class="se2 x_xo2 hasSn"><span class="gp sn">1</span>\
            <span id="e3.11" class="msDict x_xo2sub"><span class="df">to withdraw at the last moment</span>\
            </span></span></span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.count == 1, "only the x_xd1 sense is read")
        #expect(senses.first?.definition == "to move unsteadily")
        #expect(!senses.contains { $0.definition.contains("withdraw") },
                "the sub-entry sense was read — if this now passes, update the ledger's §4")
    }
}
