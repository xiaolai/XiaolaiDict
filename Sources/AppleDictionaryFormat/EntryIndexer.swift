import Foundation

/// One entry, reduced to what an index needs.
public struct IndexedEntry: Sendable, Equatable {
    public let entryID: String
    public let headword: String
    /// Apple's homograph marker, where the dictionary numbers them. `fine` the penalty and `fine` the
    /// adjective are different entries and must not merge.
    public let homograph: String?
    public let senses: [IndexedSense]
    /// Indices into `senses` whose content key needed an ordinal, because another sense of this entry had
    /// both the same definition and the same declared position.
    ///
    /// **Carried so the one order-dependent case in the keying scheme is visible.** Everything else about
    /// a content key is a function of the sense alone; these are the senses for which that is not true,
    /// and `DictionaryFacts.sensesNeedingOrdinals` counts them per dictionary so the residue can be
    /// watched rather than assumed small.
    public let sensesNeedingOrdinals: [Int]
    /// How many **subsenses** needed one, counted rather than indexed because they are addressed through
    /// their sense rather than by position in `senses`.
    public let subsensesNeedingOrdinals: Int

    /// Every sense or subsense of this entry that needed the ordinal fallback.
    public var ordinalsNeeded: Int { sensesNeedingOrdinals.count + subsensesNeedingOrdinals }

    /// Definition-marked elements this entry declares, and how many reached a sense.
    ///
    /// **The retention metric, counted by the parser instead of searched for in the text.** Both earlier
    /// versions were wrong in ways that read as success: counting the substring `d:def` gave every
    /// dictionary in the catalogue exactly 33.3%, and counting `d:def=` gave NOAD a clean 100% while a
    /// quarter of its definitions were in neither numerator nor denominator. `declared` counts maximal
    /// definition regions, so `captured ≤ declared` holds and the ratio cannot exceed 1 — which the old
    /// "split the joined text on `; `" count could, and did.
    public let declaredDefinitions: Int
    public let capturedDefinitions: Int

    /// Identifiers this entry shares with **another dictionary from the same publisher**.
    ///
    /// **The exact cross-dictionary join, found by measurement rather than assumed to be absent.** Oxford
    /// stamps a pronunciation with its own `prlexid` — `optra0016615.002` — and the *same* value appears in
    /// NOAD and in 牛津英汉汉英: 8,648 shared across the first 25,000 entries of each. Because a pronunciation
    /// belongs to one headword and one homograph, that pins `fine` the noun to `fine` the noun across two
    /// dictionaries **exactly**, where matching on the headword string cannot separate homographs at all.
    ///
    /// Not universal, and the absence matters as much as the presence: `OAWT`, `ko-en.NewAce` and
    /// `zh_TW-en.DrEye` carry none in 4,000 entries each, so an alignment involving them has to fall back to
    /// the headword. A caller reads `anchors.isEmpty` to know which it is dealing with.
    public let anchors: [String]

    /// Share of the definitions this entry declares that reached a sense. 1.0 when none were declared,
    /// because an entry with no definitions has lost nothing.
    public var definitionsReached: Double {
        declaredDefinitions > 0 ? Double(capturedDefinitions) / Double(declaredDefinitions) : 1
    }

    public init(entryID: String, headword: String, homograph: String?, senses: [IndexedSense],
                sensesNeedingOrdinals: [Int] = [], subsensesNeedingOrdinals: Int = 0,
                declaredDefinitions: Int = 0, capturedDefinitions: Int = 0,
                anchors: [String] = []) {
        self.subsensesNeedingOrdinals = subsensesNeedingOrdinals
        self.anchors = anchors
        self.entryID = entryID
        self.headword = headword
        self.homograph = homograph
        self.senses = senses
        self.sensesNeedingOrdinals = sensesNeedingOrdinals
        self.declaredDefinitions = declaredDefinitions
        self.capturedDefinitions = capturedDefinitions
    }
}

/// One subsense of a numbered sense — `1a` against `1b`.
///
/// **Carried beside the sense rather than instead of it.** A numbered sense holding several `x_xdNsub`
/// blocks is still emitted as one sense whose text is their join, because that is what keeps 譯典通's entry
/// for 一 whole: its single sense block holds "one", "one only", "alone", "once", "undivided",
/// "throughout", and keeping only the first destroyed five of six glosses. What the tree adds is that the
/// parts are now *also* available, so a reader can show "sense 1: a, b" and a schema can store them as
/// child rows under a `parent_key`. Nothing that already existed changes shape.
///
/// Present only where there are **two or more**: a sense with a single subsense has no hierarchy to
/// express, and emitting one would give it a key identical to its parent's.
public struct IndexedSubsense: Sendable, Equatable {
    public let key: SenseKey
    /// The label the dictionary prints against this subsense. NOAD uses a bullet, `•`, not a letter — so
    /// this is whatever the markup says and never a generated `a`/`b`.
    public let label: String?
    public let definition: String

    public init(key: SenseKey, label: String?, definition: String) {
        self.key = key
        self.label = label
        self.definition = definition
    }
}

public struct IndexedSense: Sendable, Equatable {
    /// The name this sense is addressed by: the publisher's id where the dictionary supplies one,
    /// otherwise `contentKey`.
    public let key: SenseKey
    /// The content key for this sense, computed whether or not the publisher supplied an id.
    ///
    /// **Carried rather than recomputed by the caller.** The validity measurement has to compare a
    /// publisher key against the content key for the *same* sense, and every time that pairing was
    /// rebuilt outside the indexer it drifted from what the indexer actually did — four times during this
    /// module's construction, and the indexer was right each time. Exposing it removes the second
    /// implementation instead of documenting it.
    public let contentKey: SenseKey
    /// Where the markup says this sense sits. The key is derived from this and the definition, so the
    /// two cannot disagree.
    public let position: SensePosition
    public let definition: String
    /// The example phrases printed against this sense, in document order.
    ///
    /// **Extracted because they are the only material two dictionaries of different languages share.**
    /// 牛津英汉汉英 marks its `d:def` on the *translation* — `fine` gives `罚款` — so its definitions and
    /// NOAD's are not in the same language and cannot be compared. Both print English examples against each
    /// sense, and that is what `SenseAligner` matches on. They are worth having on their own account too: an
    /// example is often what tells a reader which sense they are looking at.
    public let examples: [String]
    /// The subsenses this sense holds, where it holds more than one. See `IndexedSubsense`.
    public let subsenses: [IndexedSubsense]

    /// One coordinate of `position`, kept as a named accessor because narrowing candidates by part of
    /// speech is what most callers want it for.
    public var partOfSpeech: String? { position.partOfSpeech }

    public init(key: SenseKey, contentKey: SenseKey, position: SensePosition, definition: String,
                examples: [String] = [], subsenses: [IndexedSubsense] = []) {
        self.examples = examples
        self.key = key
        self.contentKey = contentKey
        self.position = position
        self.definition = definition
        self.subsenses = subsenses
    }
}

/// Turning one entry's XHTML into senses with durable keys.
///
/// **A tree, walked — not a stack of depth variables over a shared buffer.** The previous reader carried
/// eight depth variables against one text buffer, and three recorded defects came out of that shape rather
/// than out of any single line: a nested part-of-speech capture could reset text belonging to an open outer
/// region, a nested matching sense block overwrote the outer block's id, and CDATA was silently dropped
/// because `foundCharacters` was implemented and `foundCDATA` was not. `EntryTree` builds the document
/// first and this asks questions of it, so all three go by construction rather than by a ninth variable.
///
/// Only the structural layer is read — the headword block, the part-of-speech block, the sense blocks at
/// this dictionary's own depth, the sub-entries, and the `d:` attributes. Apple itself ships one XPath per
/// dictionary rather than a universal extractor, and the structural layer is the part that is universal.
///
/// Measured across the 85 readable assets: every entry is well-formed XML, 0 unparsable of 100,872
/// read. `com.apple.dictionary.AppleDictionary` is the 86th and is not a language dictionary.
public struct EntryIndexer {
    public let dictionary: String
    public let profile: DictionaryProfile

    public init(dictionary: String, profile: DictionaryProfile) {
        self.dictionary = dictionary
        self.profile = profile
    }

    public init(bundle: DictionaryBundle) {
        self.init(dictionary: bundle.identifier, profile: bundle.profile)
    }

    /// Why a record did not become an entry.
    ///
    /// **Named rather than collapsed into `nil`, because a rejected record takes its definitions with
    /// it.** NOAD has 27 records with no headword block holding 46 definition-marked elements between
    /// them; counting definitions only from accepted entries put those 46 in neither numerator nor
    /// denominator, so retention read a clean 100.00% while they were unreachable. That is the same shape
    /// as the `d:def=` denominator bug, one layer up, and it was found by an aggregate coming out *exactly*
    /// equal rather than merely close.
    public enum Rejection: String, Sendable, Equatable {
        /// `XMLParser` refused the record. 0 of NOAD's 111,606.
        case notWellFormed
        /// No `d:entry` carrying an `id`, so the entry cannot be named.
        case noEntryID
        /// No headword block, so nothing a reader could have looked up. NOAD: 27 records.
        case noHeadword
    }

    /// What one record yielded, including what it declared when it yielded nothing.
    public struct Outcome: Sendable {
        public let entry: IndexedEntry?
        public let rejection: Rejection?
        /// Definition-marked elements the record declares, **whether or not it became an entry**. A
        /// caller measuring retention must add this for rejected records too, or its denominator shrinks
        /// silently by exactly the definitions it is failing to reach.
        public let declaredDefinitions: Int
        /// `d:index` elements this record carries — its own search keys, inline.
        ///
        /// **Counted from parsed elements, not by searching the text.** A raw search for `d:index` matched a
        /// comment or a definition that happened to contain the string, and missed a `dict:index` bound to
        /// Apple's namespace under another prefix. Whether a dictionary keeps its keys inline decides whether
        /// it can be rebuilt without the key file's pointer arithmetic at all, so a false reading of it sends
        /// a rebuild down the wrong path.
        public let inlineIndexElements: Int

        public init(entry: IndexedEntry?, rejection: Rejection?, declaredDefinitions: Int,
                    inlineIndexElements: Int = 0) {
            self.entry = entry
            self.rejection = rejection
            self.declaredDefinitions = declaredDefinitions
            self.inlineIndexElements = inlineIndexElements
        }
    }

    /// The entry, or nil when it is not one — a malformed record, or a document with no `d:entry`.
    ///
    /// Use `outcome(for:)` where a rejected record must not vanish; this is the convenience for callers
    /// that only want the entry.
    public func index(_ xhtml: String) -> IndexedEntry? { outcome(for: xhtml).entry }

    /// One record, read once, reporting what it yielded and what it declared either way.
    public func outcome(for xhtml: String) -> Outcome {
        guard let tree = EntryTree.parse(xhtml) else {
            return Outcome(entry: nil, rejection: .notWellFormed, declaredDefinitions: 0)
        }
        var walk = Walk(tree: tree, profile: profile)
        let declared = walk.declaredDefinitionCount()
        let inline = walk.inlineIndexCount()

        // **The entry's id is its own field, read from `d:entry` directly.** Reading every identifier
        // through `profile.senseIDAttributes` would lose it wherever a profile declares none — and
        // `zh_TW-en.DrEye` declares none, so all 136,288 of its entries would have become unnamed.
        guard let entryID = walk.entryID(), !entryID.isEmpty else {
            return Outcome(entry: nil, rejection: .noEntryID, declaredDefinitions: declared,
                           inlineIndexElements: inline)
        }
        let headword = walk.headword()
        guard !headword.isEmpty else {
            return Outcome(entry: nil, rejection: .noHeadword, declaredDefinitions: declared,
                           inlineIndexElements: inline)
        }

        walk.collectSenses()
        // **Keys are assigned once, over every sense *and* subsense of the entry.**
        //
        // Not because a key depends on its siblings — it does not, which is the point of `SensePosition` —
        // but because the last-resort ordinal for two identical `(definition, position)` pairs can only be
        // known by seeing all of them. Assigning subsenses per parent could not: an unnumbered sense
        // defining `A` and another sense holding unlabelled subsenses `A` and `B` gave the first sense and
        // the `A` subsense **the same key**, and `IndexStore` writes that key as a primary key with
        // `INSERT OR REPLACE` — so one silently replaced the other and six records became five rows.
        var positioned: [PositionedDefinition] = walk.senses.map(\.positioned)
        // Where each sense's subsenses land in that flat list, so it can be taken apart again.
        var subsenseRanges: [Range<Int>] = []
        for raw in walk.senses {
            let start = positioned.count
            if raw.subsenses.count > 1 {
                positioned += raw.subsenses.map { Self.positioned($0, under: raw) }
            }
            subsenseRanges.append(start ..< positioned.count)
        }
        let assignment = SenseKey.keys(dictionary: dictionary, entry: entryID, senses: positioned)
        let senses = zip(walk.senses.enumerated(), assignment.keys.prefix(walk.senses.count))
            .map { pair, contentKey -> IndexedSense in
                let (index, raw) = pair
                let key: SenseKey
                if profile.expectsPublisherID, let id = raw.publisherID, !id.isEmpty {
                    key = .publisher(dictionary: dictionary, entry: entryID, id: id)
                } else {
                    key = contentKey
                }
                let subsenses = zip(raw.subsenses, assignment.keys[subsenseRanges[index]])
                    .map { IndexedSubsense(key: $1, label: $0.label, definition: $0.definition) }
                return IndexedSense(key: key, contentKey: contentKey, position: raw.position,
                                    definition: raw.definition, examples: raw.examples,
                                    subsenses: subsenses)
            }
        // **Only the indices that are indices into `senses`.** The assignment runs over senses *and*
        // subsenses, so `ordinalled` indexes the flattened array — publishing it unchanged made
        // `sensesNeedingOrdinals` able to name a position past the end of `senses`, which is not what the
        // field says it holds. A subsense that needed an ordinal is reported through
        // `subsensesNeedingOrdinals` instead of being silently renumbered into its parent's space.
        let senseOrdinals = assignment.ordinalled.filter { $0 < senses.count }
        let subsenseOrdinals = assignment.ordinalled.count - senseOrdinals.count
        let entry = IndexedEntry(entryID: entryID, headword: headword,
                                 homograph: walk.homograph(), senses: senses,
                                 sensesNeedingOrdinals: senseOrdinals,
                                 subsensesNeedingOrdinals: subsenseOrdinals,
                                 declaredDefinitions: declared,
                                 capturedDefinitions: walk.capturedDefinitions,
                                 anchors: walk.anchors())
        return Outcome(entry: entry, rejection: nil, declaredDefinitions: declared,
                       inlineIndexElements: inline)
    }

    /// A subsense as the keying scheme sees it: its sense's position, with its own label folded into the
    /// sense number.
    ///
    /// **A fourth coordinate on `SensePosition` was the alternative and was rejected** — adding one would
    /// change the digest input of every positioned sense in every dictionary, a second migration for a
    /// distinction the composed number already draws. The entry-wide assignment in `outcome(for:)` is what
    /// separates two subsenses that compose to the same thing.
    private static func positioned(_ sub: RawSubsense, under raw: RawSense) -> PositionedDefinition {
        PositionedDefinition(
            definition: sub.definition,
            position: SensePosition(
                subEntry: raw.position.subEntry,
                partOfSpeech: raw.position.partOfSpeech,
                senseNumber: [raw.position.senseNumber, sub.label]
                    .compactMap { $0 }.joined(separator: " ")))
    }

    // MARK: -

    struct RawSubsense {
        var label: String?
        var definition: String
    }

    struct RawSense {
        var publisherID: String?
        var position: SensePosition
        var definition: String
        var examples: [String] = []
        var subsenses: [RawSubsense] = []

        var positioned: PositionedDefinition {
            PositionedDefinition(definition: definition, position: position)
        }
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Asks the tree the questions an index needs answered.
///
/// Every question is answered from the tree's own shape, so there is no ordering between them and no
/// state one can leave behind for another — which is the whole reason the reader is no longer a parser
/// delegate.
struct Walk {
    let tree: EntryTree
    let profile: DictionaryProfile
    var senses: [EntryIndexer.RawSense] = []
    var capturedDefinitions = 0

    /// The subtrees whose text is pronunciation, syllabification or a printed label rather than the
    /// headword itself.
    ///
    /// **Measured, not guessed.** Taking all the text under `x_xh0` gave NOAD
    /// `007 | ˌdəbəl ˌō ˈsevənˌdəbəl ˌoʊ ˈsɛvən |` for `007`, 뉴에이스 국어사전 `ㄱㄴㄷ-순 (-順) | -영-쑨 |`
    /// for `ㄱㄴㄷ-순`, and `he.oup` `Tranz.` — a form no reader will ever type, stored as the headword and
    /// then compared against the key index, which is why agreement cannot tell a broken headword from a
    /// broken mapping.
    static let notPartOfAHeadword: Set<String> = ["gp", "prx", "pr", "ph", "syl_txt"]

    /// Ruby annotation, which is pronunciation written *above* a word rather than beside it.
    ///
    /// **An element, not a class, which is exactly why a class-only filter missed it.** 譯典通 writes
    /// Bopomofo inside unclassed `<rt>`, so entry `z_id000002` — headword `一一` — came out as `一ㄧ一ㄧ`,
    /// and the check that no headword contains `|` reported success because ruby carries no delimiter.
    static let rubyAnnotation: Set<String> = ["rt", "rp"]

    /// Whether this subtree's text belongs to a headword or a sub-entry label.
    static func isNotPartOfAName(_ node: EntryNode) -> Bool {
        rubyAnnotation.contains(node.name) || node.classes.contains(where: notPartOfAHeadword.contains)
    }

    /// The `d:entry` element's own `id` — `EntryTree`'s, which is the one owner of the match.
    func entryID() -> String? { tree.entryID() }

    /// A nested sub-entry owns its own subtree, and **every** search inside a sense stops at one. The
    /// definition walk already did; the part-of-speech, sense-number and subsense searches did not — so a
    /// sub-entry's `形` became its parent's part of speech in installed 现代汉语规范词典 entry `0000215`,
    /// and a sub-entry numbered `9` gave its parent that sense number, making the parent's content key
    /// depend on a sibling's numbering.
    func isSubEntry(_ node: EntryNode) -> Bool {
        profile.marksSubEntry(classes: node.classes)
    }

    func isSubsense(_ node: EntryNode) -> Bool {
        node.classes.contains("x_xd\(profile.senseDepth)sub")
    }

    func headwordBlock() -> EntryNode? {
        tree.root.firstDescendant { $0.classes.contains("x_xh0") }
    }

    /// The headword, without its pronunciation.
    ///
    /// Prefers the `hw` span inside the block, because that is where Apple puts the word itself; falls
    /// back to the block. **And falls back again to the unfiltered text if filtering empties it** — a
    /// headword that comes out empty is not a cleaner headword, it is a rejected entry, and rejecting an
    /// entry throws away every definition it held.
    func headword() -> String {
        guard let block = headwordBlock() else { return "" }
        let node = block.firstDescendant { $0.classes.contains("hw") } ?? block
        let filtered = EntryIndexer.collapsed(node.text(excluding: Self.isNotPartOfAName))
        if !filtered.isEmpty { return filtered }
        let whole = EntryIndexer.collapsed(node.text)
        return whole.isEmpty ? EntryIndexer.collapsed(block.text) : whole
    }

    func homograph() -> String? {
        guard let block = headwordBlock() else { return nil }
        return block.firstDescendant { !($0.attributes["homograph"] ?? "").isEmpty }?
            .attributes["homograph"]
    }

    func isDefinition(_ node: EntryNode) -> Bool {
        tree.dictionaryAttribute("def", of: node) != nil
            || profile.marksDefinition(classes: node.classes)
    }

    /// Maximal definition regions anywhere in the record, whether or not a sense encloses them.
    func declaredDefinitionCount() -> Int {
        // **Counted by the same ownership rule the capture uses, or the two sides measure different things.**
        // Plain maximal regions undercounted: a definition element enclosing a sub-entry claimed the whole
        // subtree, so the sub-entry's own definition vanished from the denominator while still being
        // captured — `declared 1, captured 2`, retention 2.0. A definition owns one region; a sub-entry
        // inside it owns its own.
        count(definitionsIn: tree.root)
    }

    /// The publisher's own cross-dictionary identifiers, deduplicated and in document order.
    ///
    /// `prlexid` is the attribute Oxford uses; it is read as a plain attribute because it carries no
    /// namespace prefix in any asset measured.
    func anchors() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for node in tree.root.allDescendants(where: { $0.attributes["prlexid"] != nil }) {
            guard let value = node.attributes["prlexid"], !value.isEmpty,
                  seen.insert(value).inserted else { continue }
            out.append(value)
        }
        return out
    }

    /// `d:index` elements, by element name under the prefix this document bound to Apple's namespace.
    func inlineIndexCount() -> Int {
        let wanted = "\(tree.applePrefix):index"
        return tree.root.allDescendants { $0.name == wanted || $0.name == "index" }.count
    }

    private func count(definitionsIn node: EntryNode) -> Int {
        // **A node can be both, and then it is both.** Testing the sub-entry case first and recursing past
        // the node's own marking meant `<span class="x_xo2 df">meaning</span>` was captured as a definition
        // and counted as none: declared 0, captured 1, retention above the bound.
        if isSubEntry(node), !isDefinition(node) {
            // A sub-entry's definitions are its own, whatever encloses it.
            return node.children.reduce(0) { $0 + count(definitionsIn: $1) }
        }
        if isDefinition(node) {
            return 1 + node.maximalNestedDescendants(where: isSubEntry)
                .reduce(0) { $0 + count(definitionsIn: $1) }
        }
        return node.children.reduce(0) { $0 + count(definitionsIn: $1) }
    }

    mutating func collectSenses() {
        walk(tree.root, partOfSpeech: nil)
    }

    private mutating func walk(_ node: EntryNode, partOfSpeech: String?) {
        // A sub-entry owns its whole subtree: `x_xo2` and `x_xo3` nest inside `x_xo1` and belong to the
        // phrasal verb it opened, not to senses of their own.
        if let depth = profile.subEntryDepth(classes: node.classes) {
            collectSubEntry(node, depth: depth, partOfSpeech: partOfSpeech)
            return
        }
        // Likewise a sense owns its subtree, so a sense nested inside a matching sense belongs to the one
        // above it — which retires the defect where the inner block overwrote the outer block's id and
        // closing the inner cleared the context for both.
        //
        // **But a sub-entry inside a sense is still a sub-entry**, and conflating the two questions cost
        // 现代汉语规范词典 53 sense labels. Measured: `zh_CN.SDCC` nests `x_xo[1-9]` inside `x_xd1` exactly
        // 53 times, and nests `x_xd1` inside `x_xo[1-9]` never. Letting the sense swallow them lost no
        // definition and no sense, so every total held — which is exactly why it would have gone unnoticed;
        // the only number that moved was the sub-entry count, 813 to 760. The label is what scopes an alias,
        // so losing it is what would make `give up` return `give`'s whole candidate set again.
        if profile.marksSense(classes: node.classes) {
            let nested = node.maximalNestedDescendants { profile.marksSubEntry(classes: $0.classes) }
            emit(node, position: SensePosition(partOfSpeech: partOfSpeech,
                                               senseNumber: senseNumber(of: node)),
                 publisherID: publisherID(of: node),
                 subsenseToken: "x_xd\(profile.senseDepth)sub",
                 stoppingAtSubEntries: true)
            for sub in nested { walk(sub, partOfSpeech: partOfSpeech) }
            return
        }
        // **Scoped to its own block.** The previous reader set the part of speech when a `d:pos` element
        // closed and never cleared it, so a block declaring none inherited the previous block's —
        // reporting a verb sense as a noun, silently. Here it is a parameter: a block that declares none
        // passes on what it was given, and one that declares a part of speech replaces it for its own
        // subtree and for nothing else.
        var inherited = partOfSpeech
        if profile.marksPartOfSpeechBlock(classes: node.classes) {
            inherited = partOfSpeechLabel(in: node)
        }
        for child in node.children { walk(child, partOfSpeech: inherited) }
    }

    /// One sub-entry, and **one sense per numbered sense inside it**.
    ///
    /// **A sub-entry is not a sense.** Emitting the whole of it as one merged the phrasal verb's meanings:
    /// installed NOAD entry `m_en_gbus0415220` (`give`) carries five numbered `x_xo2` senses under
    /// `give up`, and `take off` carries six — all of which came back as a single definition with the parts
    /// joined by `; `. That is the same defect the schema's alias scoping exists to fix, one level down:
    /// `give up` became reachable and then answered with one blob instead of five addressable senses.
    ///
    /// A sub-entry with no numbered blocks — the common shape, `msDict x_xo2 t_core` holding the definition
    /// directly — still yields one sense, and definitions sitting outside every numbered block are emitted
    /// alongside them rather than dropped.
    private mutating func collectSubEntry(_ node: EntryNode, depth: Int, partOfSpeech: String?) {
        let label = subEntryLabel(of: node)
        let pos = partOfSpeechLabel(in: node) ?? partOfSpeech
        let senseToken = "x_xo\(depth + 1)"
        let subsenseToken = senseToken + "sub"
        // **The boundary is a sub-entry at *this* level or above, not any `x_xo` at all.** `isSubEntry`
        // matches `x_xo2` — which is precisely the numbered sense block being looked for — so using it here
        // rejected every block as a boundary before it could be matched, and the sub-entry yielded nothing.
        // The profile is captured by value, so the closure does not capture a mutating `self`.
        let profile = self.profile
        let outer: (EntryNode) -> Bool = {
            (profile.subEntryDepth(classes: $0.classes) ?? Int.max) <= depth
        }
        let blocks = node.maximalDescendants(where: { $0.classes.contains(senseToken) },
                                             stoppingAt: outer)
        // The sub-entry's own definitions, outside every numbered block. Usually none.
        let ownTexts = definitionTexts(in: node, stoppingAt: {
            outer($0) || $0.classes.contains(senseToken)
        })
        if !ownTexts.isEmpty {
            capturedDefinitions += ownTexts.count
            senses.append(EntryIndexer.RawSense(publisherID: publisherID(of: node),
                                   position: SensePosition(subEntry: label, partOfSpeech: pos),
                                   definition: ownTexts.joined(separator: "; ")))
        }
        // **A block never borrows its wrapper's id.** Two attempts at this were wrong in opposite
        // directions. Falling back to the sub-entry's id for *every* block gave two id-less `x_xo2` blocks
        // the same publisher key, and `IndexStore` writes that as a primary key with `INSERT OR REPLACE` —
        // one silently replaced the other. Borrowing it only when the sub-entry held a single sense was
        // worse in the way that matters most here: it made the key a function of the **sibling count**, so
        // adding a second block switched the first from a publisher key to a content key, and a definition
        // added on the wrapper handed the original publisher key to that new text. A persisted reference
        // would then name different words.
        //
        // That is precisely the defect `PLAN.md` §0 exists to remove — *a key must be a function of the
        // sense, not of how many siblings it happens to have* — so an id-less block takes its content key,
        // which is a real name and not a missing one.
        let emitted = blocks.filter { !definitionTexts(in: $0, stoppingAt: outer).isEmpty }
        // **A nested sub-entry at this level or shallower is visited, not dropped.** `outer` excludes it
        // from every extraction here, and nothing else was reaching it — so an `x_xo1` inside another
        // `x_xo1` lost its definitions entirely, with no count anywhere showing the loss.
        let nestedSubEntries = node.maximalNestedDescendants { n in
            guard let d = profile.subEntryDepth(classes: n.classes) else { return false }
            return d <= depth
        }
        for nested in nestedSubEntries {
            collectSubEntry(nested, depth: profile.subEntryDepth(classes: nested.classes) ?? depth,
                            partOfSpeech: partOfSpeech)
        }
        for block in emitted {
            let texts = definitionTexts(in: block, stoppingAt: outer)
            capturedDefinitions += texts.count
            var raw = EntryIndexer.RawSense(
                publisherID: publisherID(of: block),
                position: SensePosition(subEntry: label, partOfSpeech: pos,
                                        senseNumber: number(of: block, subsenseToken: subsenseToken)),
                definition: texts.joined(separator: "; "),
                examples: exampleTexts(in: block, stoppingAt: outer))
            raw.subsenses = block
                .maximalNestedDescendants(where: { $0.classes.contains(subsenseToken) },
                                          stoppingAt: outer)
                .compactMap { sub -> EntryIndexer.RawSubsense? in
                    let text = definitionTexts(in: sub, stoppingAt: outer)
                        .joined(separator: "; ")
                    guard !text.isEmpty else { return nil }
                    return EntryIndexer.RawSubsense(label: number(of: sub, subsenseToken: subsenseToken),
                                       definition: text)
                }
            if raw.subsenses.count < 2 { raw.subsenses = [] }
            senses.append(raw)
        }
    }

    private mutating func emit(_ node: EntryNode, position: SensePosition,
                               publisherID: String?, subsenseToken: String?,
                               stoppingAtSubEntries: Bool = false) {
        let texts = definitionTexts(in: node, stoppingAtSubEntries: stoppingAtSubEntries)
        guard !texts.isEmpty else { return }
        capturedDefinitions += texts.count
        let boundary: (EntryNode) -> Bool = stoppingAtSubEntries
            ? { self.isSubEntry($0) } : { _ in false }
        var raw = EntryIndexer.RawSense(publisherID: publisherID, position: position,
                                        definition: texts.joined(separator: "; "),
                                        examples: exampleTexts(in: node, stoppingAt: boundary))
        if let subsenseToken {
            raw.subsenses = node.maximalNestedDescendants(
                where: { $0.classes.contains(subsenseToken) },
                stoppingAt: { self.isSubEntry($0) })
                .compactMap { sub -> EntryIndexer.RawSubsense? in
                    let text = definitionTexts(in: sub, stoppingAtSubEntries: stoppingAtSubEntries)
                        .joined(separator: "; ")
                    guard !text.isEmpty else { return nil }
                    return EntryIndexer.RawSubsense(label: senseNumber(of: sub), definition: text)
                }
        }
        senses.append(raw)
    }

    /// **One sense per block, but all of its text.** A block can hold several definitions and they are not
    /// one kind of thing. In NOAD the extras are cross-references — "American English = rappel". In 譯典通
    /// they are co-equal glosses: entry `z_id000001` (一) has a single sense block holding "one", "one
    /// only", "alone", "once", "undivided", "throughout".
    ///
    /// Emitting one sense per definition gave 1,112 publisher ids two identities each. Keeping only the
    /// first threw away five of 一's six glosses. Joining them keeps the sense singular and its content
    /// whole, which is the only option that is wrong in neither direction — and `IndexedSubsense` now
    /// carries the parts as well, so nothing needs the lossy reading to see the structure.
    /// The example phrases this region owns. Guide punctuation is dropped for the same reason it is dropped
    /// from a definition, and the search stops at the same boundary so a sub-entry's examples stay its own.
    private func exampleTexts(in node: EntryNode, stoppingAt boundary: (EntryNode) -> Bool) -> [String] {
        node.maximalNestedDescendants(where: { $0.classes.contains("ex") }, stoppingAt: boundary)
            .map { EntryIndexer.collapsed($0.text(excluding: { $0.classes.contains("gp") })) }
            .filter { !$0.isEmpty }
    }

    private func definitionTexts(in node: EntryNode,
                                 stoppingAt boundary: (EntryNode) -> Bool) -> [String] {
        node.maximalDescendants(where: isDefinition, stoppingAt: boundary)
            .map { EntryIndexer.collapsed($0.text(excluding: boundary)) }
            .filter { !$0.isEmpty }
    }

    private func definitionTexts(in node: EntryNode, stoppingAtSubEntries: Bool) -> [String] {
        // **The text stops at the boundary too, not only the search for regions.** A definition element
        // enclosing a sub-entry used to have its whole subtree read, so the parent absorbed a definition
        // the sub-entry then emitted again — `declaredDefinitions = 1`, `capturedDefinitions = 2`,
        // retention 2.0, breaking the bound `IndexedEntry.definitionsReached` promises.
        // **Guide punctuation is guide punctuation wherever it sits.** `gp` was excluded from headwords and
        // not from definitions, and Apple puts it *inside* the definition element about as often as beside
        // it: the Writer's Thesaurus stored `"renounce,"` for a sense whose content is `renounce`, and NOAD's
        // `ditto` came out as `ditto.`. It reaches the digest as well as the reader — `normalise` trims the
        // ends, so a trailing comma was harmless to the key and wrong in the text, while a `gp` in the
        // middle was wrong in both.
        let boundary: (EntryNode) -> Bool = stoppingAtSubEntries
            ? { self.isSubEntry($0) || $0.classes.contains("gp") }
            : { $0.classes.contains("gp") }
        return definitionNodes(in: node, stoppingAtSubEntries: stoppingAtSubEntries)
            .map { EntryIndexer.collapsed($0.text(excluding: boundary)) }
            .filter { !$0.isEmpty }
    }

    /// Maximal definition regions this region owns. With `stoppingAtSubEntries`, a nested sub-entry keeps
    /// its own — the parent sense must not absorb a phrasal verb's definition and, with it, its label.
    private func definitionNodes(in node: EntryNode, stoppingAtSubEntries: Bool) -> [EntryNode] {
        node.maximalDescendants(where: isDefinition,
                                stoppingAt: stoppingAtSubEntries ? { self.isSubEntry($0) }
                                                                 : { _ in false })
    }

    /// Only the attribute the profile declares. Reading `lexid ?? id` regardless would let a dictionary
    /// that declares one silently key off the other, which makes the declaration decorative — and the
    /// declarations are the thing the adapters exist to state.
    private func publisherID(of node: EntryNode) -> String? {
        profile.senseIDAttributes.lazy.compactMap { node.attributes[$0] }.first { !$0.isEmpty }
    }

    /// The number this block prints against itself, ignoring any that belongs to a subsense.
    ///
    /// Skipping subsense subtrees matters: NOAD's `@` has a sense whose second subsense is labelled `•`,
    /// and a plain document-order search for `class="sn"` inside a sense carrying no number of its own
    /// would take that bullet as the sense's number.
    private func senseNumber(of node: EntryNode) -> String? {
        number(of: node, subsenseToken: "x_xd\(profile.senseDepth)sub")
    }

    /// The number this block prints against itself, ignoring one that belongs to a subsense or to a nested
    /// sub-entry. `subsenseToken` differs between the main-sense tree and a sub-entry's.
    private func number(of node: EntryNode, subsenseToken: String) -> String? {
        guard let found = node.firstDescendant(
            where: { !$0.classes.contains("sn") ? false : !EntryIndexer.collapsed($0.text).isEmpty },
            stoppingAt: { $0.classes.contains(subsenseToken) || self.isSubEntry($0) })
        else { return nil }
        let text = EntryIndexer.collapsed(found.text)
        return text.isEmpty ? nil : text
    }

    private func partOfSpeechLabel(in node: EntryNode) -> String? {
        guard let pos = node.firstDescendant(
            where: { self.tree.dictionaryAttribute("pos", of: $0) != nil },
            stoppingAt: { self.isSubEntry($0)
                || self.profile.marksPartOfSpeechBlock(classes: $0.classes) })
        else { return nil }
        let text = EntryIndexer.collapsed(pos.text)
        return text.isEmpty ? nil : text
    }

    /// A sub-entry's own label. `l` is preferred over the enclosing `x_xoh` block, whose text also carries
    /// the pronunciation and the part of speech: NOAD writes
    /// `<span class="x_xoh"><span class="l">abjection </span><span class="prx"> | əbˈdʒɛkʃən | </span>…`.
    private func subEntryLabel(of node: EntryNode) -> String? {
        let inner: (EntryNode) -> Bool = { self.isSubEntry($0) }
        let preferred = node.firstDescendant(where: { $0.classes.contains("l") }, stoppingAt: inner)
        let block = preferred
            ?? node.firstDescendant(where: { $0.classes.contains("x_xoh") }, stoppingAt: inner)
        guard let block else { return nil }
        let text = EntryIndexer.collapsed(block.text(excluding: Self.isNotPartOfAName))
        return text.isEmpty ? nil : text
    }
}
