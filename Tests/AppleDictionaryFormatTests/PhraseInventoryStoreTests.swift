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
        let found = PhraseInventory.subEntries(in: Self.subEntry)
        #expect(found.count == 1)
        #expect(found.first?.0 == "take something into account")
        #expect(found.first?.1 == "consider something along with other factors before reaching a decision")
    }

    /// **The trailing space is removed.** The label arrives as `take something into account ` and a key with
    /// one on the end is a key that matches nothing — the whole inventory would be present and useless.
    @Test func aLabelsTrailingSpaceIsNotPartOfTheKey() {
        #expect(PhraseInventory.subEntries(in: Self.subEntry).first?.0.hasSuffix(" ") == false)
    }

    /// **The class is matched as a whole token.** `class="l x_xoh"` is the real spelling; anchoring on
    /// `class="x_xoh` found 11 of `take`'s labels instead of all of them.
    @Test(arguments: ["l x_xoh", "x_xoh", "sn x_xoh ty_label", "x_xoh sn"])
    func theLabelIsFoundWhereverItSitsInTheClassList(classes: String) {
        let markup = Self.subEntry.replacingOccurrences(of: "class=\"l x_xoh\"", with: "class=\"\(classes)\"")
        #expect(PhraseInventory.subEntries(in: markup).first?.0 == "take something into account")
    }

    /// And **not** where it is only part of a longer name, which is how `x_xd1sub` once read as `x_xd1`.
    @Test func aLongerClassNameIsNotTheLabel() {
        let markup = Self.subEntry.replacingOccurrences(of: "class=\"l x_xoh\"", with: "class=\"x_xohsub\"")
        #expect(PhraseInventory.subEntries(in: markup).isEmpty)
    }

    /// A one-word sub-entry is a derived form — *bucketful* under *bucket* — not a phrase a reader meets
    /// mid-sentence and fails to notice.
    @Test func aSingleWordSubEntryIsNotAPhrase() {
        let markup = Self.subEntry.replacingOccurrences(
            of: ">take something into account <", with: ">bucketful<")
        #expect(PhraseInventory.subEntries(in: markup).isEmpty)
    }

    /// A sub-entry marking no definition contributes nothing rather than an empty meaning, which would print
    /// as a phrase that means nothing at all.
    @Test func aSubEntryWithNoDefinitionIsSkipped() {
        let markup = Self.subEntry.replacingOccurrences(of: "class=\"df\"", with: "class=\"note\"")
        #expect(PhraseInventory.subEntries(in: markup).isEmpty)
    }

    /// **The `d:def` attribute is not what marks it.** Searching for the attribute found zero phrases in
    /// 111,606 entries — an empty answer, not an error, which is exactly how a wrong selector fails.
    @Test func theDefinitionIsFoundByClassNotByAttribute() {
        #expect(PhraseInventory.definitionClass == "df")
        let markup = Self.subEntry.replacingOccurrences(
            of: "<span role=\"text\" class=\"df\">", with: "<span role=\"text\" d:def=\"1\">")
        #expect(PhraseInventory.subEntries(in: markup).isEmpty,
                "the attribute alone must not be what this looks for")
    }

    /// The first definition under a label, where a sub-entry marks several.
    @Test func theFirstDefinitionUnderALabelIsTheMeaning() {
        let markup = Self.subEntry.replacingOccurrences(
            of: "<span role=\"text\" class=\"gp tg_df\">: </span>",
            with: "<span role=\"text\" class=\"df\">a second sense</span>")
        #expect(PhraseInventory.subEntries(in: markup).first?.1
            == "consider something along with other factors before reaching a decision")
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
            meanings: ["kick the bucket": "die"])
        try store.write(inventory, for: "noad")
        #expect(try store.read("noad") == inventory)
        _ = scratch
    }

    /// **A phrase with no meaning survives the round trip as one.** The key index contributes spellings
    /// without definitions, and a format that lost them would silently shrink the inventory to the 8% the
    /// dictionaries explain.
    @Test func aPhraseWithNoMeaningIsStillAPhrase() throws {
        let inventory = PhraseInventory(contentVersion: "v1", phrases: ["purple passage"], meanings: [:])
        let back = try #require(PhraseInventory(decoding: inventory.encoded()))
        #expect(back.phrases == ["purple passage"])
        #expect(back.meanings.isEmpty)
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
            contentVersion: "v1", phrases: ["kick the bucket", "bad\tphrase"], meanings: [:])
        let back = try #require(PhraseInventory(decoding: inventory.encoded()))
        #expect(back.phrases == ["kick the bucket"])
    }

    /// A newline inside a meaning is flattened, for the same reason.
    @Test func anewlineInAMeaningIsFlattened() throws {
        let inventory = PhraseInventory(
            contentVersion: "v1", phrases: ["kick the bucket"],
            meanings: ["kick the bucket": "die\nor expire"])
        let back = try #require(PhraseInventory(decoding: inventory.encoded()))
        #expect(back.meanings["kick the bucket"] == "die or expire")
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
