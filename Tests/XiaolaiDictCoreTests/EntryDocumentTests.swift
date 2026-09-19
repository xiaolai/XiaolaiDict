import XiaolaiDictCore
import Testing

/// What can be read out of the document a dictionary returns. The structural layer — `d:entry`'s
/// id, and in Apple's nine dictionaries the `x_` blocks — is the same across the installed
/// dictionaries; the class names on top of it are not (`dev-docs/dictionary-markup.md` §3).
struct EntryDocumentTests {
    private static func document(_ body: String, xmlns: String = #" xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng""#) -> String {
        """
        <html xmlns="http://www.w3.org/1999/xhtml"\(xmlns)><head><style>p { margin: 0 }</style></head>\
        <body>\(body)</body></html>
        """
    }

    @Test func theEntryIDIsRead() throws {
        let parsed = try #require(EntryDocument.parse(Self.document(#"<d:entry id="m_en_gbus0472980"><p>x</p></d:entry>"#)))
        #expect(parsed.entryID == "m_en_gbus0472980")
        #expect(parsed.isStyled)
    }

    /// The prefix bound to Apple's namespace is the document's business, not a constant to assume.
    @Test func anotherPrefixForApplesNamespaceStillResolves() throws {
        let xhtml = Self.document(
            #"<dict:entry id="e_id021397"><p>x</p></dict:entry>"#,
            xmlns: #" xmlns:dict="http://www.apple.com/DTDs/DictionaryService-1.0.rng""#)
        #expect(EntryDocument.parse(xhtml)?.entryID == "e_id021397")
    }

    /// An `entry` element outside Apple's namespace is somebody else's element.
    @Test func anEntryElementInAnotherNamespaceIsNotAnEntry() throws {
        let parsed = try #require(EntryDocument.parse(Self.document(#"<entry id="nope"><p>x</p></entry>"#)))
        #expect(parsed.entryID == nil)
    }

    /// Unknown, never guessed — and never an empty string passed off as an id.
    @Test(arguments: [
        #"<d:entry><p>x</p></d:entry>"#,
        #"<d:entry id=""><p>x</p></d:entry>"#,
        #"<d:entry id="   "><p>x</p></d:entry>"#,
        #"<p>no entry at all</p>"#,
    ])
    func anAbsentOrBlankIDIsNil(body: String) throws {
        #expect(try #require(EntryDocument.parse(Self.document(body))).entryID == nil)
    }

    /// The first, when a document somehow carries more than one record's entry.
    @Test func theFirstEntryWins() {
        let body = #"<d:entry id="first"><p>x</p></d:entry><d:entry id="second"><p>y</p></d:entry>"#
        #expect(EntryDocument.parse(Self.document(body))?.entryID == "first")
    }

    @Test func textThatIsNotXMLDoesNotParse() {
        #expect(EntryDocument.parse("ephemeral: lasting a very short time") == nil)
        #expect(EntryDocument.parse("<html><body><p>unclosed</body></html>") == nil)
    }

    /// The styled form's promise, checked on the same walk that reads the structure.
    @Test func aDocumentWithoutAnInlinedStylesheetIsNotStyled() throws {
        let bare = #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>x</p></body></html>"#
        #expect(try #require(EntryDocument.parse(bare)).isStyled == false)
    }
}

/// The homograph marker — NOAD's *fine¹ fine² fine³ fine⁴* — is what lets the panel label four
/// entries that share a headword. Measured present once per entry in NOAD, 譯典通 and the Writer's
/// Thesaurus; absent in 牛津英汉汉英, which files each homograph as its own record instead.
struct EntryHomographTests {
    private static func document(_ body: String) -> String {
        """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng">\
        <head><style>p { margin: 0 }</style></head><body>\(body)</body></html>
        """
    }

    @Test func theHomographMarkerIsRead() {
        let body = #"""
            <d:entry id="m_en_gbus0362750"><span class="hg x_xh0">\
            <span role="text" homograph="1" class="hw">fine<span class="gp ty_hom tg_hw"> 1 </span></span>\
            </span></d:entry>
            """#
        #expect(EntryDocument.parse(Self.document(body))?.homograph == "1")
    }

    /// 牛津英汉汉英 has no marker; an entry without one is not given a made-up ordinal.
    @Test func anEntryWithoutAMarkerHasNone() {
        let body = #"<d:entry id="e_b-en-zh_hans0013659"><span class="hwg x_xh0"><span class="hw">fine</span></span></d:entry>"#
        #expect(EntryDocument.parse(Self.document(body))?.homograph == nil)
    }

    /// Only inside the headword block: a `homograph` attribute on a cross-reference elsewhere in the
    /// entry points at another word, and labelling this entry with it would be a lie.
    @Test func aMarkerOutsideTheHeadwordBlockIsIgnored() {
        let body = #"""
            <d:entry id="x"><span class="hwg x_xh0"><span class="hw">fine</span></span>\
            <span class="xrg"><span homograph="3" class="xr">see fine<span/></span></span></d:entry>
            """#
        #expect(EntryDocument.parse(Self.document(body))?.homograph == nil)
    }
}
