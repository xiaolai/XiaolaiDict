import Foundation
import Testing
@testable import AppleDictionaryFormat

/// The two things the indexer reads for the sake of alignment rather than for display: the example phrases a
/// sense prints, and the publisher's cross-dictionary identifiers.
///
/// **Both are the alignment's entire input, so neither can be left to the executable to prove.** The examples
/// are what a bilingual dictionary shares with an English one — its definitions are in the other language —
/// and the anchors are what joins two entries at all. A silent change in either moves the alignment's
/// precision with nothing failing.
struct ExampleAndAnchorTests {
    static let profile = DictionaryProfile(identifier: "test", senseDepth: 1)
    static func index(_ xml: String) -> IndexedEntry? {
        EntryIndexer(dictionary: "test", profile: profile).index(xml)
    }

    /// A sense's own examples, in document order.
    @Test func aSenseCarriesTheExamplesItPrints() throws {
        let xml = """
            <d:entry id="e1" d:title="hold"><span class="x_xh0"><span class="hw">hold</span></span>\
            <span class="x_xd0"><span d:pos="1" class="pos">verb</span>\
            <span id="e1.1" class="x_xd1"><span d:def="1" class="df">grasp and keep</span>\
            <span class="eg"><span class="ex">she held the rope</span></span>\
            <span class="eg"><span class="ex">he held his breath</span></span>\
            </span></span></d:entry>
            """
        let sense = try #require(Self.index(xml)?.senses.first)
        #expect(sense.definition == "grasp and keep")
        #expect(sense.examples == ["she held the rope", "he held his breath"])
    }

    /// **A sub-entry's examples are its own, on both sides of the boundary.** Scope is the filter that made
    /// the alignment correct for a polysemous word — with a phrasal verb's material mixed into the main
    /// entry's, every one of `hold`'s pairs came out wrong. The boundary has to hold in the extraction, not
    /// only in the matcher.
    @Test func examplesDoNotCrossASubEntryBoundary() throws {
        let xml = """
            <d:entry id="e1" d:title="hold"><span class="x_xh0"><span class="hw">hold</span></span>\
            <span class="x_xd0"><span d:pos="1" class="pos">verb</span>\
            <span id="e1.1" class="x_xd1"><span d:def="1" class="df">grasp and keep</span>\
            <span class="eg"><span class="ex">she held the rope</span></span>\
            </span></span>\
            <span class="subEntryBlock x_xo0"><span class="gp x_xoLblBlk">PHRASAL VERBS </span>\
            <span id="e1.2" class="subEntry x_xo1"><span class="l x_xoh">hold out </span>\
            <span id="e1.3" class="se2 x_xo2"><span class="df">resist</span>\
            <span class="eg"><span class="ex">the garrison held out for a week</span></span>\
            </span></span></span></d:entry>
            """
        let entry = try #require(Self.index(xml))
        let main = try #require(entry.senses.first { $0.position.subEntry == nil })
        let sub = try #require(entry.senses.first { $0.position.subEntry != nil })
        #expect(main.examples == ["she held the rope"],
                "the main sense absorbed the sub-entry's example: \(main.examples)")
        #expect(sub.examples == ["the garrison held out for a week"], "got \(sub.examples)")
    }

    /// Guide punctuation is not content, in an example for the same reason it is not in a definition: the
    /// colon a dictionary prints before an example is markup that happens to be text.
    @Test func guidePunctuationIsNotPartOfAnExample() throws {
        let xml = """
            <d:entry id="e1" d:title="fine"><span class="x_xh0"><span class="hw">fine</span></span>\
            <span class="x_xd0"><span id="e1.1" class="x_xd1">\
            <span d:def="1" class="df">a penalty</span>\
            <span class="eg"><span class="gp">: </span><span class="ex">a heavy fine</span>\
            <span class="gp">.</span></span></span></span></d:entry>
            """
        let sense = try #require(Self.index(xml)?.senses.first)
        #expect(sense.examples == ["a heavy fine"], "guide punctuation reached the example: \(sense.examples)")
    }

    /// An example enclosing another is read once, whole. The nested case is why the extraction asks for
    /// *maximal* regions — counting every match separately reads the same words twice and inflates the
    /// overlap a pair is scored on.
    @Test func anExampleInsideAnExampleIsReadOnce() throws {
        let xml = """
            <d:entry id="e1" d:title="hold"><span class="x_xh0"><span class="hw">hold</span></span>\
            <span class="x_xd0"><span id="e1.1" class="x_xd1">\
            <span d:def="1" class="df">grasp</span>\
            <span class="ex">she held it <span class="ex">by the sleeve</span></span>\
            </span></span></d:entry>
            """
        let sense = try #require(Self.index(xml)?.senses.first)
        #expect(sense.examples == ["she held it by the sleeve"], "got \(sense.examples)")
    }

    /// **The entry's anchors, deduplicated, in document order.** An entry carries one `prlexid` per
    /// pronunciation — British and American — and 43,247 entries of 牛津英汉汉英 carry more than one, so the
    /// join has to be by entry with the anchors collapsed rather than by anchor.
    @Test func anchorsAreDeduplicatedInDocumentOrder() throws {
        let xml = """
            <d:entry id="e1" d:title="fine"><span class="x_xh0"><span class="hw">fine</span>\
            <span class="prx" prlexid="optra0016615.002">|faɪn|</span>\
            <span class="prx" prlexid="optra0016615.005">|fʌɪn|</span>\
            <span class="prx" prlexid="optra0016615.002">|faɪn|</span></span>\
            <span class="x_xd0"><span id="e1.1" class="x_xd1">\
            <span d:def="1" class="df">a penalty</span></span></span></d:entry>
            """
        #expect(Self.index(xml)?.anchors == ["optra0016615.002", "optra0016615.005"])
    }

    /// And a dictionary that carries none says none, rather than inventing a key that would join two
    /// unrelated words. Of the dictionaries measured only NOAD and 牛津英汉汉英 carry Oxford's identifiers.
    @Test func anEntryWithoutAnchorsReportsNone() throws {
        let xml = """
            <d:entry id="e1" d:title="fine"><span class="x_xh0"><span class="hw">fine</span>\
            <span class="prx">|faɪn|</span></span>\
            <span class="x_xd0"><span id="e1.1" class="x_xd1">\
            <span d:def="1" class="df">a penalty</span></span></span></d:entry>
            """
        #expect(Self.index(xml)?.anchors.isEmpty == true)
    }
}
