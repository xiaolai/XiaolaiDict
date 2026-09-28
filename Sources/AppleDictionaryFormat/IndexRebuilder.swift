import Foundation

/// Why a dictionary was not indexed, in terms a reader could act on.
///
/// **A reason, not a boolean.** "Skipped" tells a reader nothing they can do; naming the confidence and the
/// measured agreement tells them whether to wait for a fix, look at the dictionary, or stop expecting it.
public enum RebuildRefusal: Sendable, Equatable, CustomStringConvertible {
    /// The key mapping did not clear the bar. Carries what it scored so the refusal is checkable.
    case keyMappingNotVerified(confidence: KeyResolutionReport.Confidence, agreement: Double)
    /// The container could not be read. `com.apple.dictionary.AppleDictionary` is the catalogue's one case.
    case containerUnreadable(String)
    /// No key groups parsed, so there is nothing to look anything up by.
    case noKeyIndex(String)
    /// The body read, but no record in it was an entry.
    case noEntries
    /// The index itself could not be written or read — locking, disk, a constraint.
    ///
    /// **Separate from `containerUnreadable`, which it used to be reported as.** The distinction is not
    /// cosmetic: a verdict about the *dictionary* withdraws its rows, and a verdict about the *store* must
    /// not, or a transient lock would delete a good index. It also points a reader at the right component.
    case storageFailure(String)

    /// Whether this refusal is a verdict about the **dictionary**, so whatever was indexed from it must be
    /// withdrawn — or about the **store**, so it must not be.
    ///
    /// The distinction decides whether rows are deleted, which is why it is a property of the reason rather
    /// than a decision each `return` makes for itself. Three early returns made it for themselves and got it
    /// wrong: a dictionary that lost its `KeyText.data` was reported refused while its previous candidates
    /// stayed searchable.
    public var withdrawsTheIndex: Bool {
        if case .storageFailure = self { return false }
        return true
    }

    public var description: String {
        switch self {
        case .keyMappingNotVerified(let confidence, let agreement):
            return String(format: """
                its key mapping is %@ — key and headword agree on only %.1f%% of resolved groups, and \
                80%% is the bar. Nothing is known to be wrong with the dictionary: agreement also falls \
                when headword extraction is broken or when the check cannot see that language. Indexing \
                it anyway would put lookups a reader cannot audit in front of them
                """, confidence.rawValue, agreement * 100)
        case .containerUnreadable(let why):
            return "its container could not be read: \(why)"
        case .noKeyIndex(let why):
            return "it has no readable key index, so nothing could be looked up: \(why)"
        case .noEntries:
            return "its body read but held no entry"
        case .storageFailure(let why):
            return "the index could not be written: \(why). The dictionary is fine; the store is not"
        }
    }
}

/// What one dictionary's turn produced.
public struct RebuildOutcome: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case rebuilt(entries: Int, senses: Int, aliases: Int)
        /// Content and extractor generation both unchanged. **Nothing was written.**
        case upToDate
        case refused(RebuildRefusal)
    }

    public let identifier: String
    public let displayName: String
    public let verdict: Verdict

    public var wasRebuilt: Bool { if case .rebuilt = verdict { return true } else { return false } }
    public var wasRefused: Bool { if case .refused = verdict { return true } else { return false } }

    /// A line a reader could read. The refusal reason is part of it, because a refusal nobody can see is
    /// indistinguishable from a dictionary that was never installed.
    public var summary: String {
        switch verdict {
        case .rebuilt(let entries, let senses, let aliases):
            return "\(displayName): rebuilt — \(entries) entries, \(senses) senses, \(aliases) search keys"
        case .upToDate:
            return "\(displayName): up to date"
        case .refused(let why):
            return "\(displayName): not indexed, because \(why)"
        }
    }
}

/// Whether a dictionary is rebuilt, left alone, or refused.
///
/// Pure and separate from the walking, so the rule can be tested without a 230 MB body pass. The driver
/// applies it and does nothing else with these three facts.
public enum RebuildDecision: Sendable, Equatable {
    case rebuild
    case upToDate
    case refuse(RebuildRefusal)

    /// **Refusal comes first.** Deciding "up to date" before checking the mapping would let a dictionary
    /// indexed under an earlier, laxer rule stay indexed for ever.
    public static func decide(needsRebuild: Bool, report: KeyResolutionReport) -> RebuildDecision {
        guard report.groups > 0 else { return .refuse(.noKeyIndex("0 key groups parsed")) }
        guard report.isUsable else {
            return .refuse(.keyMappingNotVerified(confidence: report.confidence,
                                                  agreement: report.displayFormAgreement))
        }
        return needsRebuild ? .rebuild : .upToDate
    }
}

/// Walks the installed dictionaries and brings the index up to date.
///
/// **Mechanical, and that is the point** — every judgement it makes was made and measured somewhere else:
/// which depth delimits a sense (`DictionaryProfile`), what counts as a definition (`marksDefinition`),
/// whether the key mapping can be trusted (`KeyResolutionReport.confidence`), and what a durable sense name
/// is (`SenseKey`). This adds orchestration, refusal, and progress.
///
/// **It refuses rather than indexing quietly.** A dictionary whose key mapping is not `verified` is skipped
/// with a reason, because an uncertified mapping that turns out wrong is worse than a missing one: the
/// reader cannot see it. That is stricter than `DictionaryFacts.Usability`, which calls such a dictionary
/// `sensesOnly` and still useful — deliberately, because this writes the index a reader will trust.
public struct IndexRebuilder {
    /// How far along one dictionary is. Reported often enough to be useful and cheaply enough to ignore.
    public struct Progress: Sendable {
        public let identifier: String
        public let displayName: String
        /// What it is doing: reading keys, resolving them, or writing entries.
        public let stage: Stage
        public let entriesWritten: Int

        public enum Stage: String, Sendable {
            case readingKeys, resolving, writing, finished
        }
    }

    public let store: IndexStore
    public let extractorGeneration: Int

    public init(store: IndexStore, extractorGeneration: Int = IndexStore.extractorGeneration) {
        self.store = store
        self.extractorGeneration = extractorGeneration
    }

    /// Brings every dictionary in `bundles` up to date, in the order given.
    ///
    /// One dictionary's failure never stops the rest: a thrown error becomes that dictionary's refusal, so a
    /// run over 86 assets reports 86 outcomes rather than dying on the first unreadable one.
    @discardableResult
    public func rebuild(_ bundles: [DictionaryBundle],
                        progress: (Progress) -> Void = { _ in }) -> [RebuildOutcome] {
        bundles.map { rebuild(one: $0, progress: progress) }
    }

    func rebuild(one bundle: DictionaryBundle, progress: (Progress) -> Void) -> RebuildOutcome {
        func outcome(_ verdict: RebuildOutcome.Verdict) -> RebuildOutcome {
            RebuildOutcome(identifier: bundle.identifier, displayName: bundle.displayName,
                           verdict: verdict)
        }
        /// **One place that refuses**, so withdrawal cannot be forgotten by a `return` written later.
        func refuse(_ why: RebuildRefusal) -> RebuildOutcome {
            guard why.withdrawsTheIndex else { return outcome(.refused(why)) }
            do { try store.forget(bundle.identifier) }
            catch { return outcome(.refused(.storageFailure("\(error)"))) }
            return outcome(.refused(why))
        }
        func report(_ stage: Progress.Stage, _ written: Int = 0) {
            progress(Progress(identifier: bundle.identifier, displayName: bundle.displayName,
                              stage: stage, entriesWritten: written))
        }

        let profile = bundle.profile
        let version = bundle.contentVersion()

        // The mapping is measured before the rebuild decision, so a dictionary cannot stay indexed under a
        // rule that no longer holds. It costs three body passes, which is why `upToDate` is still worth
        // reporting: it is the writes that are skipped, not the checking.
        report(.readingKeys)
        var aliasesByEntry: [String: [(search: String, forms: [String])]] = [:]
        let resolution: KeyResolutionReport
        do {
            report(.resolving)
            resolution = try KeyIndexBuilder.build(bundle: bundle.url, profile: profile) { key in
                guard let search = key.keys.first, !search.isEmpty else { return }
                // **Every form is kept, not just the last.** A group is a folded search key followed by
                // display forms, and installed NOAD carries `["give or take", "give or take —", "give"]` —
                // so `keys.last` is the base word, and a `give me` group ends in an `xpointer(...)`
                // fragment. Both made the sub-entry scoping match the wrong phrase or nothing.
                aliasesByEntry[key.entryID, default: []].append((search: search, forms: key.keys))
            }
        } catch {
            return refuse(.containerUnreadable("\(error)"))
        }

        let needs: Bool
        do {
            needs = try store.needsRebuild(bundle.identifier, contentVersion: version,
                                           extractorGeneration: extractorGeneration)
        } catch {
            return refuse(.storageFailure("\(error)"))
        }

        switch RebuildDecision.decide(needsRebuild: needs, report: resolution) {
        case .refuse(let why):
            // A refusal withdraws whatever was indexed before: `candidates(for:)` does not filter by
            // verification status, so leaving the rows in place meant a dictionary that had passed once
            // stayed searchable after it stopped passing — and checking refusal before freshness bought
            // nothing at all. `refuse` applies the rule.
            return refuse(why)
        case .upToDate:
            report(.finished)
            return outcome(.upToDate)
        case .rebuild:
            break
        }

        let indexer = EntryIndexer(dictionary: bundle.identifier, profile: profile)
        var entries = 0, senses = 0, aliases = 0
        /// Thrown inside the transaction so an empty replacement rolls back instead of committing.
        struct NoEntries: Error {}
        do {
            try store.inTransaction {
                try store.beginRebuild(identifier: bundle.identifier, displayName: bundle.displayName,
                                       contentVersion: version,
                                       keyConfidence: resolution.confidence.rawValue,
                                       extractorGeneration: extractorGeneration)
                try ContainerReader.forEachEntry(in: bundle.url) { xhtml in
                    guard let entry = indexer.outcome(for: xhtml).entry else { return }
                    let scoped = (aliasesByEntry[entry.entryID] ?? []).map { alias in
                        // The display form shown to a reader: the last form that is not an `xpointer`
                        // fragment, which is a locator rather than a spelling of the word.
                        let display = alias.forms.last { !$0.contains("xpointer(") }
                            ?? alias.forms.last ?? alias.search
                        return SearchAlias(
                            search: alias.search, display: display,
                            subEntry: IndexStore.scope(aliasForms: alias.forms, within: entry))
                    }
                    try store.insert(entry, dictionary: bundle.identifier, aliases: scoped)
                    entries += 1
                    senses += entry.senses.count
                        + entry.senses.reduce(0) { $0 + $1.subsenses.count }
                    aliases += scoped.count
                    if entries % 2000 == 0 { report(.writing, entries) }
                }
                // **Checked inside the transaction.** `beginRebuild` has already deleted the previous
                // index; returning `.noEntries` after the commit destroyed it and recorded an empty
                // replacement as current, which is worse than either outcome on its own.
                //
                // **And senses, not only entries.** `EntryIndexer` accepts an entry with an id and a
                // headword that yields no sense at all, and key agreement is measured on headwords — so a
                // dictionary could verify, produce thousands of entries and not one definition, and commit
                // as a successful rebuild with nothing in it a reader could be shown.
                guard entries > 0, senses > 0 else { throw NoEntries() }
            }
        } catch is NoEntries {
            return refuse(.noEntries)
        } catch let error as IndexStore.Failure {
            return refuse(.storageFailure("\(error)"))
        } catch {
            return refuse(.containerUnreadable("\(error)"))
        }
        report(.finished, entries)
        return outcome(.rebuilt(entries: entries, senses: senses, aliases: aliases))
    }
}
