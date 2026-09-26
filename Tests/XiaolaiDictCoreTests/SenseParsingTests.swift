import DictionaryModel
import XiaolaiDictCore
import Testing

/// Reading senses out of an entry. The structural layer — `x_xd0` a part-of-speech block, `x_xd1`
/// one sense, `d:def` its definition, `d:pos`, `d:prn` — holds in 9 of Apple's 9 dictionaries; the
/// class names on top of it do not, so nothing here matches on `df`, `trans`, `semb` or `se2`
/// (`dev-docs/dictionary-markup.md` §3–§4).
struct SenseParsingTests {
    private static func document(_ body: String) -> String {
        """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng">\
        <head><style>p { margin: 0 }</style></head><body>\(body)</body></html>
        """
    }

    /// NOAD's shape, reduced: one entry, two part-of-speech blocks, senses carrying the publisher's
    /// own id on the `x_xd1` element itself.
    private static let noad = document("""
        <d:entry id="m_en_gbus0362750">\
        <span class="hg x_xh0"><span homograph="1" class="hw">fine</span>\
        <span d:prn="US" class="ph t_respell">fīn<d:prn></d:prn></span></span>\
        <span id="m_en_gbus0362750.004" class="se1 x_xd0">\
        <span class="posg x_xdh"><span d:pos="1" class="pos">adjective<d:pos></d:pos></span></span>\
        <span id="m_en_gbus0362750.005" class="se2 x_xd1 hasSn">\
        <span d:def="1" class="df">made or done very well<d:def></d:def></span>\
        <span class="eg"><span class="ex">a fine piece of filmmaking</span></span>\
        <span id="m_en_gbus0362750.010" class="msDict x_xd1sub t_subsense">\
        <span class="df">deserving of praise</span></span></span>\
        <span id="m_en_gbus0362750.020" class="se2 x_xd1 hasSn">\
        <span d:def="1" class="df">feeling well</span></span></span>\
        <span id="m_en_gbus0362750.029" class="se1 x_xd0">\
        <span class="posg x_xdh"><span d:pos="2" class="pos">adverb<d:pos></d:pos></span></span>\
        <span id="m_en_gbus0362750.030" class="msDict x_xd1 t_core">\
        <span d:def="1" class="df">well enough</span></span></span>\
        </d:entry>
        """)

    @Test func blocksAndSensesAreReadFromTheStructuralLayer() throws {
        let parsed = try #require(EntryDocument.parse(Self.noad))
        #expect(parsed.blocks.count == 2)
        #expect(parsed.blocks.map(\.partOfSpeech) == ["adjective", "adverb"])
        #expect(parsed.blocks.map { $0.senses.count } == [2, 1])
        #expect(parsed.senseCount == 3)
        #expect(parsed.pronunciations == ["fīn"])
    }

    /// `x_xd1sub` contains `x_xd1` as a substring, and a subsense is not a sense. Apple's own XPath
    /// makes the same exclusion. Matching on class *tokens* is what keeps them apart.
    @Test func aSubsenseIsNotASense() throws {
        let parsed = try #require(EntryDocument.parse(Self.noad))
        let keys = parsed.senses.map(\.key)
        #expect(keys == ["m_en_gbus0362750.005", "m_en_gbus0362750.020", "m_en_gbus0362750.030"])
        #expect(!keys.contains("m_en_gbus0362750.010"), "a subsense was counted as a sense")
    }

    /// Numbering restarts inside an entry — *hold* in 牛津英汉汉英 runs ①–㉙ for the transitive verb,
    /// then ①–⑧ for the intransitive — so a bare ordinal means nothing without its block.
    @Test func aSensesPathCarriesItsBlock() throws {
        let parsed = try #require(EntryDocument.parse(Self.noad))
        #expect(parsed.senses.map(\.path) == [
            SensePath(block: 1, ordinal: 1), SensePath(block: 1, ordinal: 2), SensePath(block: 2, ordinal: 1),
        ])
    }

    @Test func theDefinitionComesFromTheStructuralMarker() throws {
        let parsed = try #require(EntryDocument.parse(Self.noad))
        #expect(parsed.senses.map(\.definition) == ["made or done very well", "feeling well", "well enough"])
    }

    /// The whole sense, not only its definition: the selector of Stage 3 compares the reader's
    /// sentence against a sense's definition *and* its examples, and a subsense is part of the
    /// sense it hangs under even though it is not a sense of its own.
    @Test func aSensesTextIncludesItsExamplesAndSubsenses() throws {
        let parsed = try #require(EntryDocument.parse(Self.noad))
        let first = parsed.senses[0].text
        #expect(first.contains("made or done very well"))
        #expect(first.contains("a fine piece of filmmaking"))
        #expect(first.contains("deserving of praise"))
        #expect(!first.contains("feeling well"), "a sense swallowed the next one")
    }

    // MARK: - How precisely the key is known

    @Test func aPublisherIDIsThePublishersOwn() throws {
        let parsed = try #require(EntryDocument.parse(Self.noad))
        #expect(parsed.senses.allSatisfy { $0.keyKind == .publisher })
    }

    /// 牛津英汉汉英 spells the same thing `lexid`.
    @Test func lexidIsAPublisherIDToo() throws {
        let body = """
            <d:entry id="e_b-en-zh_hans0013659">\
            <span lexid="b-en-zh_hans0013659.001" class="gramb x_xd0 hasSn">\
            <span d:pos="1" class="ps">adjective<d:pos></d:pos></span>\
            <span lexid="b-en-zh_hans0013659.002" class="semb x_xd1">\
            <span d:def="1" class="trans">很好的</span></span></span></d:entry>
            """
        let parsed = try #require(EntryDocument.parse(Self.document(body)))
        #expect(parsed.senses.map(\.key) == ["b-en-zh_hans0013659.002"])
        #expect(parsed.senses.map(\.keyKind) == [.publisher])
    }

    /// 譯典通 has the sense structure and no ids at all. That is a weaker claim, not an absent one:
    /// the sense is addressed by where it sits, and its text is hashed so an Apple content update
    /// that reorders senses is noticed rather than silently re-pointing the reader's history.
    @Test func aSenseWithoutAnIDIsKeyedByPosition() throws {
        let body = """
            <d:entry id="e_id016730">\
            <span class="se1 x_xd0"><span d:pos="1" class="pos">adjective<d:pos></d:pos></span>\
            <span class="se2 x_xd1 hasSn"><span d:def="1" class="trans">很好的</span></span>\
            <span class="se2 x_xd1 hasSn"><span d:def="1" class="trans">天气好的</span></span></span></d:entry>
            """
        let parsed = try #require(EntryDocument.parse(Self.document(body)))
        #expect(parsed.senses.map(\.keyKind) == [.position, .position])
        #expect(parsed.senses.map(\.key) == ["1.1", "1.2"])
        #expect(parsed.senses.allSatisfy { !$0.textHash.isEmpty })
        #expect(parsed.senses[0].textHash != parsed.senses[1].textHash)
    }

    /// The hash is of the sense's text, so the same sense hashes the same and a reworded one does not.
    @Test func theHashFollowsTheSensesText() throws {
        func hash(_ definition: String) -> String {
            let body = #"<d:entry id="e"><span class="se1 x_xd0"><span class="se2 x_xd1">"# +
                #"<span d:def="1" class="trans">\#(definition)</span></span></span></d:entry>"#
            return EntryDocument.parse(Self.document(body))!.senses[0].textHash
        }
        // **Written out, not compared with itself.** `hash(x) == hash(x)` holds for any
        // deterministic hash — including `Hasher`, which is seeded per process and would give this
        // sense a different key on every launch while passing here every time. A literal is the
        // only form of this check that a per-process seed fails.
        #expect(hash("很好的") == "45c42943927ed172")
        #expect(hash("很好的") != hash("天气好的"))
    }

    /// The sideloaded conversions mark senses with fonts and colours and nothing else. There is no
    /// sense to key, and the entry says so rather than inventing one.
    @Test func aDictionaryWithoutSenseStructureHasNoSenses() throws {
        // Doubled delimiters: `color="#c00"` would close a single-# raw string at the `"#`.
        let body = ##"<d:entry id="_8pm"><p><font color="#c00">fine</font> <b>1.</b> made or done very well</p></d:entry>"##
        let parsed = try #require(EntryDocument.parse(Self.document(body)))
        #expect(parsed.blocks.isEmpty)
        #expect(parsed.senses.isEmpty)
        #expect(parsed.senseKeyKind == SenseKeyKind.none, "an entry with no sense structure claimed one")
    }

    /// The entry's own rung is the best any of its senses reached — so an entry whose senses are
    /// positional never reports itself as carrying publisher ids.
    @Test func theEntrysRungIsTheBestItsSensesReached() throws {
        #expect(EntryDocument.parse(Self.noad)?.senseKeyKind == .publisher)
        let positional = """
            <d:entry id="e"><span class="se1 x_xd0"><span class="se2 x_xd1">\
            <span d:def="1" class="trans">x</span></span></span></d:entry>
            """
        #expect(EntryDocument.parse(Self.document(positional))?.senseKeyKind == .position)
    }

    /// A sense outside any part-of-speech block still belongs somewhere; it is not dropped.
    @Test func aSenseWithNoBlockGetsOne() throws {
        let body = #"<d:entry id="e"><span class="x_xd1"><span d:def="1" class="df">loose</span></span></d:entry>"#
        let parsed = try #require(EntryDocument.parse(Self.document(body)))
        #expect(parsed.senseCount == 1)
        #expect(parsed.blocks.count == 1)
        #expect(parsed.blocks[0].partOfSpeech == nil, "a block that named no part of speech claimed one")
        #expect(parsed.senses[0].path == SensePath(block: 1, ordinal: 1))
    }

    /// Whitespace in the markup is layout, not content: a definition read with the newlines and
    /// indentation still in it would hash differently every time the dictionary is reflowed.
    @Test func textIsCollapsedToSingleSpaces() throws {
        let body = """
            <d:entry id="e"><span class="se1 x_xd0"><span class="se2 x_xd1">
                <span d:def="1" class="df">made    or
                done very well</span>
            </span></span></d:entry>
            """
        let parsed = try #require(EntryDocument.parse(Self.document(body)))
        #expect(parsed.senses[0].definition == "made or done very well")
    }
}

/// Found by audit. Both defects corrupted the *content* of a sense, which is worse than failing to
/// read one: a wrong definition renders as confidently as a right one.
struct EntryParsingAuditTests {
    private static func document(_ body: String) -> String {
        """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng">\
        <head><style>p { margin: 0 }</style></head><body>\(body)</body></html>
        """
    }

    /// A document holding two entries reported the **first** entry's id with **both** entries'
    /// senses — crediting entry A with entry B's meanings, and keying a card to the wrong one.
    @Test func asecondEntrysSensesAreNotCreditedToTheFirst() throws {
        let body = """
            <d:entry id="first"><span class="se1 x_xd0"><span d:pos="1" class="pos">noun<d:pos></d:pos></span>\
            <span class="se2 x_xd1"><span d:def="1" class="df">belonging to the first</span></span></span></d:entry>\
            <d:entry id="second"><span class="se1 x_xd0"><span d:pos="1" class="pos">verb<d:pos></d:pos></span>\
            <span class="se2 x_xd1"><span d:def="1" class="df">belonging to the second</span></span></span></d:entry>
            """
        let parsed = try #require(EntryDocument.parse(Self.document(body)))
        #expect(parsed.entryID == "first")
        #expect(parsed.senseCount == 1, "the second entry's senses were counted as the first's")
        #expect(parsed.senses.map(\.definition) == ["belonging to the first"])
        #expect(parsed.blocks.map(\.partOfSpeech) == ["noun"])
    }

    /// A pronunciation belongs to the entry that printed it.
    @Test func asecondEntrysPronunciationIsNotTheFirsts() throws {
        let body = """
            <d:entry id="first"><span class="hg x_xh0"><span d:prn="US" class="ph">fīn<d:prn></d:prn></span></span>\
            </d:entry>\
            <d:entry id="second"><span class="hg x_xh0"><span d:prn="US" class="ph">hōld<d:prn></d:prn></span></span>\
            </d:entry>
            """
        let parsed = try #require(EntryDocument.parse(Self.document(body)))
        #expect(parsed.pronunciations == ["fīn"])
    }

    /// `first<br/>second` collapsed to "firstsecond": a corrupted definition, a corrupted input to
    /// the sense selector, and a hash that no longer matches the sense it is supposed to track.
    @Test func anExplicitBreakIsAWordBoundary() throws {
        let body = #"""
            <d:entry id="e"><span class="se1 x_xd0"><span class="se2 x_xd1">\
            <span d:def="1" class="df">first<br/>second</span></span></span></d:entry>
            """#
        let parsed = try #require(EntryDocument.parse(Self.document(body)))
        #expect(parsed.senses[0].definition == "first second")
    }

    /// Found by the verify pass: opening alone left `<p>first</p>second` joined, because the
    /// closing tag emitted nothing. A boundary is a boundary at both ends.
    @Test(arguments: ["p", "div", "li", "blockquote", "h2"])
    func aClosingTagIsAWordBoundaryToo(element: String) throws {
        let body = """
            <d:entry id="e"><span class="se1 x_xd0"><span class="se2 x_xd1">\
            <span d:def="1" class="df"><\(element)>first</\(element)>second</span></span></span></d:entry>
            """
        #expect(EntryDocument.parse(Self.document(body))?.senses[0].definition == "first second")
    }

    @Test(arguments: ["p", "div", "li"])
    func blockBoundariesSeparateWordsToo(element: String) throws {
        let body = """
            <d:entry id="e"><span class="se1 x_xd0"><span class="se2 x_xd1">\
            <span d:def="1" class="df"><\(element)>first</\(element)><\(element)>second</\(element)></span>\
            </span></span></d:entry>
            """
        let parsed = try #require(EntryDocument.parse(Self.document(body)))
        #expect(parsed.senses[0].definition == "first second")
    }

    /// The separator must not appear where there was already whitespace, or every definition grows
    /// double spaces — collapsing is what makes adding one always safe.
    @Test func aBreakBesideWhitespaceDoesNotDoubleUp() throws {
        let body = #"""
            <d:entry id="e"><span class="se1 x_xd0"><span class="se2 x_xd1">\
            <span d:def="1" class="df">first <br/> second</span></span></span></d:entry>
            """#
        #expect(EntryDocument.parse(Self.document(body))?.senses[0].definition == "first second")
    }

    /// A break changes the text, so it must change the hash — that is the whole point of the hash.
    @Test func theHashSeesTheBoundary() throws {
        func hash(_ inner: String) -> String? {
            let body = """
                <d:entry id="e"><span class="se1 x_xd0"><span class="se2 x_xd1">\
                <span d:def="1" class="df">\(inner)</span></span></span></d:entry>
                """
            return EntryDocument.parse(Self.document(body))?.senses[0].textHash
        }
        #expect(hash("first<br/>second") != hash("firstsecond"))
    }
}
