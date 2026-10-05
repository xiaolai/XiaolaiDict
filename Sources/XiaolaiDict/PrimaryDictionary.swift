import DictionaryModel
import Foundation
import XiaolaiDictCore
import XiaolaiDictUI

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
struct PrimaryDictionary: Equatable, Sendable {
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

    /// **One primary for the whole lookup**, decided once and handed to every consumer — the card,
    /// the first recording and the resolver. Each used to ask `identity(among:)` of a different list:
    /// unchosen, an unkeyable word dictionary beside a keyable phrase dictionary made the card open on
    /// one and the resolver mark a sense in the other.
    ///
    /// A choice that answered anywhere — word or phrase — stands. Otherwise the word's own entries
    /// decide, because the card opens on them; a phrase's decide only where the word had none.
    func pinned(word entries: [DictionaryEntry], phrase phraseEntries: [DictionaryEntry]) -> PrimaryDictionary {
        if let chosen, (entries + phraseEntries).contains(where: { $0.dictionary.key == chosen }) { return self }
        guard let identity = identity(among: entries) ?? identity(among: phraseEntries) else { return self }
        return PrimaryDictionary(chosen: identity.key)
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
    /// The reading this lookup reopens, by its row's identity — nil for a new lookup.
    var lookup: LookupIdentity? = nil
    var keepPolicy: LookupKeepPolicy = .manual
    var primaryDictionary: String? = nil
    /// **The phrase whose own entry `encounter` is in**, by the inventory's spelling — nil where it is the
    /// word's. Automatic keeping keeps that sense as the entry's, as it always did (ADR-0028), unless the
    /// reader saved the phrase as a card already: then that card stands for it (ADR-0049).
    var phraseOfEncounter: String? = nil
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
    ///
    /// `phraseEntries` are the entries of a phrase the reader was standing inside. **One of this
    /// dictionary's withdraws `.onlySense`**, exactly as it stops rung 0 in `SenseResolver.resolve`:
    /// the word's one sense and the phrase's are two readings, and recording the first as the only one
    /// there was let automatic keeping confirm it while the selector was still choosing.
    ///
    /// **The primary is decided over the word's entries and the phrase's together** — the list the
    /// resolver's candidates come from — **and the encounter is taken from that dictionary's word entries
    /// alone** (audit-fix round 3, #3). Decided over the word's alone, a choice that answered only the
    /// phrase is absent there, and `identity(among:)` fell back to whichever other dictionary answered the
    /// word: rung 0 marked the primary's phrase and recorded an auxiliary word's only sense as
    /// `.onlySense`. A primary with no entry for the word has no word encounter to record.
    func encounter(among entries: [DictionaryEntry], phrase phraseEntries: [DictionaryEntry] = [], at when: Date) -> SenseEncounter? {
        guard let primary = identity(among: entries + phraseEntries) else { return nil }
        let mine = entries.filter { $0.dictionary == primary }
        guard mine.count == 1, let entry = mine.first, let entryKey = entry.entryKey else { return nil }
        // One sense, and it can be keyed → the shared builder, the same call the resolver and the
        // reader's tap make. **Not a guard that matches theirs — their guard.** An entry with one
        // unkeyable sense used to come back `.onlySense` here, the most confirmed provenance there
        // is, for a sense nothing can point at again: the mark was guarded and the encounter was
        // not. Two guards that agree today is the arrangement that produced that, so there is one.
        let phraseCompetes = phraseEntries.contains { $0.dictionary.key == entry.dictionary.key }
        if !phraseCompetes, entry.senses.count == 1, let key = entry.senses.first?.key,
           let only = SenseEncounter.of(entry, senseKey: key, chosenBy: .onlySense, at: when) {
            return only
        }
        // Otherwise the entry alone, with no sense key and no `chosenBy` — which reads as "this
        // entry, sense unresolved" rather than as a claim about any sense in it. A separate record
        // from the one above, not a lesser-filled version of it.
        return SenseEncounter(
            dictionary: entry.dictionary, entryID: entryKey, senseKey: nil,
            senseKeyKind: entry.senseKeyKind, sensePath: nil, entrySenseCount: entry.senseCount,
            senseHash: nil, gloss: nil, chosenBy: nil, chosenAt: nil)
    }
}


struct SenseResolution: Equatable, Sendable {
    let mark: SenseMark?
    let encounter: SenseEncounter?
    /// Which entry the mark is about — `PanelSelection.identity(of:)`'s spelling, so the card can
    /// compare without knowing how identity is built. Nil where nothing was marked. The resolver
    /// only ever looks at the primary dictionary's entries, so a mark drawn on any other entry was
    /// always borrowed.
    var owner: String? = nil

    /// Why no sense was marked, where the selector said.
    var abstention: Abstention? {
        guard case .couldNot(let why, _)? = mark else { return nil }
        return why
    }
}

/// Deciding which sense a lookup met: rung 0 first, then the selector, then honest silence.
///
/// The ladder, cheapest first — a rung that cannot beat the one below it on a labelled set does not
/// ship (decision D6).
/// Sendable because it travels into the task group that resolves the sense: `SenseSelecting` is
/// already `Sendable` and `PrimaryDictionary` is a `String?`. What must *not* travel is the closure
/// that reads the reader's chosen dictionary — that is called on this actor and the resolved value
/// is what goes with the work.
struct SenseResolver: Sendable {
    let primary: PrimaryDictionary
    let selector: any SenseSelecting

    /// Every sense of every entry, flattened into what the selector takes.
    ///
    /// Lifted out because it is the one part of `resolve` that decides nothing: a pure transform
    /// from entries to candidates, with no view on which of them is right. The rest of `resolve`
    /// is a single decision told in order — rung 0, then the selector, then what its answer is
    /// worth — and splitting *that* across methods to make each one shorter would hide the
    /// sequence the reader needs, which is the only reason the method is long.
    ///
    /// The part of speech comes from the block rather than the sense: it is a property of the
    /// entry's grammatical division, and the selector matches on it.
    static func candidates(in entries: [DictionaryEntry]) -> [SenseCandidate] {
        entries.flatMap { entry in
            entry.blocks.flatMap { block in
                block.senses.map {
                    SenseCandidate(
                        entryID: entry.entryID ?? "", key: $0.key ?? "", keyKind: $0.keyKind,
                        text: $0.text, partOfSpeech: block.partOfSpeech)
                }
            }
        }
    }

    /// `phrase` is the entries for the phrase the reader was standing inside, where there was one.
    ///
    /// **They join the candidate set rather than replacing it, and context decides between them.** Hovering
    /// *take* in "take what people think into account" offers *take*'s 13 senses and
    /// *take something into account*'s 6, and the selector answers which the reader is reading — the
    /// question a span heuristic cannot answer and the reason the phrase is detected at all.
    ///
    /// Measured 2026-09-29: **25 of 32** words inside a phrase gain senses this way. The 7 that do not are
    /// the words the phrase is *filed under* — hovering `account` in `take something into account`, or
    /// `rein` in `keep a tight rein on` — where the framework already answers with that entry, so the
    /// senses were in the set before. A first measurement compared each phrase against its head noun and
    /// concluded the enlargement was a no-op; the head noun is not the word the reader hovered.
    ///
    /// **Rung 0 stops firing when a phrase is present, and that is correct.** A word with one sense is no
    /// longer unambiguous once the sentence also holds a phrase: there is something to choose between, so
    /// `.onlySense` — the strongest mark there is — must not be claimed.
    func resolve(
        entries: [DictionaryEntry], phrase phraseEntries: [DictionaryEntry] = [],
        sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?, at when: Date
    ) async -> SenseResolution {
        let mine = primary.entries(among: entries + phraseEntries)
        guard !mine.isEmpty else { return SenseResolution(mark: nil, encounter: nil) }

        let candidates = Self.candidates(in: mine)

        // Rung 0: one entry with one sense. Nothing was chosen, so nothing can be wrong, and no
        // selector runs — which is why model invocation correlates with ambiguity, where the hard
        // cases are anyway.
        // Keyable, or nothing is claimed. "A sense a dictionary cannot key is never presented as
        // confirmed, however it was marked" — and `.onlySense` is the most confirmed mark there
        // is. An unkeyable sense reaches here with `key: ""`, which would have been written to the
        // ledger as the id of a sense nothing can point at again.
        if mine.count == 1, candidates.count == 1, let only = candidates.first,
           only.keyKind != SenseKeyKind.none, !only.key.isEmpty {
            // **Asked with the phrase's entries too**, so the encounter is decided over the list `mine`
            // was: where the one candidate is the primary's phrase, no word of another dictionary is
            // recorded under it (audit-fix round 3, #3). The phrase's mark stands; the ledger records
            // nothing for it, because a detected phrase is an inference and `.onlySense` is a fact.
            return SenseResolution(
                mark: .chosen(key: only.key, by: .onlySense),
                encounter: primary.encounter(among: entries, phrase: phraseEntries, at: when),
                owner: mine.first.map { PanelSelection.identity(of: $0) })
        }

        let choice = await selector.choose(
            from: candidates, reading: sentence, context: context, partOfSpeech: partOfSpeech)
        switch choice {
        // **`.model` covers a choice no model made**: where the part-of-speech filter leaves one
        // sense, the rung answers without asking anything. That is still a hypothesis — the tagger
        // can be wrong about the part of speech — and `.model` is the provenance that draws as one.
        // `.onlySense` would be the stronger claim, and it belongs to an entry that has one sense.
        case .chose(let key, _, let entryID):
            // By entry *and* key. A positional key is `"\(block).\(ordinal)"`, so every entry in
            // this dictionary has a sense keyed `"1.1"` — matching on the key alone took the first
            // entry containing one, which is the right sense of the wrong word, recorded as fact.
            // Where the answer named its entry, that entry. Where it did not, the key has to
            // identify one on its own — and a positional key cannot, so two entries holding
            // `"1.1"` is refused rather than resolved by position. Guessing here writes the right
            // sense of the wrong word into the ledger as a fact.
            let holders = mine.filter { candidate in
                guard entryID == nil || candidate.entryID == entryID else { return false }
                return candidate.senses.contains { $0.key == key }
            }
            guard holders.count == 1, let entry = holders.first,
                  // `SenseEncounter.of` is the panel's builder too, and it refuses a sense whose
                  // dictionary cannot key it. That guard used to be on the reader's tap alone, so
                  // the same sense was refused when tapped and recorded when guessed.
                  let encounter = SenseEncounter.of(entry, senseKey: key, chosenBy: .model, at: when)
            else {
                // The chosen key belongs to no entry XiaolaiDict can key — nothing is claimed.
                return SenseResolution(mark: nil, encounter: primary.encounter(among: entries, phrase: phraseEntries, at: when))
            }
            return SenseResolution(
                mark: .chosen(key: key, by: .model), encounter: encounter,
                owner: PanelSelection.identity(of: entry))
        case .abstained(let why, let nearest):
            // It says why it did not choose, and falls back to whatever *is* a fact — the entry,
            // when the primary answered with exactly one.
            // An abstention belongs to the primary's entry too: "could not tell" about *this*
            // dictionary is not a statement about the thesaurus's entry beside it.
            return SenseResolution(
                mark: .couldNot(why, nearest: nearest),
                encounter: primary.encounter(among: entries, phrase: phraseEntries, at: when),
                owner: mine.count == 1 ? mine.first.map { PanelSelection.identity(of: $0) } : nil)
        }
    }
}
