import Foundation

/// What can be read out of the document a dictionary returns for one record — the styled form the
/// service sends.
///
/// Apple's nine dictionaries share a structural layer; the class names on top of it are per
/// dictionary, and Apple itself ships one XPath per dictionary rather than a universal extractor
/// (`dev-docs/dictionary-markup.md` §3–§4). Only the structural layer is read here — `x_xh0` the
/// headword block, `x_xd0` a part-of-speech block, `x_xd1` one sense, and the `d:` attributes — so
/// nothing depends on `df`, `trans`, `semb` or `se2`. Everything it cannot find is nil, not guessed.
public struct EntryDocument: Sendable, Equatable, Codable, SenseStructured {
    /// Apple's dictionary namespace. Every installed dictionary's entries declare it — Apple's nine
    /// and the six sideloaded conversions alike — but the prefix bound to it is the document's
    /// business, so it is resolved rather than assumed to be `d`.
    public static let namespace = "http://www.apple.com/DTDs/DictionaryService-1.0.rng"
    public static let xhtmlNamespace = "http://www.w3.org/1999/xhtml"

    /// Whether the document is what the styled form promises: a root of `html` in the XHTML
    /// namespace — the panel parses entries as XML, and a root outside that namespace is not HTML,
    /// so `style` shows as text and nothing is laid out — with the dictionary's stylesheet inlined
    /// as at least one whole rule, a selector and a `property: value` block.
    public let isStyled: Bool
    /// `d:entry`'s `id`: the entry's identity, and the homograph distinction that separates *fine*
    /// the penalty from *fine* the adjective (`dev-docs/study-unit.md` §1). Measured present and
    /// unique across 100% of 1,406,503 entries in all 15 installed dictionaries — nil, never an
    /// empty string passed off as an id, when a document does not declare one.
    public let entryID: String?
    /// The headword block's homograph marker — NOAD's *fine¹ fine² fine³ fine⁴* — which is what
    /// lets the panel tell four entries sharing a headword apart. Nil where a dictionary does not
    /// number its homographs: 牛津英汉汉英 files each as its own record instead, and an entry
    /// without a marker is not given a made-up ordinal.
    public let homograph: String?
    /// One per part-of-speech block, in document order. Empty when the dictionary has no sense
    /// structure at all — the sideloaded conversions whose sense boundary is a colour change.
    public let blocks: [SenseBlock]
    /// The pronunciations the entry prints (`d:prn`), in document order.
    public let pronunciations: [String]

    // `senses`, `senseCount` and `senseKeyKind` come from `SenseStructured`, which is the one place
    // they are written.

    public init(
        isStyled: Bool, entryID: String?, homograph: String?,
        blocks: [SenseBlock] = [], pronunciations: [String] = []
    ) {
        self.isStyled = isStyled
        self.entryID = entryID
        self.homograph = homograph
        self.blocks = blocks
        self.pronunciations = pronunciations
    }

    /// Nil when `xhtml` is not well-formed XML at all. The dictionaries' documents all are —
    /// 1,406,503 of 1,406,503 measured — so a nil here is a changed API or a damaged document,
    /// not a document to guess at.
    public static func parse(_ xhtml: String) -> EntryDocument? {
        let parser = XMLParser(data: Data(xhtml.utf8))
        // Off: with namespace processing on, `d:def` and a plain `def` arrive under the same key,
        // and which namespace an attribute came from is lost. The prefixes are tracked here instead.
        parser.shouldProcessNamespaces = false
        let reader = EntryReader()
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return EntryDocument(
            isStyled: reader.isStyled, entryID: reader.entryID, homograph: reader.homograph,
            blocks: reader.blocks, pronunciations: reader.pronunciations)
    }
}

/// Walks an entry's document once, collecting everything `EntryDocument` reports.
///
/// One walk, because walking a 625 KB entry costs a quarter of a second — measured on Longman's
/// *hold* — against a lookup budget of one second.
///
/// Namespaces are resolved here rather than by `XMLParser`: prefix bindings are pushed and popped
/// with the element scopes that declare them, so an element is identified by its namespace and
/// local name, never by a prefix spelled a particular way.
final class EntryReader: NSObject, XMLParserDelegate {
    private(set) var entryID: String?
    private(set) var homograph: String?
    private(set) var blocks: [SenseBlock] = []
    private(set) var pronunciations: [String] = []
    private var rootIsXHTML = false
    /// The id is the *first* entry's, whether or not that entry declared one — so a document with
    /// two records cannot silently answer with the second one's identity.
    private var sawEntry = false
    /// The depth the first `d:entry` opened at, and whether the walk is still inside it. The id was
    /// always the first entry's; without this the *senses* were not, so a document holding two
    /// entries reported entry A's id with A's and B's senses together — A credited with B's
    /// meanings. Found by audit.
    private var entryDepth: Int?

    /// Whether structure found here belongs to the entry being read. Outside any `d:entry` — a
    /// document that declares none — everything counts, which is what the sideloaded conversions
    /// need.
    ///
    /// **This is the whole of the second-entry protection.** Closing the first `d:entry` clears
    /// `entryDepth` and leaves `sawEntry` set, so everything after it — a second entry included —
    /// answers false here and is collected by nothing.
    private var isCollecting: Bool {
        guard sawEntry else { return true }
        return entryDepth != nil
    }
    private var sawRoot = false

    /// The text of every XHTML `style` element.
    private var stylesheet = ""
    private var styleDepth = 0

    var isStyled: Bool {
        guard rootIsXHTML else { return false }
        // Comments first: a rule inside one is not a rule.
        let rules = stylesheet.replacingOccurrences(of: #"/\*[\s\S]*?(\*/|$)"#, with: " ", options: .regularExpression)
        return rules.range(of: #"[^{}\s][^{}]*\{[^{}]*[\w-]\s*:[^{}]*\S[^{}]*\}"#, options: .regularExpression) != nil
    }

    // MARK: - What the walk is inside of

    /// A region of the document whose text is being collected. Several are open at once — a `d:def`
    /// sits inside an `x_xd1` sits inside an `x_xd0` — so characters are appended to every open one.
    private enum Region {
        /// A part-of-speech block: `x_xd0`.
        case block
        /// One sense: `x_xd1`, and never `x_xd1sub`.
        case sense(key: String?)
        /// The element carrying `d:def`, `d:pos` or `d:prn`.
        case definition
        case partOfSpeech
        case pronunciation
        /// The headword block, `x_xh0`, whose homograph marker labels the entry.
        case headword
    }

    private struct Open {
        let depth: Int
        let region: Region
        var text = ""
    }

    private var open: [Open] = []
    private var depth = 0

    /// The block being filled, if any. One slot: the dictionaries do not nest part-of-speech blocks.
    private var pendingBlock: (number: Int, partOfSpeech: String?, senses: [DictionarySense])?
    /// A sense's own `d:def` closes before the sense does, so it is held here — keyed by the sense's
    /// depth — until there is a sense to hang it on.
    private var definitions: [Int: String] = [:]

    private var isInsideHeadword: Bool {
        open.contains { open in
            if case .headword = open.region { return true }
            return false
        }
    }

    /// The depth of the innermost open sense, if the walk is inside one.
    private var innermostSenseDepth: Int? {
        for open in open.reversed() {
            if case .sense = open.region { return open.depth }
        }
        return nil
    }

    // MARK: - Names

    /// One frame per open element: the prefixes it declared, so they can be popped with it.
    /// The outermost frame binds the prefixes XML defines itself.
    private var scopes: [[String: String]] = [["xml": "http://www.w3.org/XML/1998/namespace"]]

    /// A qualified name split into its prefix and local part. `nil` prefix is the default namespace
    /// for an element, and no namespace at all for an attribute — which is what XML says, and why
    /// an unprefixed `id` never collides with a `d:`-prefixed one.
    static func split(_ qualified: String) -> (prefix: String?, local: String) {
        guard let colon = qualified.firstIndex(of: ":") else { return (nil, qualified) }
        return (String(qualified[..<colon]), String(qualified[qualified.index(after: colon)...]))
    }

    private func namespace(forPrefix prefix: String?) -> String? {
        let key = prefix ?? ""
        for scope in scopes.reversed() { if let uri = scope[key] { return uri } }
        return nil
    }

    /// The element's namespace and local name, with the prefix resolved through the open scopes.
    private func resolve(_ qualified: String) -> (namespace: String?, local: String) {
        let (prefix, local) = Self.split(qualified)
        return (namespace(forPrefix: prefix), local)
    }

    /// An attribute in Apple's dictionary namespace, by local name — `d:def` however it is prefixed.
    private func hasDictionaryAttribute(_ local: String, _ attributes: [String: String]) -> Bool {
        for name in attributes.keys {
            let (prefix, attributeLocal) = Self.split(name)
            guard attributeLocal == local, let prefix, namespace(forPrefix: prefix) == EntryDocument.namespace
            else { continue }
            return true
        }
        return false
    }

    /// Whether `class` lists `token` — as a whole token, not as a substring. The distinction is
    /// load-bearing: `x_xd1sub` contains `x_xd1`, and a subsense is not a sense.
    static func hasClass(_ token: String, _ attributes: [String: String]) -> Bool {
        attributes["class"]?.split(whereSeparator: \.isWhitespace).contains(Substring(token)) ?? false
    }

    /// The publisher's sense id, however this dictionary spells it: `id` in NOAD and the Writer's
    /// Thesaurus, `lexid` in 牛津英汉汉英. Both are the publisher's own, and both survive into the
    /// lookup path unchanged.
    private static func publisherKey(_ attributes: [String: String]) -> String? {
        for name in ["lexid", "id"] {
            guard let value = attributes[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }

    // MARK: - Walking

    func parser(
        _ parser: XMLParser, didStartElement qualified: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        var declared: [String: String] = [:]
        for (name, value) in attributes {
            let (prefix, local) = Self.split(name)
            if prefix == nil, local == "xmlns" { declared[""] = value }
            if prefix == "xmlns" { declared[local] = value }
        }
        scopes.append(declared)
        depth += 1

        let element = resolve(qualified)
        if !sawRoot {
            sawRoot = true
            rootIsXHTML = element.local == "html" && element.namespace == EntryDocument.xhtmlNamespace
        }
        if element.local == "style", element.namespace == EntryDocument.xhtmlNamespace { styleDepth += 1 }
        // An explicit break is a word boundary. Without this, `first<br/>second` collapsed to
        // "firstsecond" — corrupting the definition the reader reads, the text the selector
        // compares against, and the hash that is supposed to notice a content update. Found by
        // audit.
        if Self.breaksWord(element.local, element.namespace) { appendToOpenRegions(" ") }

        if !sawEntry, element.local == "entry", element.namespace == EntryDocument.namespace {
            sawEntry = true
            entryDepth = depth
            let id = attributes["id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank id is an absent one: "unknown" is the honest reading, and an empty string
            // would key a ledger row to nothing.
            entryID = (id?.isEmpty == false) ? id : nil
        }

        guard isCollecting else { return }

        if Self.hasClass("x_xh0", attributes) { open.append(Open(depth: depth, region: .headword)) }
        // The homograph marker is read only inside the headword block: the same attribute on a
        // cross-reference elsewhere in the entry points at another word entirely.
        if isInsideHeadword, homograph == nil, let marker = attributes["homograph"], !marker.isEmpty {
            homograph = marker
        }

        if Self.hasClass("x_xd0", attributes) {
            finishBlock()
            pendingBlock = (blocks.count + 1, nil, [])
            open.append(Open(depth: depth, region: .block))
        }
        // `x_xd1sub` is a subsense: part of the sense it hangs under, never one of its own. Apple's
        // own XPath makes the same exclusion, and token matching is what tells the two apart.
        if Self.hasClass("x_xd1", attributes) {
            open.append(Open(depth: depth, region: .sense(key: Self.publisherKey(attributes))))
        }
        if hasDictionaryAttribute("def", attributes) { open.append(Open(depth: depth, region: .definition)) }
        if hasDictionaryAttribute("pos", attributes) { open.append(Open(depth: depth, region: .partOfSpeech)) }
        if hasDictionaryAttribute("prn", attributes) { open.append(Open(depth: depth, region: .pronunciation)) }
    }

    func parser(_ parser: XMLParser, didEndElement qualified: String, namespaceURI: String?, qualifiedName: String?) {
        let element = resolve(qualified)
        if element.local == "style", element.namespace == EntryDocument.xhtmlNamespace { styleDepth -= 1 }
        // Leaving the first entry: nothing after it belongs to it.
        if let entryDepth, entryDepth == depth { self.entryDepth = nil; finishBlock() }
        // The closing tag is a word boundary too. Opening alone left `<p>first</p>second` joined
        // as "firstsecond" — the same defect one tag later. Found by the verify pass.
        if Self.breaksWord(element.local, element.namespace) { appendToOpenRegions(" ") }

        // Innermost first: several regions can have opened on this one element.
        while let last = open.last, last.depth == depth {
            open.removeLast()
            close(last)
        }

        depth -= 1
        if scopes.count > 1 { scopes.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if styleDepth > 0 { stylesheet += string }
        appendToOpenRegions(string)
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        let text = String(decoding: block, as: UTF8.self)
        if styleDepth > 0 { stylesheet += text }
        appendToOpenRegions(text)
    }

    private func appendToOpenRegions(_ text: String) {
        for index in open.indices { open[index].text += text }
    }

    /// XHTML elements that separate words even with no whitespace around them, opening *and*
    /// closing. Collapsing runs a separator down to nothing, so one can only ever prevent a join.
    ///
    /// Measured across 90 entries from all seven installed dictionaries: **not one of these
    /// elements occurs at all** — the dictionaries are spans throughout — and none carries an
    /// inline `display` style. So neither the join this prevents nor the spurious space it could
    /// introduce is reachable today; the set is kept for a sideloaded dictionary that does use
    /// them, where a `<p>` inside a definition is a paragraph and a boundary is the right reading.
    private static let wordBreaking: Set<String> = [
        "br", "p", "div", "li", "tr", "td", "th", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    private static func breaksWord(_ local: String, _ namespace: String?) -> Bool {
        namespace == EntryDocument.xhtmlNamespace && wordBreaking.contains(local)
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        finishBlock()
    }

    // MARK: - Closing a region

    private func close(_ closed: Open) {
        let text = Self.collapsed(closed.text)
        switch closed.region {
        case .headword:
            break
        case .definition:
            // The innermost open sense owns it, and only its first: a `d:def` outside any sense
            // belongs to no sense and is dropped rather than attached to the wrong one.
            guard let sense = innermostSenseDepth, definitions[sense] == nil, !text.isEmpty else { return }
            definitions[sense] = text
        case .partOfSpeech:
            guard pendingBlock != nil, pendingBlock?.partOfSpeech == nil, !text.isEmpty else { return }
            pendingBlock?.partOfSpeech = text
        case .pronunciation:
            if !text.isEmpty { pronunciations.append(text) }
        case .sense(let key):
            finishSense(key: key, definition: definitions.removeValue(forKey: closed.depth), text: text)
        case .block:
            finishBlock()
        }
    }

    private func finishSense(key publisherKey: String?, definition: String?, text: String) {
        // A sense outside any part-of-speech block still belongs somewhere, rather than being lost.
        if pendingBlock == nil { pendingBlock = (blocks.count + 1, nil, []) }
        guard var block = pendingBlock else { return }
        let path = SensePath(block: block.number, ordinal: block.senses.count + 1)
        block.senses.append(DictionarySense(
            path: path,
            // No publisher id is a weaker claim, not an absent one: the sense is addressed by
            // where it sits, and `textHash` is what notices a content update moving it.
            key: publisherKey ?? "\(path.block).\(path.ordinal)",
            keyKind: publisherKey == nil ? .position : .publisher,
            definition: definition, text: text))
        pendingBlock = block
    }

    private func finishBlock() {
        guard let block = pendingBlock else { return }
        pendingBlock = nil
        // A block with no senses is layout, not structure, and there is nothing in it to key.
        guard !block.senses.isEmpty else { return }
        blocks.append(SenseBlock(number: block.number, partOfSpeech: block.partOfSpeech, senses: block.senses))
    }

    /// Markup whitespace is layout, not content: a definition read with its newlines and
    /// indentation still in it would hash differently every time the dictionary is reflowed.
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
