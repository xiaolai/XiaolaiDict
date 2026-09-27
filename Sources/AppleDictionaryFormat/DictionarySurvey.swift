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
    public let senseDepth: Int
    public let senseIDAttributes: [String]
    /// Share of the `d:def` elements the markup declares that survive into a sense at `senseDepth`.
    /// Below 1.0 means definitions are being lost; above means one sense joins several, which is correct.
    public let definitionRetention: Double

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
        guard bodyChunks != nil, entries > 0 else { return .unreadable }
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
        var entries = 0, senses = 0, withID = 0
        var declaredDefinitions = 0
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
                    guard let xhtml = BodyLayout.record(in: chunk, at: offset) else { continue }
                    // What the markup declares, counted before indexing, so retention is measured
                    // against the source and not against the reader's own output.
                    //
                    // **Count the attribute, not the string.** A definition is written
                    // `<span d:def="1" ...>text<d:def></d:def></span>`, so the substring `d:def` occurs
                    // three times for every one definition — as the attribute, as an empty element, and as
                    // its closing tag. Counting the substring made every dictionary in the catalogue report
                    // exactly 33.3% retention, and *exactly* one third is what gave it away.
                    declaredDefinitions += xhtml.components(separatedBy: "d:def=").count - 1
                    // Indexed a second and third time with each attribute pinned, so "which attribute
                    // does this dictionary use" is answered by the reader that will actually read it.
                    lexidSenses += byLexid.index(xhtml)?.senses.count { $0.key.origin == .publisher } ?? 0
                    idSenses += byID.index(xhtml)?.senses.count { $0.key.origin == .publisher } ?? 0
                    let inline = xhtml.components(separatedBy: "d:index").count - 1
                    guard let entry = indexer.index(xhtml) else { continue }
                    entries += 1
                    senses += entry.senses.count
                    withID += entry.senses.count { $0.key.origin == .publisher }
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
            senseDepth: profile.senseDepth, senseIDAttributes: profile.senseIDAttributes,
            definitionRetention: declaredDefinitions > 0 ? Double(senses) / Double(declaredDefinitions) : 0,
            headwordsWithPronunciation: pronounced, homographs: homographs,
            sensesWithPartOfSpeech: withPOS,
            sensesKeyedByLexid: lexidSenses, sensesKeyedByID: idSenses,
            entriesWithInlineIndex: inlineIndex,
            keyGroups: groups, keyStrings: strings, phraseGroups: phrases, resolution: report,
            failures: failures)
    }
}
