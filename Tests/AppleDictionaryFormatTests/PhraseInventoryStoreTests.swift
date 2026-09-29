import Foundation
import Testing
import XiaolaiDictTestSupport
@testable import AppleDictionaryFormat

/// **The phrase inventory: what it parses, and why it is read only once.**
///
/// The markup shapes here are the ones measured in NOAD, and each was a way the first version got nothing:
/// the definition carries `class="df"` and not the `d:def` attribute, and the label's class is a token in a
/// list rather than the first thing after `class="`. Both failures return an empty answer rather than an
/// error, which is why they are tests and not comments.
struct PhraseInventoryParsingTests {
    /// **A single root, as every real record has.** The fixtures were bare sibling spans, which `XMLParser`
    /// refuses — and a scanner accepted, which is part of why it kept finding new ways to be wrong. The
    /// namespace is the one `EntryDocument.namespace` names; `FixtureNamespaceTests` enforces that.
    static func entry(_ body: String) -> String {
        """
        <d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng" id="x" d:title="x">\
        \(body)</d:entry>
        """
    }

    /// **The second shape, from `m_en_gbus0547470.050`.** `x_xoh` is a wrapper here, holding the label's text
    /// *and* its pronunciation, where the shape below puts the class on the text span itself. Reading the
    /// wrapper's whole text glued the respelling onto the phrase — and the old code avoided that only by
    /// stopping at the first `</span>`, which is also what truncated nested definitions. Fixing one exposed
    /// the other.
    static let wrappedLabel = """
        <span id="x.050" class="subEntry x_xo1">\
        <span class="x_xoh">\
        <span role="text" class="l">kick the bucket </span>\
        <span class="prx"> | <span class="ph t_respell">ˌkik T͟Hə ˈbəkət</span> | </span>\
        </span>\
        <span id="x.051" class="msDict x_xo2 t_core">\
        <span role="text" class="df">die</span>\
        </span></span>
        """

    @Test func alabelWrappingItsPronunciationYieldsOnlyThePhrase() {
        let found = PhraseInventory.subEntries(in: Self.entry(Self.wrappedLabel))
        #expect(found.count == 1)
        #expect(found.first?.phrase == "kick the bucket", "got \(found.first?.phrase ?? "none")")
        #expect(found.first?.explanation.definitions == ["die"])
    }

    /// **A definition cannot come from the next sub-entry.** Searching to the end of the entry gave a
    /// sub-entry with no definition of its own the *following* one's — the wrong meaning under the right
    /// words, which is the one failure this inventory exists to avoid. It also made every label appear to
    /// have a meaning, so 100% coverage was the bug rather than a finding.
    @Test func adefinitionDoesNotBleedFromTheNextSubEntry() {
        let markup = """
            <span class="subEntry x_xo1"><span class="l x_xoh">first phrase here </span></span>\
            <span class="subEntry x_xo1"><span class="l x_xoh">second phrase here </span>\
            <span class="msDict x_xo2"><span class="df">the second one's meaning</span></span></span>
            """
        let found = PhraseInventory.subEntries(in: Self.entry(markup))
        #expect(found.map(\.phrase) == ["second phrase here"],
                "a sub-entry with no definition must contribute nothing, got \(found)")
    }

    /// **A sense number inside a sub-entry also carries `x_xoh`**, so bounding a definition by "the next
    /// `x_xoh`" cut before it — `kick the bucket`, `beat around the bush`, `once in a blue moon` and
    /// `by all accounts` all silently lost their meanings. The enclosing block is the real boundary.
    @Test func asenseNumberInsideTheSubEntryIsNotABoundary() {
        let markup = """
            <span class="subEntry x_xo1"><span class="l x_xoh">give up here </span>\
            <span class="gp x_xoh sn ty_label">  1 </span>\
            <span class="msDict x_xo2"><span class="df">the real meaning</span></span></span>
            """
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).first?.explanation.definitions == ["the real meaning"])
    }

    /// Nested markup inside a definition is kept, not cut at the first closing tag.
    @Test func anestedDefinitionKeepsAllItsText() {
        let markup = """
            <span class="subEntry x_xo1"><span class="l x_xoh">give up here </span>\
            <span class="df">move <span class="ital">away</span> quickly</span></span>
            """
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).first?.explanation.definitions == ["move away quickly"])
    }

    /// A definition class carrying extra tokens is still a definition. Measured at zero occurrences in NOAD
    /// today — and a class Apple adds tomorrow would otherwise make every definition vanish silently.
    @Test func adefinitionWithExtraClassesIsStillFound() {
        let markup = """
            <span class="subEntry x_xo1"><span class="l x_xoh">give up here </span>\
            <span class="df t_core">a meaning</span></span>
            """
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).first?.explanation.definitions == ["a meaning"])
    }

    /// **A self-closing span opens nothing.** Counting `<span/>` as an opening left the depth permanently one
    /// too high, the walk ran to the end of the document and returned nil — discarding the whole sub-entry
    /// rather than erring visibly. Introduced by the fix for nested definitions and caught by verification.
    @Test func aselfClosingSpanDoesNotSwallowTheSubEntry() {
        let markup = """
            <span class="subEntry x_xo1"><span class="l x_xoh">give up here </span>\
            <span class="df">move <span class="br"/> quickly</span></span>
            """
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).first?.explanation.definitions == ["move quickly"])
    }

    /// **`df` in another attribute is not a class.** Whole-token matching alone accepted `<span title="df">`
    /// and `<span id="df">`, because the name is bracketed by quotes either way — so a span carrying `df`
    /// anywhere was read as the definition.
    @Test func adfInAnotherAttributeIsNotTheDefinition() {
        let markup = """
            <span class="subEntry x_xo1"><span class="l x_xoh">give up here </span>\
            <span title="df">not the definition</span>\
            <span class="df">the definition</span></span>
            """
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).first?.explanation.definitions == ["the definition"])
    }

    /// **The three shapes a hand-rolled scan kept getting wrong**, each found by a separate audit round and
    /// each dissolved by parsing instead: a `>` inside an attribute value, a class name inside another
    /// attribute, and an attribute whose name merely ends in `class`.
    @Test(arguments: [
        ("a greater-than inside an attribute", #"<span title=">"/>"#),
        ("a class name inside another attribute", #"<span title='class="df"'>wrong</span>"#),
        ("an attribute whose name ends in class", #"<span data_class="df">wrong</span>"#),
    ])
    func markupThatDefeatedTheScannerIsParsedCorrectly(name: String, noise: String) {
        let markup = """
            <span class="subEntry x_xo1"><span class="l x_xoh">give up here </span>\
            \(noise)<span class="df">the definition</span></span>
            """
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).first?.explanation.definitions == ["the definition"],
                "\(name): got \(PhraseInventory.subEntries(in: Self.entry(markup)))")
    }

    /// **Character references are decoded, because the parser decodes them.** A label reading `one&apos;s`
    /// could never match the reader's `one's`. Measured at zero occurrences in NOAD today — which is why
    /// hand-writing a decoder would have been untested code for a case that does not arise, and why getting
    /// it from the parser instead costs nothing.
    @Test func characterReferencesAreDecoded() {
        let markup = """
            <span class="subEntry x_xo1"><span class="l x_xoh">a mind of one&apos;s own </span>\
            <span class="df">independence &amp; resolve</span></span>
            """
        let found = PhraseInventory.subEntries(in: Self.entry(markup))
        #expect(found.first?.0 == "a mind of one's own")
        #expect(found.first?.explanation.definitions == ["independence & resolve"])
    }

    /// A sub-entry nested inside another is reached through its parent, not counted twice with the inner
    /// one's definition attributed to both.
    @Test func anestedSubEntryIsNotCountedTwice() {
        let markup = """
            <span class="subEntry x_xo1"><span class="l x_xoh">outer phrase here </span>\
            <span class="df">the outer meaning</span>\
            <span class="subEntry x_xo2"><span class="l x_xoh">inner phrase here </span>\
            <span class="df">the inner meaning</span></span></span>
            """
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).map(\.phrase) == ["outer phrase here"])
    }

    /// NOAD's own shape, from `m_en_gbus0005190.081`.
    static let subEntry = """
        <span id="m_en_gbus0005190.081" class="subEntry x_xo1">\
        <span role="text" class="l x_xoh">take something into account </span>\
        <span id="m_en_gbus0005190.083" class="msDict x_xo2 t_core">\
        <span role="text" class="df">consider something along with other factors before reaching a decision</span>\
        <span role="text" class="gp tg_df">: </span>\
        </span></span>
        """

    @Test func thePhraseAndItsMeaningAreBothRead() {
        let found = PhraseInventory.subEntries(in: Self.entry(Self.subEntry))
        #expect(found.count == 1)
        #expect(found.first?.phrase == "take something into account")
        #expect(found.first?.explanation.definitions
            == ["consider something along with other factors before reaching a decision"])
    }

    /// **The trailing space is removed.** The label arrives as `take something into account ` and a key with
    /// one on the end is a key that matches nothing — the whole inventory would be present and useless.
    @Test func aLabelsTrailingSpaceIsNotPartOfTheKey() {
        #expect(PhraseInventory.subEntries(in: Self.entry(Self.subEntry)).first?.phrase.hasSuffix(" ") == false)
    }

    /// **The class is matched as a whole token.** `class="l x_xoh"` is the real spelling; anchoring on
    /// `class="x_xoh` found 11 of `take`'s labels instead of all of them.
    @Test(arguments: ["l x_xoh", "x_xoh", "sn x_xoh ty_label", "x_xoh sn"])
    func theLabelIsFoundWhereverItSitsInTheClassList(classes: String) {
        let markup = Self.subEntry.replacingOccurrences(of: "class=\"l x_xoh\"", with: "class=\"\(classes)\"")
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).first?.phrase
            == "take something into account")
    }

    /// And **not** where it is only part of a longer name, which is how `x_xd1sub` once read as `x_xd1`.
    @Test func aLongerClassNameIsNotTheLabel() {
        let markup = Self.subEntry.replacingOccurrences(of: "class=\"l x_xoh\"", with: "class=\"x_xohsub\"")
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).isEmpty)
    }

    /// A one-word sub-entry is a derived form — *bucketful* under *bucket* — not a phrase a reader meets
    /// mid-sentence and fails to notice.
    @Test func aSingleWordSubEntryIsNotAPhrase() {
        let markup = Self.subEntry.replacingOccurrences(
            of: ">take something into account <", with: ">bucketful<")
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).isEmpty)
    }

    /// A sub-entry marking no definition contributes nothing rather than an empty meaning, which would print
    /// as a phrase that means nothing at all.
    @Test func aSubEntryWithNoDefinitionIsSkipped() {
        let markup = Self.subEntry.replacingOccurrences(of: "class=\"df\"", with: "class=\"note\"")
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).isEmpty)
    }

    /// **The `d:def` attribute is not what marks it.** Searching for the attribute found zero phrases in
    /// 111,606 entries — an empty answer, not an error, which is exactly how a wrong selector fails.
    @Test func theDefinitionIsFoundByClassNotByAttribute() {
        #expect(PhraseInventory.definitionClass == "df")
        let markup = Self.subEntry.replacingOccurrences(
            of: "<span role=\"text\" class=\"df\">", with: "<span role=\"text\" d:def=\"1\">")
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).isEmpty,
                "the attribute alone must not be what this looks for")
    }

    /// **Every definition under a label, in document order.** This asserted the opposite until 2026-09-29:
    /// the walk took `firstDescendant` and the rest were dropped, which for NOAD is **2,832 definitions in
    /// 1,698 blocks**. A phrasal verb is the common case — `give up` has five numbered senses — so the
    /// reader was shown one of five with nothing saying so, and *never gate, always annotate* forbids
    /// exactly that. Keeping them is also what lets a phrase card show the sense the reader met rather than
    /// the sense that happened to be first.
    @Test func everyDefinitionUnderALabelIsKept() {
        let markup = Self.subEntry.replacingOccurrences(
            of: "<span role=\"text\" class=\"gp tg_df\">: </span>",
            with: "<span role=\"text\" class=\"df\">a second sense</span>")
        #expect(PhraseInventory.subEntries(in: Self.entry(markup)).first?.explanation.definitions
            == ["consider something along with other factors before reaching a decision", "a second sense"])
    }

    /// **Where the block is filed, and what it is called.** Measured 2026-09-29: **9,762 of 9,762** NOAD
    /// sub-entry blocks carry a publisher id, and the parent is the entry document's own. The inventory
    /// discarded both, which is why a phrase looked as though (dictionary, text) were the only identity it
    /// could have — it was the only one the inventory *kept*.
    @Test func anExplanationCarriesItsParentAndItsOwnIdentifier() {
        let found = PhraseInventory.subEntries(in: Self.entry(Self.subEntry))
        #expect(found.first?.explanation.parentEntryID == "x")
        #expect(found.first?.explanation.blockID == "m_en_gbus0005190.081")
    }

    /// **A phrase filed under two parents keeps both filings.** NOAD files 18 labels under more than one
    /// entry — `blow a fuse` under *blow* and under *fuse*, meaning two different things — and the first
    /// walked won. On 牛津粵英雙語詞典 that is **70 of 647 phrases**: `add up` kept "to seem reasonable" and
    /// discarded "to find the total of several numbers".
    @Test func aPhraseFiledUnderTwoParentsKeepsBoth() {
        let under = { (parent: String, definition: String) in
            Self.entry(Self.subEntry
                .replacingOccurrences(of: "m_en_gbus0005190.081", with: "\(parent).081")
                .replacingOccurrences(
                    of: "consider something along with other factors before reaching a decision",
                    with: definition))
            .replacingOccurrences(of: "id=\"x\"", with: "id=\"\(parent)\"")
        }
        var explanations: [String: [PhraseExplanation]] = [:]
        var phrases = Set<String>()
        for entry in [under("blow", "lose one's temper"),
                      under("fuse", "use too much power in an electrical circuit")] {
            PhraseInventory.accumulate(entry, into: &explanations, phrases: &phrases)
        }
        let found = explanations["take something into account"] ?? []
        #expect(found.count == 2, "both filings must survive, got \(found.count)")
        #expect(found.map(\.parentEntryID) == ["blow", "fuse"])
        #expect(found.flatMap(\.definitions)
            == ["lose one's temper", "use too much power in an electrical circuit"])
    }
}

/// **Read once per build of a dictionary, and `contentVersion` is what decides.**
struct PhraseInventoryStoreTests {
    private func store() -> (PhraseInventoryStore, TemporaryDirectory) {
        let scratch = TemporaryDirectory(named: "phrases")
        return (PhraseInventoryStore(directory: scratch.url), scratch)
    }

    @Test func anInventorySurvivesBeingWrittenAndRead() throws {
        let (store, scratch) = store()
        let inventory = PhraseInventory(
            contentVersion: "v1",
            phrases: ["kick the bucket", "purple passage"],
            explanations: ["kick the bucket": [
                PhraseExplanation(parentEntryID: "b1", blockID: "b1.01", definitions: ["die"])]])
        try store.write(inventory, for: "noad")
        #expect(try store.read("noad") == inventory)
        _ = scratch
    }

    /// **A phrase with no meaning survives the round trip as one.** The key index contributes spellings
    /// without definitions, and a format that lost them would silently shrink the inventory to the 8% the
    /// dictionaries explain.
    @Test func aPhraseWithNoMeaningIsStillAPhrase() throws {
        let inventory = PhraseInventory(
            contentVersion: "v1", phrases: ["purple passage"], explanations: [:])
        let back = try #require(PhraseInventory(decoding: inventory.encoded()))
        #expect(back.phrases == ["purple passage"])
        #expect(back.explanations.isEmpty)
    }

    /// An inventory written by a format this build does not read is refused, not guessed at — the same rule
    /// the index follows for an unknown schema.
    @Test func anUnknownFormatIsRefused() {
        #expect(PhraseInventory(decoding: "phrases/99\tv1\nkick the bucket\tdie") == nil)
        #expect(PhraseInventory(decoding: "") == nil)
        #expect(PhraseInventory(decoding: "no tab here") == nil)
    }

    /// **A phrase carrying a tab is skipped rather than escaped.** It would split into two fields and come
    /// back as a phrase nothing matches; no measured key contains one, and an escape scheme for a case that
    /// does not arise is a parser nobody has tested.
    @Test func aphraseCarryingATabIsNotWritten() throws {
        let inventory = PhraseInventory(
            contentVersion: "v1", phrases: ["kick the bucket", "bad\tphrase"], explanations: [:])
        let back = try #require(PhraseInventory(decoding: inventory.encoded()))
        #expect(back.phrases == ["kick the bucket"])
    }

    /// A newline inside a definition is flattened, for the same reason.
    @Test func anewlineInAMeaningIsFlattened() throws {
        let inventory = PhraseInventory(
            contentVersion: "v1", phrases: ["kick the bucket"],
            explanations: ["kick the bucket": [
                PhraseExplanation(parentEntryID: "p", blockID: "p.01",
                                  definitions: ["die\nor expire"])]])
        let back = try #require(PhraseInventory(decoding: inventory.encoded()))
        #expect(back.explanations["kick the bucket"]?.first?.definitions == ["die or expire"])
    }

    /// **And a tab, which the old format could tolerate and this one cannot.** A meaning was everything
    /// after the first tab, so an embedded one survived; a definition is now its own field, and an
    /// unflattened tab would arrive as an extra definition the dictionary never wrote.
    @Test func atabInsideADefinitionIsFlattened() throws {
        let inventory = PhraseInventory(
            contentVersion: "v1", phrases: ["kick the bucket"],
            explanations: ["kick the bucket": [
                PhraseExplanation(parentEntryID: "p", blockID: "p.01", definitions: ["die\tor expire"])]])
        let back = try #require(PhraseInventory(decoding: inventory.encoded()))
        #expect(back.explanations["kick the bucket"]?.first?.definitions == ["die or expire"])
    }

    /// Every filing of a phrase, and every definition in each, survives being written and read.
    @Test func everyFilingSurvivesTheRoundTrip() throws {
        let inventory = PhraseInventory(
            contentVersion: "v1", phrases: ["blow a fuse"],
            explanations: ["blow a fuse": [
                PhraseExplanation(parentEntryID: "blow", blockID: "blow.01",
                                  definitions: ["lose one's temper", "a second sense"]),
                PhraseExplanation(parentEntryID: "fuse", blockID: "fuse.09",
                                  definitions: ["use too much power"])]])
        #expect(PhraseInventory(decoding: inventory.encoded()) == inventory)
    }

    /// **The explanation section has its own count, and a file cut inside it is refused.** One count could
    /// only guard the section it counted: a file whose phrase list was whole and whose explanations were
    /// half-written matched the header and was read as current for ever.
    @Test func afileCutInsideTheExplanationsIsRefused() throws {
        let inventory = PhraseInventory(
            contentVersion: "v1", phrases: ["blow a fuse", "kick the bucket"],
            explanations: ["blow a fuse": [
                PhraseExplanation(parentEntryID: "blow", blockID: "blow.01", definitions: ["rage"])],
                           "kick the bucket": [
                PhraseExplanation(parentEntryID: "kick", blockID: "kick.01", definitions: ["die"])]])
        let whole = inventory.encoded()
        #expect(PhraseInventory(decoding: whole) != nil, "the whole file reads")
        let cut = whole.split(separator: "\n").dropLast().joined(separator: "\n")
        #expect(PhraseInventory(decoding: cut) == nil, "one explanation short must be refused")
    }

    /// Nothing stored is nil, not an empty inventory — an empty one would be indistinguishable from a
    /// dictionary that genuinely has no phrases, and would never be re-read.
    @Test func nothingStoredIsNothingRatherThanEmpty() throws {
        let (store, scratch) = store()
        #expect(try store.read("noad") == nil)
        _ = scratch
    }

    /// A half-written file decodes as nothing rather than as an empty inventory, for the same reason.
    @Test func atruncatedFileIsNotAnInventory() throws {
        let (store, scratch) = store()
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data("phrases".utf8).write(to: store.file(for: "noad"))
        #expect(try store.read("noad") == nil)
    }

    /// **The file is named by identifier, never by display name.** A name is localized, so a Chinese
    /// interface would file the same dictionary under a different one and read it again every launch.
    @Test func thefileIsNamedByIdentifier() {
        let (store, scratch) = store()
        #expect(store.file(for: "com.apple.dictionary.NOAD").lastPathComponent
            == "com.apple.dictionary.NOAD.phrases")
        _ = scratch
    }
}

/// **Nothing inside a dictionary is another dictionary, so the search must not look.**
///
/// `.skipsPackageDescendants` does not cover these — `.dictionary` is not a registered package type — so the
/// walker descended into every bundle's `Contents/Resources`, which for NOAD alone is a 100 MB body. Measured
/// 2026-09-29: **2.11 s to list 12 dictionaries, against 0.014 s** once the descent stops. Every caller of
/// `installed()` paid it, and the phrase inventory paid it on every launch.
///
/// Asserted on the structure rather than on a clock: a nested bundle is found only by a search that descended.
struct DictionarySearchDepthTests {
    @Test func thesearchDoesNotLookInsideABundle() throws {
        let scratch = TemporaryDirectory(named: "locator")
        let outer = scratch.appending("Outer.dictionary")
        // A bundle inside a bundle — which no real asset has, and which only a descending walk can see.
        let inner = outer.appending(path: "Contents/Resources/Inner.dictionary")
        for (bundle, identifier) in [(outer, "test.outer"), (inner, "test.inner")] {
            try FileManager.default.createDirectory(
                at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": identifier]
            try PropertyListSerialization
                .data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: bundle.appending(path: "Contents/Info.plist"))
        }
        let found = DictionaryLocator.installed(in: [scratch.url]).map(\.identifier)
        #expect(found == ["test.outer"], "the search descended into a bundle and found \(found)")
    }
}
