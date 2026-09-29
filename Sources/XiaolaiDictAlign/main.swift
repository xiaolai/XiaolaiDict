import AppleDictionaryFormat
import DictionaryIndex
import Foundation

// Aligns one dictionary's senses to another's, in the index `xdict-index` built.
//
// **A hub and a spoke, never a pair of pairs.** Align every dictionary to one hub and a three-way view is a
// join on the hub's sense key — `n − 1` alignments instead of `n(n−1)/2`, so the nine dictionaries on a Mac
// need eight runs rather than thirty-six, and any combination of them comes free afterwards. NOAD is the
// natural hub for the English-headword side of the catalogue: it is the only dictionary here whose senses are
// **100%** named by the publisher, so every pair anchored to it survives a re-master.
//
// **It settles about half and refuses the rest.** That is not a shortfall to be papered over; see
// `SenseAligner` for what was measured before it was written. A pair it cannot justify is left out, because a
// wrong alignment a reader cannot see is worse than a missing one — the same rule the key-mapping gate
// applies.

let usage = """
    xdict-align — align one dictionary's senses to another's, in an index xdict-index built

    USAGE
      xdict-align --hub <identifier> --spoke <identifier> [--index <path>] [--min <confidence>] [--dry-run]

    OPTIONS
      --hub <id>       The dictionary every alignment points at. A prefix is enough: `--hub NOAD`.
      --spoke <id>     The dictionary being aligned to the hub.
      --index <path>   Default: ~/Library/Application Support/XiaolaiDict/index.sqlite
      --min <0..1>     Discard pairs below this confidence. Default 0.0, which keeps every pair the
                       matcher was willing to claim at all — it has already refused what it could
                       not separate, and this is a second, stricter filter for a caller who wants one.
      --dry-run        Measure and report, write nothing.
      --help           This text.

    WHY A HUB
      Align each dictionary to one hub and a three-way view — English sense, its Chinese translation,
      its synonyms — is a join on the hub's sense key. Aligning every pair directly would be
      n(n-1)/2 runs and would still not agree with itself.

    EXIT
      0  the alignment ran
      1  the index does not hold what was asked for
      2  the arguments could not be read
    """

struct Options {
    var hub = ""
    var spoke = ""
    var index = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/XiaolaiDict/index.sqlite")
    var minimum = 0.0
    var dryRun = false
}

func parse(_ arguments: [String]) throws -> Options {
    struct Bad: Error, CustomStringConvertible { let description: String }
    var options = Options()
    var rest = arguments.dropFirst().makeIterator()
    while let argument = rest.next() {
        switch argument {
        case "--help", "-h": print(usage); exit(0)
        case "--hub":
            guard let v = rest.next() else { throw Bad(description: "--hub needs an identifier") }
            options.hub = v
        case "--spoke":
            guard let v = rest.next() else { throw Bad(description: "--spoke needs an identifier") }
            options.spoke = v
        case "--index":
            guard let v = rest.next() else { throw Bad(description: "--index needs a path") }
            options.index = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
        case "--min":
            guard let v = rest.next(), let d = Double(v), d >= 0, d <= 1 else {
                throw Bad(description: "--min needs a confidence between 0 and 1")
            }
            options.minimum = d
        case "--dry-run": options.dryRun = true
        default: throw Bad(description: "unknown argument: \(argument)")
        }
    }
    guard !options.hub.isEmpty, !options.spoke.isEmpty else {
        throw Bad(description: "--hub and --spoke are both required")
    }
    guard options.hub != options.spoke else {
        throw Bad(description: "a dictionary cannot be aligned to itself")
    }
    return options
}

let options: Options
do {
    options = try parse(CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("xdict-align: \(error)\n\n\(usage)\n".utf8))
    exit(2)
}

do {
    guard FileManager.default.fileExists(atPath: options.index.path) else {
        FileHandle.standardError.write(Data("""
            xdict-align: no index at \(options.index.path)
            Build one first:  swift run XiaolaiDictIndex\n
            """.utf8))
        exit(1)
    }
    let store = try IndexStore(path: options.index.path)
    let indexed = try store.dictionaries().map(\.identifier)

    /// A prefix is enough, as it is for `xdict-index`, but an ambiguous one is an error rather than a guess.
    func resolve(_ wanted: String, _ role: String) throws -> String {
        let matches = indexed.filter { $0.localizedCaseInsensitiveContains(wanted) }
        guard !matches.isEmpty else {
            FileHandle.standardError.write(Data("""
                xdict-align: no indexed dictionary matches \(role) `\(wanted)`. The index holds:
                \(indexed.map { "  " + $0 }.joined(separator: "\n"))\n
                """.utf8))
            exit(1)
        }
        guard matches.count == 1 else {
            FileHandle.standardError.write(Data("""
                xdict-align: \(role) `\(wanted)` matches \(matches.count) dictionaries: \
                \(matches.joined(separator: ", "))\n
                """.utf8))
            exit(2)
        }
        return matches[0]
    }
    let hub = try resolve(options.hub, "--hub")
    let spoke = try resolve(options.spoke, "--spoke")

    let pairsOfEntries = try store.entryPairs(hub: hub, spoke: spoke)
    let hubByEntry = try store.sensesByEntry(in: hub)
    let spokeByEntry = try store.sensesByEntry(in: spoke)
    // The publisher's own inflections, so `held` is excluded along with `hold`.
    let hubInflections = try store.inflectionsByEntry(in: hub)
    let spokeInflections = try store.inflectionsByEntry(in: spoke)

    // Every hub entry a spoke entry is joined to. One entry carries several anchors — a `prlexid` per
    // pronunciation — so the pairs are collapsed here rather than iterated once per anchor.
    var hubEntriesForSpoke: [String: Set<String>] = [:]
    for pair in pairsOfEntries {
        hubEntriesForSpoke[pair.spoke, default: []].insert(pair.hub)
    }

    print("""
        xdict-align: \(spoke) → \(hub)
          \(try store.anchorCount(in: hub)) anchors on the hub, \
        \(try store.anchorCount(in: spoke)) on the spoke
          \(hubEntriesForSpoke.count) spoke entries joined to a hub entry, \
        over \(pairsOfEntries.count) entry pairs
        """)
    guard !hubEntriesForSpoke.isEmpty else {
        FileHandle.standardError.write(Data("""
            xdict-align: these two share no anchor, so there is no exact join between them.
            Only NOAD and 牛津英汉汉英 carry Oxford's `prlexid` among the dictionaries measured; the others
            would need a headword join, which cannot separate homographs and is not what this writes.\n
            """.utf8))
        exit(1)
    }

    // The weighting is built from the hub's senses, which is the population a spoke sense is scored against.
    let weighting = SenseAligner.Weighting(documents: hubByEntry.flatMap { entry, senses in
        let about = SenseAligner.terms(senses.first?.headword ?? "")
            .union(hubInflections[entry] ?? [])
        return senses.map { SenseAligner.terms($0.matchableText, about: about) }
    })
    let aligner = SenseAligner(weighting: weighting)

    var matched = 0, tooClose = 0, nothingShared = 0, noCandidate = 0
    var noMaterial = 0, belowMinimum = 0
    // How many distinct words each claimed pair rests on, because a pair resting on two is a different claim
    // from one resting on six and the score alone does not say which it is.
    var restingOn: [Int: Int] = [:]
    var pairs: [(IndexStore.AlignableSense, IndexStore.AlignableSense, Double)] = []
    for (spokeEntry, hubEntries) in hubEntriesForSpoke.sorted(by: { $0.key < $1.key }) {
        // Every candidate at once, from every hub entry this spoke entry is joined to.
        var hubSenses: [IndexStore.AlignableSense] = []
        var seenKeys = Set<String>()
        for hubEntry in hubEntries.sorted() {
            for sense in hubByEntry[hubEntry] ?? [] where seenKeys.insert(sense.senseKey).inserted {
                hubSenses.append(sense)
            }
        }
        for spokeSense in spokeByEntry[spokeEntry] ?? [] {
            // **Scope first, then granularity — they are different filters and conflating them was wrong.**
            //
            // Scope: a main sense and a phrasal verb's sense are not alternatives. With NOAD's idioms left in
            // the candidate set, every one of `hold`'s pairs came out wrong — 抓地 against "approve of
            // something", which is *hold with*.
            //
            // Granularity: among the senses that are in scope, a parent's text is the join of its children's,
            // so its overlap is a superset of theirs and it wins every comparison. Dropping a parent *that
            // has children* is what lets the right subsense be chosen — but dropping every parent removed
            // `hold`'s main senses altogether, because those are the ones with subsenses.
            // The word both entries are about, in every form either dictionary indexes it under.
            var about = SenseAligner.terms(spokeSense.headword)
                .union(hubSenses.first.map { SenseAligner.terms($0.headword) } ?? [])
            for hubEntry in hubEntries { about.formUnion(hubInflections[hubEntry] ?? []) }
            about.formUnion(spokeInflections[spokeEntry] ?? [])
            let inScope = hubSenses.filter { $0.subEntry == spokeSense.subEntry }
            let candidates = inScope.filter { !$0.hasSubsenses }.map {
                SenseAligner.Candidate(senseKey: $0.senseKey, partOfSpeech: $0.partOfSpeech,
                                       terms: SenseAligner.terms($0.matchableText, about: about))
            }
            // The spoke's own definition may be in another language; its examples are the shared material.
            let terms = SenseAligner.terms(spokeSense.examples.joined(separator: " "), about: about)
            switch aligner.match(spoke: terms, partOfSpeech: spokeSense.partOfSpeech,
                                 against: candidates) {
            case .matched(let key, let confidence, let sharedTerms):
                guard confidence >= options.minimum else { belowMinimum += 1; continue }
                guard let hubSense = inScope.first(where: { $0.senseKey == key }) else { continue }
                matched += 1
                restingOn[min(sharedTerms, 6), default: 0] += 1
                pairs.append((hubSense, spokeSense, confidence))
            case .tooClose: tooClose += 1
            case .nothingShared: nothingShared += 1
            case .noCandidate: noCandidate += 1
            case .noMaterial: noMaterial += 1
            }
        }
    }

    let assessed = matched + tooClose + nothingShared + noCandidate + noMaterial + belowMinimum
    let withMaterial = assessed - noMaterial
    func ofMaterial(_ n: Int) -> String {
        String(format: "%5.1f%%", withMaterial > 0 ? 100 * Double(n) / Double(withMaterial) : 0)
    }
    // **Two denominators, because they answer different questions.** `assessed` counts every sense of the
    // spoke; most of them print no example and so offer this method nothing to work with, which is a fact
    // about the dictionary. The percentages are of the senses that *did* carry material, which is the only
    // population the matcher can be judged on.
    print("""

          \(assessed) spoke senses, of which \(noMaterial) print no example \
        (\(String(format: "%.1f%%", assessed > 0 ? 100 * Double(noMaterial) / Double(assessed) : 0)))
          \(withMaterial) had material to match, and of those:
            aligned            \(matched)  \(ofMaterial(matched))
            too close to call  \(tooClose)  \(ofMaterial(tooClose))
            nothing shared     \(nothingShared)  \(ofMaterial(nothingShared))
            no candidate       \(noCandidate)  \(ofMaterial(noCandidate))
          words each pair rests on: \(restingOn.sorted { $0.key < $1.key }
              .map { "\($0.key)\($0.key == 6 ? "+" : ""): \($0.value)" }.joined(separator: "  "))\
        \(belowMinimum > 0 ? "\n    below --min        \(belowMinimum)  \(ofMaterial(belowMinimum))" : "")
        """)

    guard !options.dryRun else {
        print("\n  --dry-run: nothing written.")
        exit(0)
    }
    // Replaced rather than added to, for the reason a rebuild replaces: a second run must not leave the first
    // run's pairs beside its own.
    try store.inTransaction {
        try store.forgetAlignment(hub: hub, spoke: spoke)
        for (hubSense, spokeSense, confidence) in pairs {
            try store.insertAlignment(hub: (hub, hubSense), spoke: (spoke, spokeSense),
                                      confidence: confidence, method: SenseAligner.method)
        }
    }
    print("\n  wrote \(try store.alignmentCount(hub: hub, spoke: spoke)) pairs, method \(SenseAligner.method)")
    exit(0)
} catch {
    FileHandle.standardError.write(Data("xdict-align: \(error)\n".utf8))
    exit(1)
}
