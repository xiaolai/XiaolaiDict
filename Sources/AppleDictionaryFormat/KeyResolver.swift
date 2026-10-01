import Foundation

/// Which body chunk holds each record, so a key's pointer can be followed.
///
/// Holds **only the offset map**, never the decompressed chunks: NOAD's body is 230 MB decompressed and a
/// rebuild has no reason to keep it. The map is 92,435 entries for 111,606 records, which is the point —
/// an in-chunk offset is *not* unique, so it cannot identify an entry on its own.
public struct BodyLayout: Sendable {
    /// In-chunk record offset → every chunk index where a record starts at exactly that offset.
    public let chunksByOffset: [Int: [Int]]
    public let chunkCount: Int
    public let recordCount: Int

    /// **68.3% of NOAD's records sit at an offset no other record shares.** The rest need the chunk id,
    /// which is why `KeyResolver` exists rather than a join on offset alone.
    public var unambiguousShare: Double {
        guard recordCount > 0 else { return 0 }
        let unique = chunksByOffset.values.count { $0.count == 1 }
        return Double(unique) / Double(recordCount)
    }

    /// For tests, which construct a layout whose right answer is known by construction rather than
    /// reading one out of a licensed bundle.
    init(chunksByOffset: [Int: [Int]], chunkCount: Int, recordCount: Int) {
        self.chunksByOffset = chunksByOffset
        self.chunkCount = chunkCount
        self.recordCount = recordCount
    }

    public init(bundle: URL) throws {
        var byOffset: [Int: [Int]] = [:]
        var records = 0, chunks = 0
        try ContainerReader.forEachBodyChunk(at: ContainerReader.bodyURL(of: bundle)) { index, chunk in
            chunks += 1
            for offset in Self.recordOffsets(in: chunk) {
                byOffset[offset, default: []].append(index)
                records += 1
            }
        }
        self.chunksByOffset = byOffset
        self.chunkCount = chunks
        self.recordCount = records
    }

    /// Every record start in one decompressed chunk. A record is `UInt32 length` then that many UTF-8
    /// bytes, laid end to end.
    static func recordOffsets(in chunk: Data) -> [Int] {
        var out: [Int] = []
        var offset = 0
        while offset + 4 <= chunk.count {
            guard let length = chunk.uint32(at: offset).map(Int.init) else { break }
            guard length > 0, offset + 4 + length <= chunk.count else { break }
            out.append(offset)
            offset += 4 + length
        }
        return out
    }

    /// The record at an offset, if one starts exactly there. Nil is the answer to "that pointer is not a
    /// record", which is a resolution failing **loudly** rather than returning a neighbouring entry.
    static func record(in chunk: Data, at offset: Int) -> String? {
        guard offset >= 0, let length = chunk.uint32(at: offset).map(Int.init) else { return nil }
        guard length > 0, offset + 4 + length <= chunk.count else { return nil }
        return String(data: chunk.subdata(in: (offset + 4) ..< (offset + 4 + length)), encoding: .utf8)
    }
}

/// Recovers Apple's chunk-id table from the data, exactly, and without knowing how the id is computed.
///
/// **Why derivation rather than reverse-engineering.** `chunkID` is a 16-bit number with no arithmetic
/// relation to a chunk's index, file offset, compressed size or decompressed size — all four were checked
/// and none of them correlates. But the table is *implied*: every group carrying id X points into one
/// chunk, so that chunk must appear in `chunksByOffset[group.offset]` for **every** group with id X.
/// Intersecting those candidate sets cannot admit a wrong answer, and on NOAD it pins all **785 ids to
/// exactly one chunk each**, with no id left ambiguous.
///
/// **One group must never be able to erase a chunk id.** An early version intersected blindly, and a
/// single group whose offset matched no record anywhere emptied the set for its whole id — losing 4,829
/// groups to 7 poisoned ids. A group that cannot be satisfied is dropped; it is one group's problem, not
/// the chunk's.
public struct KeyResolver: Sendable {
    /// Apple's chunk id → the body chunk index it denotes.
    public let table: [Int: Int]
    /// Ids whose candidates never narrowed to one chunk. **0 on NOAD.**
    public let ambiguousIDs: Int

    public init(groups: [KeyGroup], layout: BodyLayout) {
        var candidates: [Int: Set<Int>] = [:]
        for group in groups {
            let here = Set(layout.chunksByOffset[group.pointer.offset] ?? [])
            // Contributes no constraint, and intersecting with it would destroy every real one.
            guard !here.isEmpty else { continue }
            guard let known = candidates[group.pointer.chunkID] else {
                candidates[group.pointer.chunkID] = here
                continue
            }
            let narrowed = known.intersection(here)
            candidates[group.pointer.chunkID] = narrowed.isEmpty ? known : narrowed
        }
        var table: [Int: Int] = [:]
        var ambiguous = 0
        for (id, set) in candidates {
            if set.count == 1, let only = set.first { table[id] = only } else { ambiguous += 1 }
        }
        self.table = table
        self.ambiguousIDs = ambiguous
    }

    /// The body chunk a pointer names, or nil for an id this dictionary never constrained.
    public func chunkIndex(for pointer: EntryPointer) -> Int? { table[pointer.chunkID] }
}

/// A key group joined to the entry it names.
public struct ResolvedKey: Sendable, Equatable {
    public let keys: [String]
    public let entryID: String
    public let headword: String

    public init(keys: [String], entryID: String, headword: String) {
        self.keys = keys
        self.entryID = entryID
        self.headword = headword
    }
}

/// Reports what a resolution pass achieved, because a count is the only way to know it happened.
///
/// **`resolved` is not the same as `correct`, and conflating them was the defect this type exists to
/// prevent.** A pointer that lands on *a* record resolves; whether it is the *right* record is a separate
/// question, and for one dictionary measured here the answer was almost always no while resolution
/// reported 100%. Read `confidence` before believing `resolved`.
public struct KeyResolutionReport: Sendable {
    public var groups = 0
    public var resolved = 0
    public var unknownChunkID = 0
    /// The pointer landed somewhere that is not a record start. **2,231 of 252,428 on NOAD (0.88%)** —
    /// and a failure here is loud by construction, never a neighbouring entry returned as if correct.
    public var notARecord = 0
    public var unparsableEntry = 0

    /// Groups whose display form shares an opening with the headword they resolved to, over those checked.
    ///
    /// **Not containment.** Asking whether the headword *contains* the key fails for every suffix-inflected
    /// form and for every dictionary that writes pronunciation inside the word; it scored Russian at 7.9%
    /// and Traditional Chinese at 6.9% while both resolved correctly. `KeyAgreement` explains the test and
    /// what it is still blind to.
    public var displayFormAgreement = 0.0
    public var displayFormsChecked = 0

    /// What the chunk-id derivation managed, carried here so one pass answers every question about it and
    /// a caller never has to redo the body walk to find out.
    public var chunkIDsPinned = 0
    /// Ids whose candidates never narrowed to one chunk. **1 on NOAD, 5 on ko.NewAce, 0 elsewhere** — an
    /// id left ambiguous resolves to nothing, which is the safe direction to fail in.
    public var chunkIDsAmbiguous = 0
    public var bodyChunks = 0
    /// The share of body records sitting at an offset no other record shares — what a join on offset
    /// alone could settle. **68.3% on NOAD**, which is why the chunk id is needed at all.
    public var unambiguousOffsetShare = 0.0

    public var resolvedShare: Double { groups > 0 ? Double(resolved) / Double(groups) : 0 }

    /// Whether the resolved mapping may be used — and, when not, **what is actually in doubt.**
    ///
    /// Agreement is the share of resolved groups whose key and headword share an opening once pronunciation
    /// is stripped (`KeyAgreement`). It is the only oracle available without leaving this module, and it
    /// measures **a chain, not the mapping**: a low score means one of
    ///
    /// 1. the key mapping is wrong,
    /// 2. the **headword extraction** is wrong — `he.oup` and `ro.oup` yield `Tranz.` and `(Pop. şi fam.)`
    ///    as headwords, which is this module's own recorded `x_xh0` defect and nothing to do with keys, or
    /// 3. the oracle is blind to that language — a kana key against a kanji headword shares no opening,
    ///    and neither does a prefix-inflecting morphology.
    ///
    /// **So a low score is a refusal to certify, not a finding of fault.** Naming the case `rejected`
    /// implied the mapping had been shown wrong, and that implication was false: `zh_TW-en.DrEye` scored
    /// 3.5% under an earlier containment oracle, was described as resolving 96.5% of its keys to the wrong
    /// entry, and scores **100.0%** here — its headwords interleave Bopomofo between every character, so
    /// containment could never have matched. Nothing was wrong with it but the measurement.
    ///
    /// Measured over the whole catalogue: **64 verified, 10 unverified, 10 disagreeing, 2 with no keys.**
    public enum Confidence: String, Sendable {
        /// Agreement at or above 0.80. Safe to build an index from.
        case verified
        /// Between 0.50 and 0.80. Not certified, not impeached.
        case unverified
        /// Below 0.50. Something in the chain is wrong, and this measurement cannot say which link.
        case disagrees
        /// Nothing was checked, so nothing is known. **Never treated as passing.**
        case unmeasured
    }

    public var confidence: Confidence {
        guard displayFormsChecked > 0 else { return .unmeasured }
        if displayFormAgreement >= 0.80 { return .verified }
        if displayFormAgreement >= 0.50 { return .unverified }
        return .disagrees
    }

    /// Whether a rebuild should use this dictionary's key index. Only `verified` qualifies: an uncertified
    /// mapping that turns out wrong is worse than a missing one, because a reader cannot see it.
    public var isUsable: Bool { confidence == .verified }

    public var summary: String {
        String(format: "%d of %d resolved (%.2f%%); %d unknown id, %d not a record, %d unparsable; %d ids pinned over %d chunks (%d ambiguous); offset alone %.1f%%; agreement %.1f%% → ",
               resolved, groups, resolvedShare * 100, unknownChunkID, notARecord, unparsableEntry,
               chunkIDsPinned, bodyChunks, chunkIDsAmbiguous, unambiguousOffsetShare * 100,
               displayFormAgreement * 100) + confidence.rawValue
    }
}

/// Joins keys to entries in one streaming pass over the body.
///
/// **Three passes, in this order, and the order is load-bearing.** The keys are read first because they
/// are small (4 MB on disk). The body's record layout comes second, and yields only an offset map. The
/// chunk table is derived third, from those two and no file access at all. Only then is the body walked
/// again to read the entries themselves — one chunk in memory at a time, with every group that points
/// into that chunk resolved while it is open.
///
/// Measured on NOAD: **267,481 of 269,918 groups resolved, 99.10%**, reaching 103,933 distinct entries.
/// Of the rest, every single one is a pointer that is not a record start — never a wrong entry returned
/// as though it were right.
public enum KeyIndexBuilder {
    /// Every key group joined to its entry, handed over as it is resolved.
    ///
    /// `onKey` is called once per group, so an entry with several ways of finding it is reported several
    /// times. That is deliberate: the caller is building an index from keys to entries, and collapsing
    /// them here would throw away the distinction between `čapek` and `čapek, karel`.
    @discardableResult
    public static func build(
        bundle: URL, profile: DictionaryProfile, onKey: (ResolvedKey) throws -> Void
    ) throws -> KeyResolutionReport {
        let groups = try KeyIndexReader.groups(in: bundle)
        let layout = try BodyLayout(bundle: bundle)
        let resolver = KeyResolver(groups: groups, layout: layout)
        var report = KeyResolutionReport()
        report.chunkIDsPinned = resolver.table.count
        report.chunkIDsAmbiguous = resolver.ambiguousIDs
        report.bodyChunks = layout.chunkCount
        report.unambiguousOffsetShare = layout.unambiguousShare

        // Group the work by body chunk, so the body is walked once and each chunk is held once.
        var byChunk: [Int: [KeyGroup]] = [:]
        report.groups = groups.count
        for group in groups {
            guard let chunk = resolver.chunkIndex(for: group.pointer) else {
                report.unknownChunkID += 1
                continue
            }
            byChunk[chunk, default: []].append(group)
        }

        var agreementChecked = 0, agreementHits = 0
        let indexer = EntryIndexer(dictionary: profile.identifier, profile: profile)
        try ContainerReader.forEachBodyChunk(at: ContainerReader.bodyURL(of: bundle)) { index, chunk in
            guard let here = byChunk[index] else { return }
            // One entry serves many groups; parse it once per chunk visit rather than once per group.
            var parsed: [Int: IndexedEntry?] = [:]
            for group in here {
                guard let xhtml = BodyLayout.record(in: chunk, at: group.pointer.offset) else {
                    report.notARecord += 1
                    continue
                }
                let entry: IndexedEntry?
                if let cached = parsed[group.pointer.offset] { entry = cached }
                else {
                    entry = indexer.index(xhtml)
                    parsed[group.pointer.offset] = entry
                }
                guard let entry else {
                    report.unparsableEntry += 1
                    continue
                }
                report.resolved += 1
                // Checked here rather than left to the caller, so a report can never come back without
                // the one number that says whether its mapping is believable.
                if let display = group.displayKey, !display.isEmpty {
                    agreementChecked += 1
                    if KeyAgreement.agrees(key: display, headword: entry.headword) { agreementHits += 1 }
                }
                try onKey(ResolvedKey(keys: group.keys, entryID: entry.entryID, headword: entry.headword))
            }
        }
        report.displayFormsChecked = agreementChecked
        report.displayFormAgreement = agreementChecked > 0 ? Double(agreementHits) / Double(agreementChecked) : 0
        return report
    }
}
