import Foundation

/// One element of an entry's markup, with its text and its child elements **in document order**.
///
/// **Ordered inline content, not `text` plus `children`.** A definition's text feeds the sense's hash, so
/// losing the interleaving changes identities: `<df>turn <b>off</b> now</df>` and
/// `<df>turn now<b>off</b></df>` would collapse to the same string, and they are not the same definition.
/// That is why `content` is one ordered array of alternatives rather than two fields.
///
/// **Why a tree at all.** The flat reader carried eight depth variables against one shared text buffer, and
/// three recorded defects came out of that shape rather than out of any single line: a nested
/// part-of-speech capture could reset text belonging to an open outer region, a nested matching sense block
/// overwrote the outer block's id, and CDATA was dropped because `foundCharacters` was implemented and
/// `foundCDATA` was not. Building the tree first and asking questions of it second retires all three by
/// construction — there is no shared buffer to clobber and no depth variable to overwrite.
public struct EntryNode: Sendable, Equatable {
    /// Text or a child element. The order of this array *is* the document order.
    public enum Content: Sendable, Equatable {
        case text(String)
        case element(EntryNode)
    }

    /// The element's qualified name as written, `span` or `d:entry`.
    public let name: String
    public let attributes: [String: String]
    /// `class` split into whole tokens, kept rather than recomputed: every predicate in this module asks
    /// for it and `class` is a space-separated list that must never be substring-matched.
    public let classes: [String]
    public let content: [Content]

    public init(name: String, attributes: [String: String], content: [Content]) {
        self.name = name
        self.attributes = attributes
        self.classes = (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        self.content = content
    }

    /// The child elements, in document order, with the text between them dropped.
    public var children: [EntryNode] {
        content.compactMap { if case .element(let node) = $0 { return node } else { return nil } }
    }

    /// Every character of text under this node, in document order.
    public var text: String {
        var out = ""
        appendText(to: &out, excluding: { _ in false }, isRoot: true)
        return out
    }

    /// The text under this node, leaving out any subtree `excluding` claims.
    ///
    /// **A closure rather than a set of class names, because not every exclusion is a class.** A clean
    /// headword has to drop `class="prx"` *and* the `<rt>` element ruby annotation is written in — DrEye
    /// puts Bopomofo inside unclassed `<rt>`, so entry `z_id000002`, whose headword is `一一`, came out as
    /// `一ㄧ一ㄧ` while a class-only filter reported success. A definition's text has to stop at a nested
    /// sub-entry for a different reason: absorbing it makes the parent count a definition the sub-entry also
    /// emits, which pushed retention above the 1.0 it is supposed to be bounded by.
    /// **The receiver's own text is never excluded — only subtrees inside it.** Applying the predicate to
    /// the receiver too silently emptied a region that satisfied it: a definition marked directly on a
    /// sub-entry node, `<span class="x_xo1 df">…`, was asked for its text with "stop at a sub-entry" as the
    /// rule, matched itself, and returned nothing at all. "Exclude these subtrees within me" is the only
    /// reading a caller ever wants; the other one has no use and one silent failure.
    public func text(excluding: (EntryNode) -> Bool) -> String {
        var out = ""
        appendText(to: &out, excluding: excluding, isRoot: true)
        return out
    }

    private func appendText(to out: inout String, excluding: (EntryNode) -> Bool, isRoot: Bool) {
        guard isRoot || !excluding(self) else { return }
        for item in content {
            switch item {
            case .text(let s): out += s
            case .element(let node): node.appendText(to: &out, excluding: excluding, isRoot: false)
            }
        }
    }

    /// The first node in document order, this one included, satisfying `matches`.
    public func firstDescendant(where matches: (EntryNode) -> Bool) -> EntryNode? {
        if matches(self) { return self }
        for child in children {
            if let hit = child.firstDescendant(where: matches) { return hit }
        }
        return nil
    }

    /// Every **maximal** node satisfying `matches` — one nested inside another match is not returned
    /// separately.
    ///
    /// Maximal rather than every match, and that is the fix for a recorded defect: the flat reader kept one
    /// `senseDepth` variable, so a sense block nested inside a matching sense block overwrote the outer
    /// one's context and closing the inner cleared it. Here the outer block owns its whole subtree.
    public func maximalDescendants(where matches: (EntryNode) -> Bool) -> [EntryNode] {
        maximalDescendants(where: matches, stoppingAt: { _ in false })
    }

    /// Every node satisfying `matches`, nested matches included, in document order.
    ///
    /// Collected into one buffer rather than concatenating an array per level: the array-per-level form
    /// copied roughly n²/2 nodes on a chain of n matches.
    public func allDescendants(where matches: (EntryNode) -> Bool) -> [EntryNode] {
        var out: [EntryNode] = []
        collect(into: &out, where: matches)
        return out
    }

    private func collect(into out: inout [EntryNode], where matches: (EntryNode) -> Bool) {
        if matches(self) { out.append(self) }
        for child in children { child.collect(into: &out, where: matches) }
    }

    /// Every **maximal** node satisfying `matches`, with the search stopping at any subtree `boundary`
    /// claims — so a region nested inside another region's does not leak into it.
    ///
    /// **One traversal for every ownership question, because having several was the defect.** Definitions
    /// stopped at a sub-entry while the part-of-speech, sense-number and subsense searches did not, so a
    /// sub-entry's label reached its parent sense: in installed 现代汉语规范词典 entry `0000215` the `形`
    /// belonging to sub-entry `嚣嚣` became the main sense's part of speech, and a sub-entry numbered `9`
    /// gave its parent that sense number — changing the parent's content key when a *sibling* was renumbered.
    public func maximalDescendants(where matches: (EntryNode) -> Bool,
                                   stoppingAt boundary: (EntryNode) -> Bool) -> [EntryNode] {
        var out: [EntryNode] = []
        collectMaximal(into: &out, where: matches, boundary: boundary, isRoot: true)
        return out
    }

    private func collectMaximal(into out: inout [EntryNode], where matches: (EntryNode) -> Bool,
                                boundary: (EntryNode) -> Bool, isRoot: Bool) {
        if !isRoot, boundary(self) { return }
        if matches(self) { out.append(self); return }
        for child in children {
            child.collectMaximal(into: &out, where: matches, boundary: boundary, isRoot: false)
        }
    }

    /// Every **maximal** node satisfying `matches` that is strictly *inside* this one — the receiver is
    /// never returned, however well it matches.
    ///
    /// **A separate operation because the ambiguity caused the same defect twice.** `maximalDescendants`
    /// matches the receiver first, which is right when asking "what definition regions does this region
    /// own" — a sub-entry marked `class="x_xo1 df"` is its own definition. It is wrong every time the
    /// question is "what is nested inside this", and asking it that way once made the declared-definition
    /// count recurse forever on that very node, and once made a nested-sub-entry search return the node it
    /// started from and quietly do nothing.
    public func maximalNestedDescendants(where matches: (EntryNode) -> Bool,
                                         stoppingAt boundary: (EntryNode) -> Bool = { _ in false })
        -> [EntryNode] {
        var out: [EntryNode] = []
        for child in children {
            child.collectMaximal(into: &out, where: matches, boundary: boundary, isRoot: false)
        }
        return out
    }

    /// The first node in document order satisfying `matches`, with the search stopping at any subtree
    /// `boundary` claims.
    public func firstDescendant(where matches: (EntryNode) -> Bool,
                               stoppingAt boundary: (EntryNode) -> Bool) -> EntryNode? {
        firstDescendant(where: matches, boundary: boundary, isRoot: true)
    }

    private func firstDescendant(where matches: (EntryNode) -> Bool,
                                 boundary: (EntryNode) -> Bool, isRoot: Bool) -> EntryNode? {
        if !isRoot, boundary(self) { return nil }
        if matches(self) { return self }
        for child in children {
            if let hit = child.firstDescendant(where: matches, boundary: boundary, isRoot: false) {
                return hit
            }
        }
        return nil
    }
}

/// Parses one entry's XHTML into an `EntryNode` tree.
///
/// **The namespace prefix is resolved, not assumed.** The flat reader matched a literal `d:` while its own
/// docstring claimed otherwise. Apple's documents bind the prefix in an `xmlns:` declaration, so the
/// binding is read off the document and any prefix works — a document writing `dict:def` is handled by the
/// same code as one writing `d:def`.
public struct EntryTree: Sendable {
    /// Apple's dictionary namespace, as its own entries declare it.
    public static let namespace = "http://www.apple.com/DTDs/DictionaryService-1.0.rng"

    public let root: EntryNode
    /// The prefix this document bound to `namespace`, without its colon. `d` in every asset measured.
    ///
    /// **`nil` means no declaration named Apple's namespace.** Distinguishing that from "declared as `d`"
    /// is what stops `xmlns:d="urn:something-else"` being read as Apple's: with a default of `d` a document
    /// that explicitly binds `d` elsewhere had its `d:def` attributes accepted anyway.
    public let prefix: String?
    /// Prefixes this document bound to some *other* namespace. A `d:def` under one of these is not Apple's.
    let foreignPrefixes: Set<String>
    /// Whether the document bound its **default** namespace to something that is not Apple's.
    ///
    /// An unprefixed `<entry>` is accepted as Apple's, because records that declare no namespace at all are
    /// read. `<entry xmlns="urn:unrelated" id="wrong">` is a different element entirely, and accepting it let
    /// a foreign wrapper take the identity of a genuine entry nested inside it.
    let hasForeignDefaultNamespace: Bool

    /// The attribute value for one of Apple's own attributes on a node — `def`, `pos`, `prn`, `syl`.
    ///
    /// Checks the prefix this document actually declared for Apple's namespace, then the bare local name.
    /// Never a substring: `d:def` as an *element* name carries no attributes and must not be mistaken for
    /// one.
    ///
    /// **The bare `d:` fallback applies only when nothing claimed that prefix.** Every asset measured
    /// declares the namespace, but a record that omits the declaration is still read — while one that binds
    /// `d` to something else is not.
    public func dictionaryAttribute(_ local: String, of node: EntryNode) -> String? {
        let prefix = applePrefix
        if prefix.isEmpty { return node.attributes[local] }
        return node.attributes["\(prefix):\(local)"] ?? node.attributes[local]
    }

    /// The prefix Apple's own documents use. Only a fallback: `prefix` is what a document declared.
    static let conventionalPrefix = "d"

    /// The prefix that means Apple's namespace in **this** document — declared, or the conventional `d`
    /// when nothing claimed it. Empty when `d` is explicitly bound elsewhere, so nothing matches it.
    ///
    /// One accessor, because a caller re-deriving `prefix ?? "d"` loses the "bound to something else" case
    /// and reads a foreign vocabulary's `d:entry` as Apple's.
    public var applePrefix: String {
        if let prefix { return prefix }
        return foreignPrefixes.contains(Self.conventionalPrefix) ? "" : Self.conventionalPrefix
    }

    /// The tree, or nil when the record is not well-formed XML.
    public static func parse(_ xhtml: String) -> EntryTree? {
        let builder = Builder()
        let parser = XMLParser(data: Data(xhtml.utf8))
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.finished else { return nil }
        // **A document declaring an entity is refused rather than read short.** Measured against macOS's
        // own parser: `<!DOCTYPE df [<!ENTITY x "middle">]><df>a&x;b</df>` parses *successfully* and yields
        // `ab` — the entity's text simply gone. A definition quietly missing a word still hashes to a key,
        // so this is the shape of silent loss that gets persisted and never noticed.
        guard !builder.sawUnexpandedEntity else { return nil }
        return EntryTree(root: root, prefix: builder.appleNamespacePrefix,
                         foreignPrefixes: builder.foreignPrefixes,
                         hasForeignDefaultNamespace: builder.hasForeignDefaultNamespace)
    }

    // MARK: -

    /// Builds the tree. Holds a stack of partially-built nodes, so there is no shared text buffer and
    /// nothing to reset: text lands in whichever node is open, which is the only node it could belong to.
    final class Builder: NSObject, XMLParserDelegate {
        private struct Open {
            let name: String
            let attributes: [String: String]
            var content: [EntryNode.Content] = []
        }

        private var stack: [Open] = []
        var finished: EntryNode?
        /// The prefix this document bound to Apple's namespace, or nil if no declaration named it.
        var appleNamespacePrefix: String?
        /// Prefixes bound to anything else, so a `d:` that belongs to another vocabulary is not read as
        /// Apple's.
        var foreignPrefixes: Set<String> = []
        var hasForeignDefaultNamespace = false
        /// An entity reference the parser could not expand. See `parse(_:)`.
        var sawUnexpandedEntity = false

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            // The prefix bound to Apple's namespace, read from the declaration rather than assumed. **The
            // first declaration wins**: a child rebinding the prefix used to overwrite it document-wide, so
            // an earlier sibling's valid `d:def` became invisible.
            if let declared = attributes["xmlns"], declared != EntryTree.namespace, !declared.isEmpty {
                hasForeignDefaultNamespace = true
            }
            for (name, value) in attributes where name.hasPrefix("xmlns:") {
                let bound = String(name.dropFirst("xmlns:".count))
                if value == EntryTree.namespace {
                    if appleNamespacePrefix == nil { appleNamespacePrefix = bound }
                } else {
                    foreignPrefixes.insert(bound)
                }
            }
            stack.append(Open(name: element, attributes: attributes))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            append(.text(string))
        }

        /// **CDATA is text.** `foundCharacters` was implemented and this was not, so a definition written
        /// as CDATA read empty — a silent loss, because an empty definition is simply not appended.
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
            append(.text(text))
        }

        /// Whitespace the parser classes as ignorable is still a character of a definition, so it is kept.
        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
            append(.text(whitespaceString))
        }

        /// **An internal entity declaration means the text will arrive incomplete.** macOS's parser reports
        /// the declaration here, does not expand the reference, and reports no error — so the only way to
        /// avoid persisting a definition with a word missing is to refuse the record.
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String,
                    value: String?) {
            sawUnexpandedEntity = true
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            sawUnexpandedEntity = true
        }

        /// An unresolvable entity is a refusal for the same reason.
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String,
                    systemID: String?) -> Data? {
            sawUnexpandedEntity = true
            return nil
        }

        private func append(_ item: EntryNode.Content) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].content.append(item)
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            guard let open = stack.popLast() else { return }
            let node = EntryNode(name: open.name, attributes: open.attributes, content: open.content)
            if stack.isEmpty {
                // The outermost element closing is the document's root. A record holding several roots is
                // not well-formed and `XMLParser` refuses it before reaching here.
                finished = node
            } else {
                stack[stack.count - 1].content.append(.element(node))
            }
        }
    }
}
