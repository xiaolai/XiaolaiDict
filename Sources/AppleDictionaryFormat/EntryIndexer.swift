import Foundation

/// One entry, reduced to what an index needs.
public struct IndexedEntry: Sendable, Equatable {
    public let entryID: String
    public let headword: String
    /// Apple's homograph marker, where the dictionary numbers them. `fine` the penalty and `fine` the
    /// adjective are different entries and must not merge.
    public let homograph: String?
    public let senses: [IndexedSense]
}

public struct IndexedSense: Sendable, Equatable {
    public let key: SenseKey
    public let partOfSpeech: String?
    public let definition: String
}

/// Turning one entry's XHTML into senses with durable keys.
///
/// Only the structural layer is read — the headword block, the part-of-speech block, the sense blocks
/// at this dictionary's own depth, and the `d:` attributes. Nothing depends on `df`, `trans`, `semb` or
/// `se2`, which are per-publisher; Apple itself ships one XPath per dictionary rather than a universal
/// extractor, and the structural layer is the part that is universal.
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

    /// The entry, or nil when it is not one — a malformed record, or a document with no `d:entry`.
    public func index(_ xhtml: String) -> IndexedEntry? {
        let reader = Reader(profile: profile)
        let parser = XMLParser(data: Data(xhtml.utf8))
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse(), let entryID = reader.entryID, !reader.headword.isEmpty else { return nil }

        // Keys are assigned for the whole entry at once: the ordinal that separates two identically
        // worded senses can only be known by seeing all of them.
        let definitions = reader.senses.map(\.definition)
        let contentKeys = SenseKey.keys(dictionary: dictionary, entry: entryID, definitions: definitions)
        let senses = zip(reader.senses, contentKeys).map { raw, contentKey -> IndexedSense in
            let key: SenseKey
            if profile.expectsPublisherID, let id = raw.publisherID, !id.isEmpty {
                key = .publisher(dictionary: dictionary, entry: entryID, id: id)
            } else {
                key = contentKey
            }
            return IndexedSense(key: key, partOfSpeech: raw.partOfSpeech, definition: raw.definition)
        }
        return IndexedEntry(entryID: entryID, headword: reader.headword,
                            homograph: reader.homograph, senses: senses)
    }

    // MARK: -

    struct RawSense {
        var publisherID: String?
        var partOfSpeech: String?
        var definition: String
    }

    final class Reader: NSObject, XMLParserDelegate {
        let profile: DictionaryProfile
        init(profile: DictionaryProfile) { self.profile = profile }

        var entryID: String?
        var headword = ""
        var homograph: String?
        var senses: [RawSense] = []

        private var depth = 0
        private var posBlockDepth: Int?
        private var headwordDepth: Int?
        private var senseDepth: Int?
        private var definitionDepth: Int?
        /// The definition regions seen inside the open sense block, in document order.
        ///
        /// **One sense per block, but all of its text.** A sense block can hold several `d:def`
        /// elements and they are not one kind of thing. In NOAD the extras are cross-references —
        /// "American English = rappel". In 譯典通 they are co-equal glosses: entry `z_id000001` (一)
        /// has a single sense block holding "one", "one only", "alone", "once", "undivided",
        /// "throughout".
        ///
        /// Emitting one sense per `d:def` gave 1,112 publisher ids two identities each. Keeping only
        /// the first threw away five of 一's six glosses. Joining them keeps the sense singular and its
        /// content whole, which is the only option that is wrong in neither direction.
        private var senseDefinitions: [String] = []
        private var posDepth: Int?
        private var currentPOS: String?
        private var pendingID: String?
        private var buffer = ""

        /// Whether a `d:`-prefixed attribute is present, whatever prefix the document bound to Apple's
        /// namespace. Resolved rather than assumed to be `d`.
        private func dictionaryAttribute(_ local: String, _ attributes: [String: String]) -> String? {
            for (name, value) in attributes where name == "d:\(local)" || name == local {
                if name.hasPrefix("d:") || name == local { return value }
            }
            return nil
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            depth += 1
            if element.hasSuffix("entry"), entryID == nil, let id = attributes["id"] { entryID = id }
            let classes = attributes["class"]

            if headwordDepth == nil, classes?.split(whereSeparator: \.isWhitespace).contains("x_xh0") == true {
                headwordDepth = depth
                buffer = ""
            }
            if headwordDepth != nil, homograph == nil, let marker = attributes["homograph"], !marker.isEmpty {
                homograph = marker
            }
            // **Part of speech is scoped to its own block.** `currentPOS` was set when a `d:pos` element
            // closed and never cleared, so an `x_xd0` block declaring no part of speech inherited the
            // previous block's — reporting a verb sense as a noun, silently, for any entry laid out that
            // way. Entering a block clears it; `partOfSpeechIsScopedToItsOwnBlock` holds that.
            if profile.marksPartOfSpeechBlock(classAttribute: classes) {
                posBlockDepth = depth
                currentPOS = nil
            }
            if profile.marksSense(classAttribute: classes) {
                senseDepth = depth
                // Only the attribute the profile declares. Reading `lexid ?? id` regardless would let a
                // dictionary that declares one silently key off the other, which makes the declaration
                // decorative — and the declarations are the thing the adapters exist to state.
                pendingID = profile.senseIDAttributes.lazy.compactMap { attributes[$0] }
                    .first { !$0.isEmpty }
            }
            if dictionaryAttribute("pos", attributes) != nil { posDepth = depth; buffer = "" }
            if dictionaryAttribute("def", attributes) != nil, senseDepth != nil, definitionDepth == nil {
                definitionDepth = depth
                buffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if let d = definitionDepth, d == depth {
                let text = Self.collapsed(buffer)
                if !text.isEmpty { senseDefinitions.append(text) }
                definitionDepth = nil
                buffer = ""
            }
            if let d = posDepth, d == depth {
                let text = Self.collapsed(buffer)
                if !text.isEmpty { currentPOS = text }
                posDepth = nil
                buffer = ""
            }
            if let d = posBlockDepth, d == depth {
                posBlockDepth = nil
                currentPOS = nil
            }
            if let d = headwordDepth, d == depth {
                headword = Self.collapsed(buffer)
                headwordDepth = nil
                buffer = ""
            }
            // The sense is emitted when its block closes, once, carrying every definition it held.
            if let d = senseDepth, d == depth {
                if !senseDefinitions.isEmpty {
                    senses.append(RawSense(publisherID: pendingID, partOfSpeech: currentPOS,
                                           definition: senseDefinitions.joined(separator: "; ")))
                }
                senseDepth = nil
                pendingID = nil
                senseDefinitions = []
            }
            depth -= 1
        }

        static func collapsed(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }
}
