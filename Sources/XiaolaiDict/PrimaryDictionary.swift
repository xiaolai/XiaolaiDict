import Foundation
import XiaolaiDictCore

/// Which dictionary XiaolaiDict studies from (decision D7).
///
/// It exists because the sense selector is a **closed-set choice**, and a set assembled from every
/// enabled dictionary is not a set it can be judged on: *hold* offers 49 senses in 牛津英汉汉英, 19 in
/// 譯典通, 15 in the Writer's Thesaurus and 11 in NOAD's first entry alone, and among those hundred-odd
/// candidates NOAD's "cargo space" and 牛津's 货舱 are one meaning wearing two ids. Near-duplicates
/// split the probability mass, so the confidently-wrong rate — the number that decides whether
/// marking a sense is honest at all — gets *worse* the more dictionaries the reader enables.
///
/// It also bounds the card: without it, one lookup of *fine* could leave seven study items behind
/// for a single meaning.
struct PrimaryDictionary: Equatable {
    /// `DictionaryIdentity.key` of the dictionary the reader chose, or nil until they choose one.
    let chosen: String?

    init(chosen: String? = nil) {
        self.chosen = chosen
    }

    /// The primary among the dictionaries that answered this lookup.
    ///
    /// The reader's choice when it answered. Otherwise the first dictionary — in the order they set
    /// in Dictionary.app, which is the order these arrive in — that can key a sense at all, because
    /// a primary that cannot is a primary that can never produce a card. Failing that, simply the
    /// first: an entry-level study item is still a study item.
    func identity(among entries: [DictionaryEntry]) -> DictionaryIdentity? {
        if let chosen, let match = entries.first(where: { $0.dictionary.key == chosen }) {
            return match.dictionary
        }
        if let keyable = entries.first(where: { $0.senseKeyKind != SenseKeyKind.none }) {
            return keyable.dictionary
        }
        return entries.first?.dictionary
    }

    /// The primary's own entries, in order.
    func entries(among entries: [DictionaryEntry]) -> [DictionaryEntry] {
        guard let identity = identity(among: entries) else { return [] }
        return entries.filter { $0.dictionary == identity }
    }
}

/// The reader's choice of primary dictionary, kept across launches.
struct PrimaryDictionaryStore {
    static let defaultsKey = "PrimaryDictionary"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PrimaryDictionary {
        PrimaryDictionary(chosen: defaults.string(forKey: Self.defaultsKey))
    }

    /// `nil` clears the choice, which returns XiaolaiDict to picking the first dictionary that can key a
    /// sense rather than remembering one the reader may have removed.
    func save(_ key: String?) {
        if let key {
            defaults.set(key, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}

/// What one lookup leaves in the ledger.
struct LookupRecording {
    let record: LookupRecord
    /// Recorded only where the sense — or at least the entry — is a **fact**. With several entries
    /// from the primary dictionary and no reader tap and no selector, which one the reader was
    /// reading is unknown, and unknown is not written down as a guess.
    let encounter: SenseEncounter?
}

extension PrimaryDictionary {
    /// The encounter this lookup is entitled to record, before any selector has run and before the
    /// reader has tapped anything.
    ///
    /// - one entry, one sense → the sense, `chosenBy: .onlySense`: nothing was chosen, so nothing
    ///   can be wrong.
    /// - one entry, several senses → the entry, with no sense key and no `chosenBy`: null means
    ///   "this entry, sense unresolved".
    /// - several entries → nothing. *fine* is four entries in NOAD and picking one would be a guess.
    func encounter(among entries: [DictionaryEntry], at when: Date) -> SenseEncounter? {
        let mine = self.entries(among: entries)
        guard mine.count == 1, let entry = mine.first, let entryKey = entry.entryKey else { return nil }
        let only = entry.senses.count == 1 ? entry.senses.first : nil
        return SenseEncounter(
            dictionary: entry.dictionary, entryID: entryKey,
            senseKey: only?.key, senseKeyKind: only?.keyKind ?? entry.senseKeyKind,
            sensePath: only?.path, entrySenseCount: entry.senseCount, senseHash: only?.textHash,
            // A snapshot so the ledger stays readable when a dictionary is updated or removed.
            // Local only — never shipped, published, or sent to a remote service.
            gloss: only?.label, chosenBy: only == nil ? nil : .onlySense,
            chosenAt: only == nil ? nil : when)
    }
}


struct SenseResolution: Equatable {
    let mark: SenseMark?
    let encounter: SenseEncounter?
}

/// Deciding which sense a lookup met: rung 0 first, then the selector, then honest silence.
///
/// The ladder, cheapest first — a rung that cannot beat the one below it on a labelled set does not
/// ship (decision D6).
struct SenseResolver {
    let primary: PrimaryDictionary
    let selector: any SenseSelecting

    func resolve(
        entries: [DictionaryEntry], sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?, at when: Date
    ) async -> SenseResolution {
        let mine = primary.entries(among: entries)
        guard !mine.isEmpty else { return SenseResolution(mark: nil, encounter: nil) }

        let candidates = mine.flatMap { entry in
            entry.blocks.flatMap { block in
                block.senses.map {
                    SenseCandidate(
                        entryID: entry.entryID ?? "", key: $0.key ?? "", keyKind: $0.keyKind,
                        text: $0.text, partOfSpeech: block.partOfSpeech)
                }
            }
        }

        // Rung 0: one entry with one sense. Nothing was chosen, so nothing can be wrong, and no
        // selector runs — which is why model invocation correlates with ambiguity, where the hard
        // cases are anyway.
        if mine.count == 1, candidates.count == 1, let only = candidates.first {
            return SenseResolution(
                mark: .chosen(key: only.key, by: .onlySense),
                encounter: primary.encounter(among: entries, at: when))
        }

        let choice = await selector.choose(
            from: candidates, reading: sentence, context: context, partOfSpeech: partOfSpeech)
        switch choice {
        case .chose(let key, _):
            guard let entry = mine.first(where: { $0.senses.contains { $0.key == key } }),
                  let sense = entry.senses.first(where: { $0.key == key }),
                  let entryKey = entry.entryKey
            else {
                // The chosen key belongs to no entry XiaolaiDict can key — nothing is claimed.
                return SenseResolution(mark: nil, encounter: primary.encounter(among: entries, at: when))
            }
            return SenseResolution(
                mark: .chosen(key: key, by: .model),
                encounter: SenseEncounter(
                    dictionary: entry.dictionary, entryID: entryKey, senseKey: key,
                    senseKeyKind: sense.keyKind, sensePath: sense.path, entrySenseCount: entry.senseCount,
                    senseHash: sense.textHash, gloss: sense.label, chosenBy: .model, chosenAt: when))
        case .abstained(let why):
            // It says why it did not choose, and falls back to whatever *is* a fact — the entry,
            // when the primary answered with exactly one.
            return SenseResolution(
                mark: .couldNot(why), encounter: primary.encounter(among: entries, at: when))
        }
    }
}
