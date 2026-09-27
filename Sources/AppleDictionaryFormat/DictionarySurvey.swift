import Foundation

/// Everything this module can establish about one dictionary, measured in one pass.
///
/// **This exists because the 86 dictionaries are not one format.** They share a container and diverge
/// inside it: sense depth, which attribute carries a publisher id, whether the key pointers can be
/// followed at all. A rebuild driver has to ask each dictionary what it is before deciding what to do
/// with it, and a survey that answers per dictionary is the only honest way to do that.
///
/// Every field is a measurement or a declaration, and `failures` records what could not be read rather
/// than letting a zero pass for a fact.
public struct DictionaryFacts: Sendable {
    public let identifier: String
    public let displayName: String

    // MARK: Container
    /// Nil when `Body.data` could not be read at all. `com.apple.dictionary.AppleDictionary` is the one
    /// such case in the catalogue: its chunks are not zlib-wrapped deflate.
    public let bodyChunks: Int?
    public let entries: Int

    // MARK: Senses
    public let senses: Int
    public let sensesWithPublisherID: Int
    /// Senses whose content key fell back to an ordinal, because another sense of the same entry had both
    /// the same definition and the same declared position.
    ///
    /// **The one place the keying scheme is still order-dependent, counted rather than assumed away.**
    /// Everything else about a content key is a function of the sense alone; these are the senses for
    /// which that is not true, so a dictionary where this number is large is one whose content keys will
    /// move if the publisher reorders. 0 is the intended value.
    public let sensesNeedingOrdinals: Int
    public let senseDepth: Int
    public let senseIDAttributes: [String]
    /// Share of the definition-marked elements the markup declares that reached a sense at `senseDepth`.
    ///
    /// **Counts `d:def` *and* `class="df"`, and is counted by the parser.** Counting only `d:def=` put a
    /// definition without that attribute in neither numerator nor denominator, so NOAD read a clean 100%
    /// while a quarter of its definitions were never reached. Bounded in [0, 1] by construction now —
    /// `declared` counts maximal definition regions — where the earlier ratio could exceed 1 and did.
    public let definitionRetention: Double
    /// The two sides of `definitionRetention`, carried so a share is never reported without the counts it
    /// came from. A denominator that quietly shrinks is the failure mode this makes visible.
    ///
    /// `declaredDefinitions` **includes records the indexer refused**. NOAD has 27 records with no headword
    /// block holding 46 definition-marked elements; counting only accepted entries made retention read
    /// exactly 100.00% while those 46 were unreachable.
    public let declaredDefinitions: Int
    public let capturedDefinitions: Int
    /// Records that are not entries, by reason. A dictionary refusing many is one whose definitions are
    /// going somewhere this module cannot see, and a ratio alone would not say so.
    public let refusedRecords: [String: Int]
    /// Records whose bytes are not UTF-8, so nothing in them could be read. Their lengths and bounds were
    /// valid; they are counted rather than skipped, because a survey that drops them reports complete
    /// measurements over incomplete input.
    public let undecodableRecords: Int

    // MARK: What an adapter would have to clean up
    /// Entries whose headword carries a pronunciation — Apple delimits it with `|`, so `roo | ro͞oru |`.
    /// A rebuild that stores this as the headword stores something no reader will ever type.
    public let headwordsWithPronunciation: Int
    /// Entries declaring a homograph number, which is what distinguishes `hood 1` from `hood 2`.
    public let homographs: Int
    /// Senses carrying a part-of-speech label. Where this is 0 the dictionary does not mark one, and a
    /// selector that narrows by part of speech narrows to nothing.
    public let sensesWithPartOfSpeech: Int
    /// Senses that yield a publisher id when the profile is pinned to `lexid`, and to `id`.
    ///
    /// Which attribute a dictionary uses is **measured by indexing it both ways**, not by looking for the
    /// string in the markup: `lexid=` appears on elements that are not senses, so a substring count
    /// overstates it — it reported 46 dictionaries using `lexid` where indexing finds fewer. Both are run
    /// over the same entries in one pass, so the two counts are directly comparable.
    ///
    /// This matters because a default naming one attribute drops every id in the dictionaries using the
    /// other, which is exactly what happened: pinning the default to `id` silently dropped 28 dictionaries
    /// out of a validation set.
    public let sensesKeyedByLexid: Int
    public let sensesKeyedByID: Int

    /// Entries carrying `d:index` elements — their own search keys, inline.
    ///
    /// **NOAD has none**, Apple having moved them into `KeyText.data` at build time. If any dictionary
    /// keeps them, its keys can be read without the key file or its pointer arithmetic at all, which is a
    /// different and much easier rebuild for that dictionary.
    public let entriesWithInlineIndex: Int

    // MARK: Keys
    public let keyGroups: Int
    public let keyStrings: Int
    public let phraseGroups: Int
    /// Nil when resolution was not attempted, which is not the same as attempted and failed.
    public let resolution: KeyResolutionReport?

    public let failures: [String]

    public var hasPublisherIDs: Bool { sensesWithPublisherID > 0 }
    public var publisherIDShare: Double { senses > 0 ? Double(sensesWithPublisherID) / Double(senses) : 0 }
    public var phraseShare: Double { keyGroups > 0 ? Double(phraseGroups) / Double(keyGroups) : 0 }

    /// What a rebuild can actually do with this dictionary.
    ///
    /// Deliberately coarse, and deliberately pessimistic: a dictionary whose keys cannot be trusted is
    /// still useful for its senses, and saying so is more use than a single pass/fail.
    public enum Usability: String, Sendable {
        /// Senses and keys both verified. Everything a rebuild wants.
        case full
        /// Senses read, keys unusable or unverified. Lookups by headword work; phrases and inflections do not.
        case sensesOnly
        /// The container could not be read. Nothing is available.
        case unreadable
    }

    public var usability: Usability {
        // **Senses, not merely entries.** `EntryIndexer` accepts an entry with an id and a headword even
        // when it extracts no sense, so a dictionary supplying none was reported `sensesOnly` — or `full`
        // when its key agreement passed — while having nothing a reader could be shown.
        guard bodyChunks != nil, entries > 0, senses > 0 else { return .unreadable }
        return resolution?.isUsable == true ? .full : .sensesOnly
    }
}

/// Measures a dictionary against every fact this module knows how to establish.
///
/// **Two tiers, because they cost very different amounts.** The container and sense measurements need one
/// body pass. Key resolution needs two more and dominates the runtime — on the development machine a
/// survey of nine dictionaries took 471 seconds, almost all of it here. `includingKeys: false` is the
/// tier a caller wants when it is deciding what to show, not what to build.
public enum DictionarySurvey {
    public static func measure(_ bundle: DictionaryBundle, includingKeys: Bool = true) -> DictionaryFacts {
        var failures: [String] = []
        let profile = bundle.profile

        // Container and senses, one pass.
        var chunks: Int?
        var entries = 0, senses = 0, withID = 0, needingOrdinals = 0
        var declaredDefinitions = 0, capturedDefinitions = 0
        var refused: [String: Int] = [:]
        var undecodable = 0
        var pronounced = 0, homographs = 0, withPOS = 0, inlineIndex = 0
        var lexidSenses = 0, idSenses = 0
        let indexer = EntryIndexer(dictionary: bundle.identifier, profile: profile)
        let byLexid = EntryIndexer(dictionary: bundle.identifier, profile: DictionaryProfile(
            identifier: profile.identifier, senseDepth: profile.senseDepth, senseIDAttributes: ["lexid"]))
        let byID = EntryIndexer(dictionary: bundle.identifier, profile: DictionaryProfile(
            identifier: profile.identifier, senseDepth: profile.senseDepth, senseIDAttributes: ["id"]))
        do {
            var count = 0
            try ContainerReader.forEachBodyChunk(at: ContainerReader.bodyURL(of: bundle.url)) { _, chunk in
                count += 1
                for offset in BodyLayout.recordOffsets(in: chunk) {
                    guard let xhtml = BodyLayout.record(in: chunk, at: offset) else {
                        // A record whose bytes are not UTF-8. Its length and bounds were already valid, so
                        // this is content the reader cannot see — counted, because a survey that drops it
                        // reports complete measurements over incomplete input.
                        undecodable += 1
                        continue
                    }
                    // Retention is read off the indexer's own counts rather than searched for in the
                    // text. Two string-counting versions of this were wrong in ways that read as success:
                    // the substring `d:def` occurs three times per definition and gave every dictionary
                    // exactly 33.3%, and `d:def=` omitted every definition marked only by `class="df"` —
                    // a quarter of NOAD — from numerator and denominator alike. `IndexedEntry` explains it.
                    // Indexed a second and third time with each attribute pinned, so "which attribute
                    // does this dictionary use" is answered by the reader that will actually read it.
                    lexidSenses += byLexid.index(xhtml)?.senses.count { $0.key.origin == .publisher } ?? 0
                    idSenses += byID.index(xhtml)?.senses.count { $0.key.origin == .publisher } ?? 0
                    let outcome = indexer.outcome(for: xhtml)
                    let inline = outcome.inlineIndexElements
                    guard let entry = outcome.entry else {
                        // A refused record still declared whatever it declared. Dropping that from the
                        // denominator is how retention read 100% with definitions unreachable.
                        declaredDefinitions += outcome.declaredDefinitions
                        if let why = outcome.rejection { refused[why.rawValue, default: 0] += 1 }
                        continue
                    }
                    entries += 1
                    declaredDefinitions += entry.declaredDefinitions
                    capturedDefinitions += entry.capturedDefinitions
                    senses += entry.senses.count
                    withID += entry.senses.count { $0.key.origin == .publisher }
                    needingOrdinals += entry.sensesNeedingOrdinals.count
                    withPOS += entry.senses.count { $0.partOfSpeech != nil }
                    if inline > 0 { inlineIndex += 1 }
                    if entry.headword.contains("|") { pronounced += 1 }
                    if entry.homograph != nil { homographs += 1 }
                }
            }
            chunks = count
        } catch {
            failures.append("body: \(error)")
        }

        // Keys, which cost more than everything above put together.
        var groups = 0, strings = 0, phrases = 0
        var report: KeyResolutionReport?
        if includingKeys {
            do {
                let parsed = try KeyIndexReader.groups(in: bundle.url)
                groups = parsed.count
                strings = parsed.reduce(0) { $0 + $1.keys.count }
                phrases = parsed.count { $0.isPhrase }
            } catch {
                failures.append("keys: \(error)")
            }
            if groups > 0 {
                do { report = try KeyIndexBuilder.build(bundle: bundle.url, profile: profile) { _ in } }
                catch { failures.append("resolution: \(error)") }
            }
        }

        return DictionaryFacts(
            identifier: bundle.identifier, displayName: bundle.displayName,
            bodyChunks: chunks, entries: entries, senses: senses, sensesWithPublisherID: withID,
            sensesNeedingOrdinals: needingOrdinals,
            senseDepth: profile.senseDepth, senseIDAttributes: profile.senseIDAttributes,
            definitionRetention: declaredDefinitions > 0
                ? Double(capturedDefinitions) / Double(declaredDefinitions) : 0,
            declaredDefinitions: declaredDefinitions, capturedDefinitions: capturedDefinitions,
            refusedRecords: refused, undecodableRecords: undecodable,
            headwordsWithPronunciation: pronounced, homographs: homographs,
            sensesWithPartOfSpeech: withPOS,
            sensesKeyedByLexid: lexidSenses, sensesKeyedByID: idSenses,
            entriesWithInlineIndex: inlineIndex,
            keyGroups: groups, keyStrings: strings, phraseGroups: phrases, resolution: report,
            failures: failures)
    }
}
