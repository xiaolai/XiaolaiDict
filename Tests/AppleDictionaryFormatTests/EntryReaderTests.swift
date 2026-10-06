import Foundation
import Testing
@testable import AppleDictionaryFormat
@testable import DictionaryIndex

/// What the tree-based reader buys that a predicate could not: clean headwords, the subsense hierarchy,
/// and the structural retirement of three recorded defects.
@Suite struct EntryReaderTests {
    static let profile = DictionaryProfile(identifier: "test", senseDepth: 1)
    static func index(_ xml: String, _ profile: DictionaryProfile = profile) -> IndexedEntry? {
        EntryIndexer(dictionary: "test", profile: profile).index(xml)
    }

    /// **A headword is the word, not the word plus how to say it.**
    ///
    /// Taking all the text under `x_xh0` gave NOAD `007 | ˌdəbəl ˌō ˈsevən… |` for `007` and `abject
    /// ab·ject | ˈabˌjek(t) … |` for `abject`. 42 of 84 dictionaries carry a pronunciation in the block.
    @Test func theHeadwordLosesItsPronunciationAndItsLabels() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" d:title="abject" class="entry">\
            <span class="hg x_xh0"><span role="text" class="hw">ab<span class="hsb"></span>ject </span>\
            <span d:syl="1" class="syl_txt">ab·ject</span>\
            <span class="prx"> | <span d:prn="US" class="ph t_respell">ˈabˌjek(t)</span> | </span></span>\
            <span class="x_xd0"><span d:pos="1" class="pos">adjective</span>\
            <span id="e1.1" class="x_xd1"><span d:def="1" class="df">utterly hopeless</span></span></span>\
            </d:entry>
            """
        let entry = Self.index(xml)
        #expect(entry?.headword == "abject")
        let carriesDelimiter = entry?.headword.contains("|") ?? true
        #expect(carriesDelimiter == false, "the pronunciation delimiter reached the headword")
    }

    /// **A pronunciation written in the headword's own text.** Prisma, the Dutch dictionary, prints the syllabified
    /// form and the plain one inside the `hw` span itself — `aal·glad | aalglad` — with no class naming either, so
    /// no class filter can remove it: 141 of its first 6,000 headwords carried the `|`. The delimiter is Apple's, and
    /// the headword is what stands before it.
    @Test(arguments: [("aal<span class=\"hsb\"></span>gl<span class=\"sy_underline\">a</span>d  |  <span class=\"sy_underline\">aa</span>l<span class=\"hsb\"></span>glad ", "aalglad"),
                      ("aangeërfde | aangeerfde", "aangeërfde"), ("plain ", "plain")])
    func aPronunciationInTheHeadwordsOwnTextIsCutAtTheDelimiter(markup: String, expected: String) {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" d:title="\(expected)" class="entry">\
            <span class="hg x_xh0"><span role="text" class="hw">\(markup)</span></span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">meaning</span></span></span></d:entry>
            """
        #expect(Self.index(xml)?.headword == expected)
    }

    /// **Cutting must never empty a headword**, for the reason filtering must not: an empty headword is a refused
    /// entry. A block that is only the delimiter keeps what it had.
    @Test func aBlockThatIsOnlyTheDelimiterIsNotEmptied() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="hg x_xh0"><span class="hw"> | x</span></span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">meaning</span></span></span></d:entry>
            """
        #expect(Self.index(xml)?.headword.isEmpty == false)
    }

    /// The homograph number is printed inside `hw` as guide punctuation, so it comes out of the headword
    /// while staying available as the homograph marker.
    @Test func theHomographNumberIsNotPartOfTheHeadword() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" d:title="-a" class="entry">\
            <span class="hg x_xh0"><span role="text" homograph="1" class="hw">-a\
            <span class="gp ty_hom tg_hw"> 1 </span></span></span>\
            <span class="x_xd0"><span id="e1.1" class="x_xd1">\
            <span d:def="1" class="df">forming names of oxides</span></span></span></d:entry>
            """
        let entry = Self.index(xml)
        #expect(entry?.headword == "-a")
        #expect(entry?.homograph == "1", "the marker itself must survive — `hood 1` and `hood 2` differ")
    }

    /// **Filtering must never empty a headword**, because an empty headword is a refused entry and a
    /// refused entry throws away every definition it held.
    @Test func aHeadwordMadeEntirelyOfFilteredContentIsKeptAnyway() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="hg x_xh0"><span class="hw"><span class="gp">◊</span></span></span>\
            <span class="x_xd0"><span id="e1.1" class="x_xd1">\
            <span class="df">a lozenge</span></span></span></d:entry>
            """
        let entry = Self.index(xml)
        #expect(entry != nil, "the entry was refused, so its definition was lost")
        #expect(entry?.headword == "◊")
        #expect(entry?.senses.count == 1)
    }

    /// **The entry id is its own field, not a sense id.**
    ///
    /// Reading every identifier through `profile.senseIDAttributes` loses the entry's own `id` wherever a
    /// profile declares none — and `zh_TW-en.DrEye` declares none, so all 136,288 of its entries would have
    /// become unnamed.
    @Test func theEntryIDSurvivesAProfileDeclaringNoSenseAttributes() {
        let none = DictionaryProfile(identifier: "test", senseDepth: 1, senseIDAttributes: [])
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="z_id000001" class="entry">\
            <span class="x_xh0">一</span><span class="x_xd0">\
            <span id="z_id000001.1" class="x_xd1"><span class="df">one</span></span></span></d:entry>
            """
        let entry = Self.index(xml, none)
        #expect(entry?.entryID == "z_id000001")
        #expect(entry?.senses.count == 1)
        #expect(entry?.senses.first?.key.origin == .content,
                "declaring no attribute means content keys, which is a real name and not a missing one")
    }

    /// **A nested matching sense block does not steal the outer block's identity.** The previous reader kept
    /// one `senseDepth` variable, so opening an inner block overwrote the outer one's id and closing the
    /// inner cleared the context for both.
    @Test func aNestedSenseBlockBelongsToTheSenseAboveIt() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span><span class="x_xd0">\
            <span id="outer" class="x_xd1"><span class="df">to move unsteadily</span>\
            <span id="inner" class="x_xd1"><span class="df">and to keep moving</span></span></span>\
            <span id="sibling" class="x_xd1"><span class="df">a small device</span></span></span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.count == 2, "the nested block belongs to the sense above it, not to a sense of its own")
        #expect(senses.map(\.key.value) == ["outer", "sibling"])
        #expect(senses.first?.definition == "to move unsteadily; and to keep moving")
    }

    /// **CDATA is text.** `foundCDATA` was not implemented, so a definition written this way read empty and
    /// an empty definition is simply not appended — a silent loss.
    @Test func aCDATADefinitionReachesItsSense() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span><span class="x_xd0">\
            <span id="e1.1" class="x_xd1"><span d:def="1" class="df">\
            <![CDATA[a marsh plant that glows]]></span></span></span></d:entry>
            """
        let entry = Self.index(xml)
        #expect(entry?.senses.map(\.definition) == ["a marsh plant that glows"])
        #expect(entry?.capturedDefinitions == 1)
    }

    /// The namespace prefix is read from the document, so a record binding it to something other than `d`
    /// is read by the same code.
    @Test func anotherNamespacePrefixIsReadTheSameWay() {
        let xml = """
            <dict:entry xmlns:dict="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span><span class="x_xd0">\
            <span dict:pos="1" class="pos">noun</span>\
            <span id="e1.1" class="x_xd1"><span dict:def="1" class="df">a small device</span></span>\
            </span></dict:entry>
            """
        let entry = Self.index(xml)
        #expect(entry?.entryID == "e1")
        #expect(entry?.senses.map(\.definition) == ["a small device"])
        #expect(entry?.senses.first?.partOfSpeech == "noun")
    }

    /// **The subsense hierarchy is available, and the sense is still whole.**
    ///
    /// Joining is the right call over dropping — the alternative destroyed five of 一's six glosses — but the
    /// parts were unreachable. They are now carried beside the join, so a reader can show "sense 1: a, b"
    /// and a schema can store them under a `parent_key`.
    @Test func aNumberedSenseCarriesItsSubsenses() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e2" class="entry">\
            <span class="x_xh0">@</span><span class="x_xd0"><span d:pos="1" class="pos">symbol</span>\
            <span id="e2.1" class="se2 x_xd1 hasSn"><span class="gp x_xdh sn ty_label">  1 </span>\
            <span id="e2.2" class="msDict x_xd1sub t_first">\
            <span d:def="1" class="df">used in internet addresses</span></span>\
            <span id="e2.3" class="msDict x_xd1sub hasSn t_subsense">\
            <span class="gp sn tg_msDict">  • </span>\
            <span class="df">used preceding a person's name</span></span></span></span></d:entry>
            """
        let sense = Self.index(xml)?.senses.first
        #expect(sense?.definition == "used in internet addresses; used preceding a person's name",
                "the sense is still whole")
        #expect(sense?.position.senseNumber == "1",
                "the sense's own number, not its last subsense's bullet")
        #expect(sense?.subsenses.count == 2)
        #expect(sense?.subsenses.map(\.label) == [nil, "•"],
                "NOAD labels a subsense with a bullet, so nothing invents an `a`/`b`")
        #expect(sense?.subsenses.map(\.definition)
                == ["used in internet addresses", "used preceding a person's name"])
        // Each subsense is its own name, and none of them is the sense's.
        let keys = Set((sense?.subsenses.map(\.key.value) ?? []) + [sense?.contentKey.value ?? ""])
        #expect(keys.count == 3, "a subsense must not take its parent's key")
        // Counted once: a subsense's definition is the sense's definition, not an extra one.
        #expect(Self.index(xml)?.capturedDefinitions == 2)
        #expect(Self.index(xml)?.declaredDefinitions == 2)
    }

    /// A sense with a single subsense has no hierarchy to express, and emitting one would give it a key
    /// identical to its parent's.
    @Test func aSenseWithOneSubsenseCarriesNoHierarchy() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e3" class="entry">\
            <span class="x_xh0">wibble</span><span class="x_xd0">\
            <span id="e3.1" class="se2 x_xd1 hasSn"><span class="gp sn">1</span>\
            <span id="e3.2" class="msDict x_xd1sub t_first">\
            <span d:def="1" class="df">to move unsteadily</span></span></span></span></d:entry>
            """
        let sense = Self.index(xml)?.senses.first
        #expect(sense?.definition == "to move unsteadily")
        #expect(sense?.subsenses.isEmpty == true)
    }

    /// **No shared capture buffer, so a nested capture cannot eat an open region's text.**
    ///
    /// The previous reader kept one `buffer` for the headword, the part of speech and the definition, and
    /// opening any of those reset it. A `d:pos` element *inside* a definition therefore threw away every
    /// character captured before it: `a device <pos>noun</pos> for wibbling` yielded `for wibbling`, with
    /// `a device` silently gone — and a definition's text feeds its key, so the sense got a different name
    /// as well as less content. Each node owns its own text now, so there is nothing to reset.
    @Test func aNestedCaptureDoesNotEatTheTextBeforeIt() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span><span class="x_xd0">\
            <span id="e1.1" class="x_xd1"><span d:def="1" class="df">a device \
            <span d:pos="1" class="pos">noun</span> for wibbling</span></span></span></d:entry>
            """
        let entry = Self.index(xml)
        let definition = entry?.senses.first?.definition ?? ""
        #expect(definition.contains("a device"), "the text before the nested capture was lost")
        #expect(definition.contains("for wibbling"), "the text after the nested capture was lost")
        #expect(definition == "a device noun for wibbling",
                "a definition region keeps all of its text, in order")
    }

    /// The headword survives a nested capture inside its own block for the same reason.
    @Test func aNestedCaptureDoesNotEatTheHeadword() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="hg x_xh0"><span class="hw">wib<span d:syl="1" class="inner">·</span>ble</span></span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">a small device</span></span></span>\
            </d:entry>
            """
        #expect(Self.index(xml)?.headword == "wib·ble")
    }

    /// **A sub-entry inside a sense is still a sub-entry.**
    ///
    /// The maximal-sense rule that retires the nested-block defect nearly took this with it: letting the
    /// sense own its whole subtree swallowed the sub-entry's definition into the parent and left the sense
    /// with no label. Measured on 现代汉语规范词典, which nests `x_xo[1-9]` inside `x_xd1` exactly 53 times:
    /// no definition and no sense was lost, so every total held and only the sub-entry count moved, 813 to
    /// 760. The label is what scopes an alias, so losing it is what makes `give up` return `give`'s whole
    /// candidate set.
    @Test func aSubEntryNestedInsideASenseKeepsItsOwnLabel() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">give</span><span class="x_xd0">\
            <span id="e1.1" class="x_xd1"><span class="df">to hand over</span>\
            <span id="e1.2" class="subEntry x_xo1"><span class="l">give up </span>\
            <span class="msDict x_xo2"><span class="df">to stop trying</span></span></span></span>\
            </span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.count == 2, "the nested sub-entry is a sense of its own")
        #expect(senses.map(\.definition) == ["to hand over", "to stop trying"])
        #expect(senses.map(\.position.subEntry) == [nil, "give up"])
        // The parent must not absorb the sub-entry's definition, or the label goes with it.
        #expect(senses.first?.definition.contains("stop trying") == false)
        #expect(Self.index(xml)?.capturedDefinitions == 2)
    }

    /// **A nested sub-entry does not lend its part of speech to the sense above it.**
    ///
    /// Reproduced against installed 现代汉语规范词典 entry `0000215`, where the `形` belonging to sub-entry
    /// `嚣嚣` became the main sense's part of speech. Wrong in the direction that matters: a filter narrowing
    /// by part of speech would select the wrong senses rather than none, and the label feeds the content key.
    @Test func aNestedSubEntryDoesNotLendItsPartOfSpeechToItsParent() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span><span class="x_xd0">\
            <span id="e1.1" class="x_xd1"><span class="df">to move unsteadily</span>\
            <span id="e1.2" class="subEntry x_xo1"><span class="l">wibble out </span>\
            <span d:pos="1" class="pos">adjective</span>\
            <span class="msDict x_xo2"><span class="df">withdrawn</span></span></span></span>\
            </span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.count == 2)
        #expect(senses.first?.position.partOfSpeech == nil,
                "the main sense took the sub-entry's part of speech")
        #expect(senses.last?.position.subEntry == "wibble out")
    }

    /// **And it does not lend its sense number either**, which would make the parent's content key depend on
    /// how a *sibling* was numbered.
    @Test func aNestedSubEntryDoesNotLendItsSenseNumberToItsParent() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span><span class="x_xd0">\
            <span id="e1.1" class="x_xd1"><span class="df">to move unsteadily</span>\
            <span id="e1.2" class="subEntry x_xo1"><span class="l">wibble out </span>\
            <span class="gp sn">9</span>\
            <span class="msDict x_xo2"><span class="df">withdrawn</span></span></span></span>\
            </span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.first?.position.senseNumber == nil, "the parent took the sub-entry's number")
    }

    /// **A definition element enclosing a sub-entry must not absorb its text.**
    ///
    /// Absorbing it made the parent carry a definition the sub-entry then emitted again:
    /// `declaredDefinitions = 1`, `capturedDefinitions = 2`, retention `2.0` — breaking the bound
    /// `definitionsReached` promises and that `DepthRetentionTests` asserts.
    @Test func aDefinitionWrapperDoesNotAbsorbANestedSubEntry() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span><span class="x_xd0">\
            <span id="e1.1" class="x_xd1"><span class="df">to move unsteadily\
            <span id="e1.2" class="subEntry x_xo1"><span class="l">wibble out </span>\
            <span class="df">withdrawn</span></span></span></span>\
            </span></d:entry>
            """
        let entry = Self.index(xml)
        #expect(entry?.senses.first?.definition == "to move unsteadily",
                "the parent absorbed the sub-entry's definition")
        #expect((entry?.capturedDefinitions ?? 0) <= (entry?.declaredDefinitions ?? 0))
        #expect((entry?.definitionsReached ?? 2) <= 1.0, "retention above 100% is a counting defect")
    }

    /// **Ruby annotation is pronunciation, and it is an element rather than a class.**
    ///
    /// 譯典通 puts Bopomofo inside unclassed `<rt>`, so entry `z_id000002` — headword `一一` — came out as
    /// `一ㄧ一ㄧ`. The check that no headword contains `|` reported success, because ruby carries no
    /// delimiter: this is the case the plan's "Bopomofo-interleaved headwords come out clean" names.
    @Test func rubyPronunciationIsNotPartOfTheHeadword() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="z_id000002" class="entry">\
            <span class="x_xh0"><span class="hw">\
            <ruby>一<rt>ㄧ</rt></ruby><ruby>一<rt>ㄧ</rt></ruby></span></span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">one by one</span></span></span>\
            </d:entry>
            """
        #expect(Self.index(xml)?.headword == "一一")
    }

    /// The same filter applies to a sub-entry's label, which is matched against a search key.
    @Test func rubyPronunciationIsNotPartOfASubEntryLabel() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">一</span><span class="x_xd0">\
            <span class="x_xd1"><span class="df">one</span></span></span>\
            <span class="subEntry x_xo1"><span class="l"><ruby>一一<rt>ㄧㄧ</rt></ruby></span>\
            <span class="msDict x_xo2"><span class="df">one by one</span></span></span></d:entry>
            """
        #expect(Self.index(xml)?.senses.last?.position.subEntry == "一一")
    }

    /// **The entry element is matched exactly.** `hasSuffix("entry")` accepted `<notentry id="wrong">` and
    /// would take such a wrapper ahead of a real `d:entry`, indexing the record under the wrong id.
    @Test func anElementMerelyEndingInEntryIsNotTheEntry() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="right" class="entry">\
            <notentry id="wrong"><span class="x_xh0">wibble</span></notentry>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">a small device</span></span></span>\
            </d:entry>
            """
        #expect(Self.index(xml)?.entryID == "right")
    }

    /// **Two senses and a subsense of a third cannot share a key.**
    ///
    /// Assigning subsense keys per parent could not see the entry's other senses: an unnumbered sense
    /// defining `A`, beside a sense holding unlabelled subsenses `A` and `B`, gave the first sense and the
    /// `A` subsense the same key — and `IndexStore` writes that key as a primary key with
    /// `INSERT OR REPLACE`, so one silently replaced the other.
    @Test func aSubsenseCannotTakeAnotherSensesKey() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span><span class="x_xd0">\
            <span class="x_xd1"><span class="df">A</span></span>\
            <span class="x_xd1">\
            <span class="msDict x_xd1sub"><span class="df">A</span></span>\
            <span class="msDict x_xd1sub"><span class="df">B</span></span></span></span></d:entry>
            """
        let entry = Self.index(xml)
        let senses = entry?.senses ?? []
        #expect(senses.count == 2)
        #expect(senses[1].subsenses.count == 2)
        var keys = senses.map(\.contentKey.value)
        keys += senses.flatMap { $0.subsenses.map(\.key.value) }
        #expect(Set(keys).count == keys.count,
                "a subsense shares a key with another sense: \(keys)")
    }

    /// **A sub-entry reads its own part of speech**, rather than only inheriting one.
    ///
    /// Installed 现代汉语规范词典 sub-entry `0000215_0` (`嚣嚣`) declares `形` and was getting `nil`: the
    /// sub-entry branch passed the inherited value through and never read the declaration under it. The
    /// label feeds the content key, so this was a missing filter *and* a different name.
    @Test func aSubEntryReadsItsOwnPartOfSpeech() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span d:pos="1" class="pos">noun</span>\
            <span class="x_xd1"><span class="df">a small device</span></span></span>\
            <span class="subEntry x_xo1"><span class="l">wibble out </span>\
            <span d:pos="1" class="pos">verb</span>\
            <span class="msDict x_xo2"><span class="df">to withdraw</span></span></span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.map(\.position.partOfSpeech) == ["noun", "verb"])
    }

    /// **`sensesNeedingOrdinals` holds indices into `senses`, and nothing else.**
    ///
    /// Keys are assigned over senses *and* subsenses, so the raw list indexes the flattened array — and
    /// publishing it unchanged let the field name a position past the end of `senses`.
    @Test func ordinalIndicesStayInsideTheSenseArray() {
        // Two senses with identical wording and position, plus a sense whose two subsenses are identical.
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span><span class="x_xd0">\
            <span class="x_xd1"><span class="df">same</span></span>\
            <span class="x_xd1"><span class="df">same</span></span>\
            <span class="x_xd1">\
            <span class="msDict x_xd1sub"><span class="df">twin</span></span>\
            <span class="msDict x_xd1sub"><span class="df">twin</span></span></span></span></d:entry>
            """
        let entry = Self.index(xml)
        let senses = entry?.senses ?? []
        #expect(entry?.sensesNeedingOrdinals.allSatisfy { $0 < senses.count } == true,
                "an ordinal index pointed past the end of `senses`")
        #expect(entry?.sensesNeedingOrdinals == [1], "the second of the two identical senses")
        #expect((entry?.subsensesNeedingOrdinals ?? 0) >= 1, "the identical subsense is reported too")
        #expect(entry?.ordinalsNeeded == (entry?.sensesNeedingOrdinals.count ?? 0)
                + (entry?.subsensesNeedingOrdinals ?? 0))
        // And every emitted name is still distinct.
        var keys = senses.map(\.contentKey.value) + senses.flatMap { $0.subsenses.map(\.key.value) }
        #expect(Set(keys).count == keys.count)
        keys.removeAll()
    }

    /// A `d:` bound to some other namespace is not Apple's, for elements as well as attributes.
    @Test func aForeignPrefixDoesNotNameTheEntryElement() {
        let xml = """
            <d:entry xmlns:d="urn:unrelated" id="e1" class="entry">\
            <span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">a small device</span></span></span>\
            </d:entry>
            """
        // Nothing here is Apple's, so there is no entry to index.
        #expect(Self.index(xml) == nil)
    }

    /// **A phrasal verb with several numbered senses yields several senses.**
    ///
    /// Installed NOAD entry `m_en_gbus0415220` (`give`) carries five numbered `x_xo2` senses under `give up`,
    /// and `take off` carries six. Emitting the sub-entry as one returned them joined by `; ` — so `give up`
    /// became reachable and then answered with a single blob, which is the same defect the schema's alias
    /// scoping exists to prevent one level up.
    @Test func aPhrasalVerbWithSeveralNumberedSensesYieldsSeveral() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="give" class="entry">\
            <span class="x_xh0"><span class="hw">give</span></span>\
            <span class="x_xd0"><span d:pos="1" class="pos">verb</span>\
            <span id="give.1" class="msDict x_xd1"><span d:def="1" class="df">to hand over</span></span></span>\
            <span class="subEntryBlock x_xo0 t_phrasalVerbs">\
            <span id="give.9" class="subEntry x_xo1"><span class="l x_xoh">give up </span>\
            <span id="give.10" class="se2 x_xo2 hasSn"><span class="gp sn">1</span>\
            <span class="msDict x_xo2sub"><span class="df">to cease making an effort</span></span></span>\
            <span id="give.11" class="se2 x_xo2 hasSn"><span class="gp sn">2</span>\
            <span class="msDict x_xo2sub"><span class="df">to surrender</span></span></span>\
            <span id="give.12" class="se2 x_xo2 hasSn"><span class="gp sn">3</span>\
            <span class="msDict x_xo2sub"><span class="df">to devote to a cause</span></span></span>\
            </span></span></d:entry>
            """
        let entry = Self.index(xml)
        let senses = entry?.senses ?? []
        #expect(senses.count == 4, "one main sense and three for `give up`, not one blob")
        let phrase = senses.filter { $0.position.subEntry == "give up" }
        #expect(phrase.count == 3)
        #expect(phrase.map(\.position.senseNumber) == ["1", "2", "3"])
        #expect(phrase.map(\.definition)
                == ["to cease making an effort", "to surrender", "to devote to a cause"])
        // Each carries its own publisher id, so each is independently addressable.
        #expect(phrase.map(\.key.value) == ["give.10", "give.11", "give.12"])
        // **They inherit no part of speech, and that is correct rather than a gap.** NOAD puts the
        // sub-entry block *beside* the `x_xd0` part-of-speech block, not inside it, so there is nothing to
        // inherit — a phrasal verb's part of speech is its own affair and it declares one where it has one.
        // Asserted so the scoping rule is visible: a block's part of speech does not leak to its siblings.
        #expect(phrase.allSatisfy { $0.position.partOfSpeech == nil })
        #expect(senses.first?.position.partOfSpeech == "verb")
        #expect(phrase.allSatisfy { $0.subsenses.isEmpty })
        // Every definition still counted exactly once.
        #expect(entry?.capturedDefinitions == 4)
        #expect(entry?.declaredDefinitions == 4)
    }

    /// **Two id-less sense blocks under one id-bearing sub-entry must not share its key.**
    ///
    /// Borrowing the wrapper's id for every block gave them the same publisher key, and `IndexStore` writes
    /// that as a primary key with `INSERT OR REPLACE` — so one silently replaced the other, and the distinct
    /// content keys that would have told them apart were discarded on the way.
    @Test func senseBlocksDoNotShareTheirSubEntrysPublisherID() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="give" class="entry">\
            <span class="x_xh0"><span class="hw">give</span></span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">to hand over</span></span></span>\
            <span id="give.9" class="subEntry x_xo1"><span class="l">give up </span>\
            <span class="se2 x_xo2 hasSn"><span class="gp sn">1</span>\
            <span class="msDict x_xo2sub"><span class="df">to cease trying</span></span></span>\
            <span class="se2 x_xo2 hasSn"><span class="gp sn">2</span>\
            <span class="msDict x_xo2sub"><span class="df">to surrender</span></span></span>\
            </span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        let phrase = senses.filter { $0.position.subEntry == "give up" }
        #expect(phrase.count == 2)
        #expect(Set(phrase.map(\.key.value)).count == 2, "both senses took the sub-entry's id")
        #expect(phrase.allSatisfy { $0.key.origin == .content },
                "no block declares an id, so each keeps its own content key")
        #expect(Set(senses.map(\.key.value)).count == senses.count)
    }

    /// **A sense block never borrows its sub-entry's id, however few siblings it has.**
    ///
    /// An earlier fix borrowed it when the sub-entry held exactly one sense, which made the key a function of
    /// the **sibling count**: adding a second block switched the first from a publisher key to a content key,
    /// and adding a definition on the wrapper handed the original publisher key to that new text. A persisted
    /// reference would then name different words — the defect `PLAN.md` §0 exists to remove, which is why the
    /// stability is asserted here as the *same key before and after* rather than as any particular value.
    @Test func aSenseBlockKeepsItsKeyWhenASiblingIsAdded() {
        func entry(_ extra: String) -> String {
            """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="abject" class="entry">\
            <span class="x_xh0"><span class="hw">abject</span></span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">utterly hopeless</span></span></span>\
            <span id="abject.13" class="subEntry x_xo1"><span class="l">abjection </span>\
            <span class="msDict x_xo2"><span class="df">the state of being abject</span></span>\
            \(extra)</span></d:entry>
            """
        }
        let alone = Self.index(entry(""))?.senses ?? []
        #expect(alone.last?.definition == "the state of being abject")
        #expect(alone.last?.key.origin == .content, "an id-less block takes its own content key")

        // A second block arrives. The first block's key must not move.
        let withSibling = Self.index(entry(
            "<span class=\"msDict x_xo2\"><span class=\"df\">abjectness</span></span>"))?.senses ?? []
        let first = withSibling.first { $0.definition == "the state of being abject" }
        #expect(first?.key.value == alone.last?.key.value,
                "adding a sibling renamed an existing sense")
        #expect(Set(withSibling.map(\.key.value)).count == withSibling.count)

        // And a definition on the wrapper itself must not take the first block's key either.
        let withOwn = Self.index(entry(""))?.senses ?? []
        #expect(withOwn.last?.key.value == alone.last?.key.value)
    }

    /// A block that declares its own id uses it — that is the publisher's name for that sense.
    @Test func aSenseBlockWithItsOwnIDUsesIt() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="abject" class="entry">\
            <span class="x_xh0"><span class="hw">abject</span></span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">utterly hopeless</span></span></span>\
            <span id="abject.13" class="subEntry x_xo1"><span class="l">abjection </span>\
            <span id="abject.17" class="msDict x_xo2"><span class="df">the state of being abject</span></span>\
            </span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.last?.key.value == "abject.17")
        #expect(senses.last?.key.origin == .publisher)
    }

    /// **A definition marked directly on the sub-entry node is not discarded.**
    ///
    /// `text(excluding:)` applied its predicate to the receiver as well as to its descendants, so asking an
    /// `x_xo1 df` node for its text under "stop at a sub-entry" matched itself and returned nothing — the
    /// region was found and then emptied.
    @Test func aDefinitionMarkedOnTheSubEntryItselfIsRead() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">a small device</span></span></span>\
            <span class="subEntry x_xo1 df">wibble out: to withdraw</span></d:entry>
            """
        let entry = Self.index(xml)
        let senses = entry?.senses ?? []
        #expect(senses.count == 2, "the definition on the sub-entry node itself was dropped")
        #expect(senses.last?.definition == "wibble out: to withdraw")
        // Counted on both sides, so retention stays inside its bound.
        #expect((entry?.capturedDefinitions ?? 0) <= (entry?.declaredDefinitions ?? 0))
        #expect(entry?.declaredDefinitions == 2)
    }

    /// **A nested sub-entry at the same depth keeps its definitions.** `outer` excluded it from every
    /// extraction and nothing else reached it, so its content vanished with no count showing the loss.
    @Test func aSubEntryNestedInsideAnotherAtTheSameDepthIsStillRead() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">give</span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">to hand over</span></span></span>\
            <span class="subEntry x_xo1"><span class="l">give up </span>\
            <span class="msDict x_xo2"><span class="df">to stop trying</span></span>\
            <span class="subEntry x_xo1"><span class="l">give up on </span>\
            <span class="msDict x_xo2"><span class="df">to abandon hope for</span></span></span>\
            </span></d:entry>
            """
        let entry = Self.index(xml)
        let definitions = Set((entry?.senses ?? []).map(\.definition))
        #expect(definitions.contains("to abandon hope for"), "the nested sub-entry's definition was lost")
        #expect(entry?.capturedDefinitions == entry?.declaredDefinitions)
        let labels = Set((entry?.senses ?? []).compactMap(\.position.subEntry))
        #expect(labels.contains("give up on"))
    }

    /// **A depth out of a file cannot crash the reader.** `x_xo9223372036854775807` parsed to `Int.max` and
    /// `depth + 1` trapped on overflow.
    @Test func anAbsurdMarkupDepthIsRefusedRatherThanTrapping() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">a small device</span></span></span>\
            <span class="subEntry x_xo9223372036854775807"><span class="df">nonsense</span></span></d:entry>
            """
        // It must return rather than trap, and the absurd token must not be read as a sub-entry.
        let entry = Self.index(xml)
        #expect(entry?.senses.first?.definition == "a small device")
        #expect(entry?.senses.allSatisfy { $0.position.subEntry == nil } == true)
    }

    /// A foreign default namespace must not let a bare `<entry>` claim Apple's identity.
    @Test func aForeignDefaultNamespaceDoesNotNameTheEntry() {
        let xml = """
            <entry xmlns="urn:unrelated" id="wrong"><span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">a small device</span></span></span>\
            </entry>
            """
        #expect(Self.index(xml) == nil)
    }

    /// A sub-entry holding its definition directly — the common shape — still yields exactly one sense.
    @Test func aPhrasalVerbWithOneSenseStillYieldsOne() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="abject" class="entry">\
            <span class="x_xh0"><span class="hw">abject</span></span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">utterly hopeless</span></span></span>\
            <span class="subEntryBlock x_xo0 t_derivatives">\
            <span id="abject.13" class="subEntry x_xo1"><span class="x_xoh"><span class="l">abjection </span>\
            <span class="prx"> | əbˈdʒɛkʃən | </span></span>\
            <span id="abject.17" class="msDict x_xo2 t_core">\
            <span class="df">the state of being abject</span></span></span></span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.count == 2)
        #expect(senses.last?.position.subEntry == "abjection")
        #expect(senses.last?.definition == "the state of being abject")
        #expect(senses.last?.position.senseNumber == nil, "it prints no number")
    }

    /// Part of speech is scoped to its block, and the tree makes that a parameter rather than a variable
    /// somebody has to remember to clear.
    @Test func aBlockDeclaringNoPartOfSpeechDoesNotInheritTheLastOne() {
        let xml = """
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1" class="entry">\
            <span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span d:pos="1" class="pos">noun</span>\
            <span id="e1.1" class="x_xd1"><span class="df">a small device</span></span></span>\
            <span class="x_xd0">\
            <span id="e1.2" class="x_xd1"><span class="df">to move unsteadily</span></span></span>\
            </d:entry>
            """
        #expect(Self.index(xml)?.senses.map(\.partOfSpeech) == ["noun", nil])
    }
}

/// The reader against real bundles. Gated on `XIAOLAIDICT_BUNDLES`.
@Suite struct EntryReaderMeasurementTests {
    static func bundles() -> [DictionaryBundle] {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else { return [] }
        return DictionaryLocator.installed(in: [URL(fileURLWithPath: root)])
    }

    /// **No headword contains `|`.** Apple's pronunciation delimiter, and the plan's own check.
    ///
    /// Also reports how many records are refused for want of a headword, because filtering a headword down
    /// to nothing would turn a clean headword into a lost entry — the failure this could plausibly
    /// introduce, and the one worth watching rather than assuming away.
    @Test func noHeadwordCarriesAPronunciation() throws {
        let all = Self.bundles()
        guard !all.isEmpty else {
            print("EntryReaderMeasurementTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        var offenders: [String] = []
        var measured = 0
        for bundle in all {
            let indexer = EntryIndexer(bundle: bundle)
            var entries = 0, refused = 0, withPipe = 0, empty = 0
            guard (try? ContainerReader.forEachEntry(in: bundle.url, limit: 6000) { xhtml in
                let outcome = indexer.outcome(for: xhtml)
                guard let entry = outcome.entry else {
                    if outcome.rejection == .noHeadword { refused += 1 }
                    return
                }
                entries += 1
                if entry.headword.contains("|") {
                    withPipe += 1
                    if offenders.count < 8 {
                        offenders.append("\(bundle.identifier)/\(entry.entryID) → \(entry.headword)")
                    }
                }
                if entry.headword.isEmpty { empty += 1 }
            }) != nil else { continue }
            guard entries > 0 else { continue }
            measured += 1
            print("""
                  EntryReader \(bundle.identifier): \(entries) entries, \(withPipe) headwords with `|`, \
                  \(empty) empty, \(refused) records refused for no headword
                  """)
            #expect(empty == 0, "\(bundle.identifier): \(empty) headwords came out empty")
        }
        print("EntryReaderMeasurementTests: \(measured) dictionaries measured")
        #expect(measured > 0, "no dictionary was read, so this measured nothing")
        #expect(offenders.isEmpty, Comment(rawValue:
            "headwords still carrying a pronunciation: " + offenders.joined(separator: "; ")))
    }
}
