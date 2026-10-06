import Foundation
import Testing
import XiaolaiDictTestSupport
@testable import AppleDictionaryFormat

/// **What a dictionary prints as inflections, and nothing it files.** The markup is invented in the shape
/// measured in NOAD: the licensed text is never committed (`ContainerReaderTests` says why).
struct InflectionInventoryParsingTests {
    static func entry(title: String? = "break", _ body: String) -> String {
        let attribute = title.map { " d:title=\"\($0)\"" } ?? ""
        return """
            <d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng" id="x"\(attribute)>\
            <span class="hg x_xh0"><span class="hw">break</span></span>\(body)</d:entry>
            """
    }

    static func block(_ label: String, _ groups: String) -> String {
        """
        <span class="se1 x_xd0"><span class="posg x_xdh"><span class="pos"><span class="gp">\(label) </span></span>\
        \(groups)</span></span>
        """
    }

    static func group(_ label: String?, _ form: String) -> String {
        let sy = label.map { "<span class=\"sy\">\($0)</span> " } ?? ""
        return """
            <span class="infg"><span class="gp">(</span>\(sy)<span class="inf">\(form) </span>\
            <span class="pr"> | <span class="ph">brōk</span> | </span><span class="gp">)</span></span>
            """
    }

    static func forms(_ xhtml: String) -> [String: Set<InflectionInventory.Reading>] {
        var out: [String: Set<InflectionInventory.Reading>] = [:]
        InflectionInventory.accumulate(xhtml, into: &out)
        return out
    }

    @Test func aPrintedFormIsFiledUnderTheHeadwordWithTheClassItWasPrintedIn() {
        let found = Self.forms(Self.entry(Self.block("verb", Self.group("past", "broke") + Self.group("past participle", "broken"))))
        #expect(found["broke"] == [.init(lemma: "break", partOfSpeech: "verb")])
        #expect(found["broken"] == [.init(lemma: "break", partOfSpeech: "verb")])
        #expect(found.count == 2, "the pronunciation next to a form is not a form: \(found.keys.sorted())")
    }

    @Test func aFormPrintedUnderTwoHeadwordsKeepsBothReadings() {
        var out: [String: Set<InflectionInventory.Reading>] = [:]
        InflectionInventory.accumulate(Self.entry(title: "lie", Self.block("verb", Self.group("past", "lay"))), into: &out)
        InflectionInventory.accumulate(Self.entry(title: "lay", Self.block("verb", Self.group("past", "lay"))), into: &out)
        #expect(out["lay"]?.map(\.lemma).sorted() == ["lie"], "a headword restated is not a form of itself")
        InflectionInventory.accumulate(Self.entry(title: "lie", Self.block("noun", Self.group(nil, "lay"))), into: &out)
        #expect(out["lay"]?.map(\.partOfSpeech).sorted() == ["noun", "verb"])
    }

    @Test func theClassIsTheBlocksNotTheEntrys() {
        let two = Self.entry(Self.block("noun", Self.group("plural", "breaks")) + Self.block("verb", Self.group(nil, "breaking")))
        let found = Self.forms(two)
        #expect(found["breaks"] == [.init(lemma: "break", partOfSpeech: "noun")])
        #expect(found["breaking"] == [.init(lemma: "break", partOfSpeech: "verb")])
    }

    /// **A sub-entry's inflections belong to its label.** `gave up` filed under *give* is a phrase's form, and
    /// the lemmatiser is handed a word at a time.
    @Test func aSubEntrysInflectionsAreNotItsParents() {
        let sub = "<span class=\"subEntry x_xo1\"><span class=\"l x_xoh\">break out </span>\(Self.group("past", "broke out"))</span>"
        #expect(Self.forms(Self.entry(Self.block("verb", sub))).isEmpty)
    }

    @Test(arguments: ["cc'd", "mfrs.", "@ed", "snow men", "mothers-in-law", "x2", ""])
    func aFormThatIsNotOneAlphabeticWordIsNeverAsked(form: String) {
        #expect(Self.forms(Self.entry(Self.block("verb", Self.group("past", form)))).isEmpty, "kept \(form)")
    }

    @Test func aSuffixEntryTitledWithAPlaceholderFilesNothing() {
        #expect(Self.forms(Self.entry(title: "@", Self.block("verb", Self.group("past", "ed")))).isEmpty)
    }

    @Test func aGroupOutsideEveryBlockCarriesNoClass() {
        let found = Self.forms(Self.entry(Self.group("plural", "breaks")))
        #expect(found["breaks"] == [.init(lemma: "break", partOfSpeech: "")])
    }

    @Test func theHeadwordBlockNamesTheEntryWhereNoTitleIsDeclared() {
        let found = Self.forms(Self.entry(title: nil, Self.block("verb", Self.group("past", "broke"))))
        #expect(found["broke"]?.first?.lemma == "break")
    }

    @Test func anEntryWithNoInflectionsAndARecordThatIsNotXMLAreSkipped() {
        #expect(Self.forms(Self.entry(Self.block("verb", ""))).isEmpty)
        #expect(Self.forms("<d:entry><infg").isEmpty)
    }

    /// **By whole word**, the project's rule for every part-of-speech label: `pronoun` is not a noun.
    @Test(arguments: [("verb", "verb"), ("phrasal verb", "verb"), ("plural noun", "noun"), ("adjective", "adjective"),
                      ("adverb", "adverb"), ("pronoun", ""), ("exclamation", ""), ("", "")])
    func aLabelIsMatchedByWholeWord(label: String, expected: String) {
        #expect(InflectionInventory.partOfSpeech(from: label) == expected)
    }
}

/// **The read, end to end, against a body the test wrote** — the wire the parsing tests cannot see: that the
/// walk reaches the entries, and that a form which is another entry's headword is told from one that is not.
struct InflectionInventoryReadTests {
    typealias Parsing = InflectionInventoryParsingTests

    @Test func aFormThatIsAlsoAnEntrysTitleIsMarkedAndOneThatIsNotIsNot() throws {
        let scratch = TemporaryDirectory()
        let bundle = try SyntheticDictionary.bundle(in: scratch, identifier: "test.english", entries: [
            Parsing.entry(title: "find", Parsing.block("verb", Parsing.group("past", "found"))),
            Parsing.entry(title: "found", Parsing.block("verb", "")),
            Parsing.entry(title: "swear", Parsing.block("verb", Parsing.group("past", "swore"))),
            Parsing.entry(title: "hot dog", Parsing.block("noun", "")),
            Parsing.entry(title: "x-ray", Parsing.block("noun", "")),
        ])
        let inventory = try InflectionInventory.read(bundle)
        #expect(Set(inventory.forms.keys) == ["found", "swore"])
        #expect(inventory.ownHeadwords == ["found"], "got \(inventory.ownHeadwords)")
        #expect(inventory.contentVersion == bundle.contentVersion())
        #expect(inventory.headwords == ["find", "found", "swear"], "the word list is every one-word title")
    }

    @Test func aDictionaryPrintingNothingYieldsAnEmptyInventoryNotAFailure() throws {
        let scratch = TemporaryDirectory()
        let bundle = try SyntheticDictionary.bundle(in: scratch, identifier: "test.thesaurus", entries: [
            Parsing.entry(title: "big", Parsing.block("adjective", "")),
        ])
        let inventory = try InflectionInventory.read(bundle)
        #expect(inventory.forms.isEmpty && inventory.ownHeadwords.isEmpty)
    }
}

/// **Found by the branch audit**, each a way the first version was quietly wrong.
struct InflectionInventoryAuditTests {
    typealias Parsing = InflectionInventoryParsingTests

    /// A record with no `d:title` still names its headword from the headword block, so its form is protected.
    @Test func aTitlelessEntryStillProtectsItsOwnHeadword() throws {
        let scratch = TemporaryDirectory()
        let bare = Parsing.entry(title: nil, "").replacingOccurrences(of: "break", with: "found")
        let bundle = try SyntheticDictionary.bundle(in: scratch, identifier: "test.titleless", entries: [
            Parsing.entry(title: "find", Parsing.block("verb", Parsing.group("past", "found"))), bare,
        ])
        let inventory = try InflectionInventory.read(bundle)
        #expect(inventory.ownHeadwords == ["found"], "got \(inventory.ownHeadwords)")
        #expect(inventory.headwords.contains("found"))
    }

    /// A sub-entry marked only `x_xo1` — no `subEntry` token — is still a sub-entry.
    @Test func aSubEntryMarkedOnlyByItsDepthClassKeepsItsInflectionsToItself() {
        let sub = "<span class=\"x_xo1\"><span class=\"l x_xoh\">break out </span>\(Parsing.group("past", "outbroke"))</span>"
        #expect(Parsing.forms(Parsing.entry(Parsing.block("verb", sub))).isEmpty,
                "a one-word form, so only the sub-entry test can have kept it out")
    }

    /// `chassés` with a combining accent is the same word as the precomposed one.
    @Test func aDecomposedAccentIsTheSameWordAsAComposedOne() {
        let composed = "chass\u{e9}s", decomposed = "chasse\u{301}s"
        let a = Parsing.forms(Parsing.entry(title: "chass\u{e9}", Parsing.block("noun", Parsing.group("plural", composed))))
        let b = Parsing.forms(Parsing.entry(title: "chasse\u{301}", Parsing.block("noun", Parsing.group("plural", decomposed))))
        #expect(a == b && a.count == 1, "\(a.keys.map(\.unicodeScalars.count)) vs \(b.keys.map(\.unicodeScalars.count))")
    }

    @Test func anEntryThatPrintedFormsReturnsItsHeadwordSoItIsNotParsedAgain() {
        var out: [String: Set<InflectionInventory.Reading>] = [:]
        #expect(InflectionInventory.accumulate(Parsing.entry(Parsing.block("verb", Parsing.group("past", "broke"))), into: &out) == .named("break"))
        #expect(InflectionInventory.accumulate(Parsing.entry(Parsing.block("verb", "")), into: &out) == .unread)
        let placeholder = Parsing.entry(title: "@", Parsing.block("verb", Parsing.group("past", "ed")))
        #expect(InflectionInventory.accumulate(placeholder, into: &out) == .named(""), "parsed, no usable headword: not parsed again")
    }

    @Test func aSuppliedVersionIsUsedAndNotComputedAgain() throws {
        let scratch = TemporaryDirectory()
        let bundle = try SyntheticDictionary.bundle(in: scratch, identifier: "test.v", entries: [Parsing.entry(Parsing.block("verb", ""))])
        #expect(try InflectionInventory.read(bundle, contentVersion: "given").contentVersion == "given")
        #expect(try InflectionInventory.read(bundle).contentVersion == bundle.contentVersion())
    }
}

/// **The whole-tree parse reads every alias**, not only the first the document bound.
struct EntryTreeAliasTests {
    @Test func aTitleUnderTheSecondAliasIsFoundByTheWholeTreeToo() throws {
        let namespace = "http://www.apple.com/DTDs/DictionaryService-1.0.rng"
        let xhtml = """
            <d:entry xmlns:d="\(namespace)" xmlns:dict="\(namespace)" id="x" dict:title="run">\
            <span class="se1 x_xd0"><span class="pos"><span class="gp">verb </span></span>\
            \(InflectionInventoryParsingTests.group("past", "ran"))</span></d:entry>
            """
        let tree = try #require(EntryTree.parse(xhtml))
        #expect(tree.dictionaryAttribute("title", of: tree.root) == "run")
        var out: [String: Set<InflectionInventory.Reading>] = [:]
        InflectionInventory.accumulate(xhtml, into: &out)
        #expect(out["ran"] == [.init(lemma: "run", partOfSpeech: "verb")])
    }
}

/// A prefix bound to Apple's namespace in one subtree and to another vocabulary in another is ambiguous.
struct AmbiguousAliasTests {
    @Test func aPrefixAlsoBoundToAnotherVocabularyIsNotTakenAsApples() throws {
        let namespace = "http://www.apple.com/DTDs/DictionaryService-1.0.rng"
        let xhtml = """
            <d:entry xmlns:d="\(namespace)" xmlns:q="urn:other" id="x"><span q:title="foreign"/>\
            <span xmlns:q="\(namespace)"/></d:entry>
            """
        let tree = try #require(EntryTree.parse(xhtml))
        let span = try #require(tree.root.firstDescendant { $0.attributes["q:title"] != nil })
        #expect(tree.dictionaryAttribute("title", of: span) == nil, "a foreign q:title was read as Apple's")
    }
}

struct EnglishMonolingualTests {
    private func bundle(_ languages: [(String, String)]) -> DictionaryBundle {
        DictionaryBundle(url: URL(fileURLWithPath: "/x"), identifier: "x", displayName: "x",
                         languages: languages.map { DeclaredLanguage(index: $0.0, explains: $0.1) })
    }

    @Test func onlyADictionaryOfEnglishInEnglishAndNothingElseQualifies() {
        #expect(bundle([("en_US", "en_US")]).isEnglishMonolingual)
        #expect(bundle([("en_GB", "en_GB")]).isEnglishMonolingual)
        #expect(!bundle([("de", "de"), ("en", "de")]).isEnglishMonolingual, "a bilingual's groups are another language's")
        #expect(!bundle([("zh_CN", "zh_CN"), ("en", "zh_CN")]).isEnglishMonolingual)
        #expect(!bundle([]).isEnglishMonolingual, "an undeclared bundle is not guessed into the set")
    }
}

struct EntryTitleTests {
    private let namespace = "http://www.apple.com/DTDs/DictionaryService-1.0.rng"

    @Test func theTitleIsReadFromTheOpeningTagUnderWhicheverPrefixBindsTheNamespace() {
        #expect(EntryTree.title(of: "<d:entry xmlns:d=\"\(namespace)\" id=\"a\" d:title=\"break\"><x/></d:entry>") == "break")
        #expect(EntryTree.title(of: "<dict:entry xmlns:dict=\"\(namespace)\" dict:title=\"run\"/>") == "run")
    }

    @Test func aTitleBoundToAnotherVocabularyIsNotApples() {
        #expect(EntryTree.title(of: "<d:entry xmlns:d=\"urn:other\" d:title=\"x\"/>") == nil)
    }

    @Test func aRecordWithNoTitleOrNoElementHasNone() {
        #expect(EntryTree.title(of: "<d:entry xmlns:d=\"\(namespace)\" id=\"a\"/>") == nil)
        #expect(EntryTree.title(of: "") == nil)
        #expect(EntryTree.title(of: "plain text") == nil)
    }

    /// **Two aliases for Apple's namespace**: the title may sit under either, and which one the tag's unordered
    /// attributes listed first must not decide whether it is found.
    @Test func everyAliasOfTheNamespaceIsTriedForTheTitle() {
        let both = "<d:entry xmlns:d=\"\(namespace)\" xmlns:dict=\"\(namespace)\" dict:title=\"run\"/>"
        for _ in 0 ..< 20 { #expect(EntryTree.title(of: both) == "run") }
        #expect(EntryTree.namespaceBindings(in: ["xmlns:dict": namespace, "xmlns:d": namespace, "xmlns:z": namespace]).apple == ["d", "dict", "z"],
                "a fixed order, the conventional prefix first")
    }

    /// A `>` inside an attribute value is the shape that broke the hand-rolled scans. It is a parse here.
    @Test func aGreaterThanInsideAnAttributeValueIsPartOfTheValue() {
        #expect(EntryTree.title(of: "<d:entry xmlns:d=\"\(namespace)\" d:title=\"a &gt; b\"/>") == "a > b")
    }
}
