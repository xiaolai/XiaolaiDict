import Foundation
import Testing
@testable import AppleDictionaryFormat

/// The node model, on invented markup where the right answer is known by construction.
@Suite struct EntryTreeTests {
    /// Re-emits a node's inline content in document order. Test-only: the module never needs to write
    /// markup, but *proving* the order survives needs something that can put it back.
    static func markup(of node: EntryNode) -> String {
        var out = "<\(node.name)>"
        for item in node.content {
            switch item {
            case .text(let s): out += s
            case .element(let child): out += markup(of: child)
            }
        }
        return out + "</\(node.name)>"
    }

    /// **Mixed content must keep its order**, because the definition's text feeds the sense's hash.
    /// Collapsing `text` and `children` into separate fields makes these two the same definition, and they
    /// are not.
    @Test func interleavedTextAndElementsAreNotCollapsed() {
        let a = EntryTree.parse("<df>turn <b>off</b> now</df>")!
        let b = EntryTree.parse("<df>turn now<b>off</b></df>")!
        #expect(a.root.text == "turn off now")
        #expect(b.root.text == "turn nowoff")
        #expect(a.root.text != b.root.text, "losing the interleaving would change sense identities")
        #expect(SenseKey.digest(of: a.root.text) != SenseKey.digest(of: b.root.text))
    }

    /// **Round-trip of ordered inline content is byte-identical.** The plan's own check for the node model.
    @Test func orderedInlineContentRoundTripsByteIdentically() {
        for original in [
            "<df>turn <b>off</b> now</df>",
            "<df>turn now<b>off</b></df>",
            "<df>a<b>b</b>c<i>d</i>e</df>",
            "<df><b>leading</b> then text</df>",
            "<df>text then <b>trailing</b></df>",
            "<df>deep <b>one <i>two</i> three</b> four</df>",
            "<df></df>",
        ] {
            let tree = EntryTree.parse(original)
            #expect(tree != nil, "fixture did not parse: \(original)")
            #expect(Self.markup(of: tree!.root) == original, "round-trip changed: \(original)")
        }
    }

    /// **CDATA is text.** `foundCDATA` was not implemented, so a definition written this way read empty —
    /// and an empty definition is simply not appended, which makes the loss silent.
    @Test func cdataIsReadAsText() {
        let tree = EntryTree.parse("<df><![CDATA[a marsh plant that glows]]></df>")
        #expect(tree?.root.text == "a marsh plant that glows")
    }

    @Test func cdataInterleavesWithOrdinaryTextInOrder() {
        let tree = EntryTree.parse("<df>before <![CDATA[middle]]> after</df>")
        #expect(tree?.root.text == "before middle after")
    }

    /// **The namespace prefix is read from the document, not assumed to be `d`.** The flat reader matched a
    /// literal `d:` while its docstring claimed it resolved the namespace.
    @Test func theNamespacePrefixIsResolvedFromTheDeclaration() {
        let asD = EntryTree.parse("""
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1">\
            <span d:def="1" class="df">a small device</span></d:entry>
            """)!
        #expect(asD.prefix == "d")
        let df = asD.root.firstDescendant { $0.classes.contains("df") }!
        #expect(asD.dictionaryAttribute("def", of: df) == "1")

        let asDict = EntryTree.parse("""
            <dict:entry xmlns:dict="\(EntryTree.namespace)" id="e1">\
            <span dict:def="1" class="df">a small device</span></dict:entry>
            """)!
        #expect(asDict.prefix == "dict")
        let other = asDict.root.firstDescendant { $0.classes.contains("df") }!
        #expect(asDict.dictionaryAttribute("def", of: other) == "1",
                "a document binding the namespace to another prefix must read the same")
    }

    /// A prefix bound to some other namespace must not be taken for Apple's.
    /// A prefix bound to some other namespace must not be taken for Apple's — and the earlier version of
    /// this test only checked the *fallback*, so it passed while `xmlns:d="urn:unrelated"` plus `d:def="1"`
    /// was being read as Apple's attribute.
    @Test func anUnrelatedNamespaceDoesNotClaimThePrefix() {
        let tree = EntryTree.parse("""
            <x:entry xmlns:x="http://example.invalid/other" id="e1">\
            <span class="df">a small device</span></x:entry>
            """)!
        #expect(tree.prefix == nil, "no declaration named Apple's namespace")

        // A document with no declaration at all is still read: the conventional `d:` is the fallback.
        let undeclared = EntryTree.parse("<d:entry id=\"e1\"><span d:def=\"1\" class=\"df\">x</span></d:entry>")!
        let df = undeclared.root.firstDescendant { $0.classes.contains("df") }!
        #expect(undeclared.dictionaryAttribute("def", of: df) == "1")

        // But a document that binds `d` to something else has no Apple attributes.
        let foreign = EntryTree.parse("""
            <d:entry xmlns:d="urn:unrelated" id="e1">\
            <span d:def="1" class="df">a small device</span></d:entry>
            """)!
        #expect(foreign.prefix == nil)
        let other = foreign.root.firstDescendant { $0.classes.contains("df") }!
        #expect(foreign.dictionaryAttribute("def", of: other) == nil,
                "a `d:def` bound to another namespace was read as Apple's")
    }

    /// **A child rebinding the prefix must not blind an earlier sibling.** One document-wide mutable prefix
    /// meant the last declaration won, so a valid `d:def` before it became invisible.
    @Test func theFirstDeclarationOfApplesNamespaceWins() {
        let tree = EntryTree.parse("""
            <d:entry xmlns:d="\(EntryTree.namespace)" id="e1">\
            <span d:def="1" class="df">first</span>\
            <span xmlns:q="\(EntryTree.namespace)"><span q:def="1" class="df">second</span></span>\
            </d:entry>
            """)!
        #expect(tree.prefix == "d")
        let first = tree.root.firstDescendant { $0.classes.contains("df") }!
        #expect(tree.dictionaryAttribute("def", of: first) == "1",
                "the earlier sibling's attribute was lost to a later rebinding")
    }

    /// **A declared entity means the text will arrive incomplete, so the record is refused.** macOS's parser
    /// reports the declaration, does not expand the reference, and reports no error: `a&x;b` becomes `ab`.
    /// A definition quietly missing a word still hashes to a key.
    @Test func aDocumentDeclaringAnEntityIsRefused() {
        #expect(EntryTree.parse("<!DOCTYPE df [<!ENTITY x \"middle\">]><df>a&x;b</df>") == nil)
        // The built-in entities are not declarations and are expanded by the parser itself.
        #expect(EntryTree.parse("<df>a &amp; b</df>")?.root.text == "a & b")
    }

    /// **Only the outermost match.** The flat reader kept one `senseDepth` variable, so a sense block
    /// nested inside a matching sense block overwrote the outer one's context and closing the inner cleared
    /// it. The outer block owns its whole subtree here.
    @Test func maximalDescendantsIgnoresANestedMatch() {
        let tree = EntryTree.parse("""
            <d:entry id="e1"><span class="x_xd1" id="outer">\
            <span class="x_xd1" id="inner">nested</span></span>\
            <span class="x_xd1" id="sibling">beside</span></d:entry>
            """)!
        let found = tree.root.maximalDescendants { $0.classes.contains("x_xd1") }
        #expect(found.map { $0.attributes["id"] } == ["outer", "sibling"])
        // And every match, when that is what a caller wants.
        let all = tree.root.allDescendants { $0.classes.contains("x_xd1") }
        #expect(all.map { $0.attributes["id"] } == ["outer", "inner", "sibling"])
    }

    /// The headword block holds the headword *and* its pronunciation, syllabification and homograph label.
    /// Skipping those subtrees is what gives a form a reader could type.
    @Test func textCanSkipASubtreeByClass() {
        let tree = EntryTree.parse("""
            <span class="hg x_xh0"><span class="hw">abject<span class="gp ty_hom"> 1 </span></span>\
            <span class="syl_txt">ab·ject</span>\
            <span class="prx"> | ˈabˌjek(t) | </span></span>
            """)!
        #expect(tree.root.text == "abject 1 ab·ject | ˈabˌjek(t) | ")
        #expect(tree.root.text(excluding: { $0.classes.contains(where: ["gp", "syl_txt", "prx"].contains) })
                == "abject")
    }

    /// `class` is a space-separated list and is matched as whole tokens. `tg_df` is guide punctuation, not
    /// a definition; substring matching reads it as one.
    @Test func classesAreWholeTokens() {
        let tree = EntryTree.parse("<span class=\"gp tg_df x_xd1sub\">: </span>")!
        #expect(tree.root.classes == ["gp", "tg_df", "x_xd1sub"])
        #expect(!tree.root.classes.contains("df"))
        #expect(!tree.root.classes.contains("x_xd1"))
    }

    /// A record that is not well-formed yields nil rather than a partial tree. Nothing downstream should
    /// have to guess whether what it holds is complete.
    @Test func anUnclosedElementYieldsNoTree() {
        #expect(EntryTree.parse("<d:entry id=\"e1\"><span class=\"df\">unclosed") == nil)
        #expect(EntryTree.parse("") == nil)
    }

    /// Children are the elements only; the text between them is not one of them, and is not lost either.
    @Test func childrenAreElementsAndTextIsStillThere() {
        let tree = EntryTree.parse("<df>a<b>B</b>c<i>D</i>e</df>")!
        #expect(tree.root.children.map(\.name) == ["b", "i"])
        #expect(tree.root.text == "aBcDe")
        #expect(tree.root.content.count == 5)
    }
}
