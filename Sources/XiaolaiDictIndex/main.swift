import AppleDictionaryFormat
import DictionaryIndex
import Foundation

// Builds the local index from the dictionaries Apple already put on this Mac.
//
// **Why a command and not a button.** The index is derived from dictionaries licensed to *this* reader, so
// it is built here and never shipped — which means somebody has to be able to run the build, watch it, and
// read why a dictionary was refused. A progress bar inside the app would hide all three.
//
// It does nothing clever. Every judgement it makes was measured somewhere else: which depth delimits a
// sense (`DictionaryProfile`), what counts as a definition (`marksDefinition`), whether a key mapping can be
// trusted (`KeyResolutionReport.confidence`), and what a durable sense name is (`SenseKey`). This walks the
// installed set, applies them, and reports.

let usage = """
    xdict-index — build the local sense index from the dictionaries installed on this Mac

    USAGE
      xdict-index [--index <path>] [--only <identifier>]... [--force] [--quiet]

    OPTIONS
      --index <path>   Where to write the index.
                       Default: ~/Library/Application Support/XiaolaiDict/index.sqlite
      --only <id>      Restrict to one dictionary, by CFBundleIdentifier. Repeatable.
                       A prefix is enough: `--only NOAD` matches com.apple.dictionary.NOAD.
      --reader <tag>   Build for a reader of this language rather than this Mac's own, e.g.
                       `--reader zh-Hant-TW`, `--reader yue-Hant-HK`. Decides which bilingual
                       dictionary is included; the English monolinguals are in every audience.
      --all            Ignore the audience and index everything readable. Larger, slower, and it
                       puts dictionaries in the index the reader cannot read.
      --force          Discard what was built from each selected dictionary and rebuild it,
                       even when nothing about it has changed.
      --quiet          Print the per-dictionary result only, without progress.
      --help           This text.

    WHOSE INDEX THIS IS
      Simplified Chinese, Traditional Chinese and Cantonese are three audiences, each wanting its
      own bilingual dictionary — a Cantonese reader wants Cantonese glosses, not Mandarin written
      in Traditional characters. Only this reader's audience is indexed by default. Measured: 82 s
      and 319 MB scoped against 216 s and 478 MB for everything, and adding an audience later costs
      only its own dictionaries, because a rebuild is per-dictionary.

    WHAT IT REFUSES, AND WHY THAT IS THE POINT
      A dictionary whose key mapping cannot be certified is skipped with a reason rather than
      indexed quietly. An uncertified mapping that turns out wrong is worse than a missing one,
      because a reader cannot see it. The reason names the score and the bar it missed.

    EXIT
      0  at least one dictionary is indexed and usable
      1  nothing usable was produced
      2  the arguments could not be read
    """

// MARK: - Arguments

struct Options {
    var index: URL
    var only: [String] = []
    var force = false
    var quiet = false
    /// Whose index this is. Defaults to the reader's own language; `--all` sets it nil.
    // Spelled here rather than read from `ReaderLanguage`: this tool links `AppleDictionaryFormat` alone,
    // and pulling `DictionaryModel` in for one accessor would widen an instrument's dependencies to
    // narrow a duplication. Two spellings, and this is the one that is a command's default flag value.
    var reader: String? = Locale.preferredLanguages.first ?? "en"
}

/// `IndexStore.defaultURL`, not a second copy of the path: the dictionary service reads this same file to
/// build its phrase inventory, and two spellings would drift the day one of them moved.
let defaultIndex = IndexStore.defaultURL

func parse(_ arguments: [String]) throws -> Options {
    struct Bad: Error, CustomStringConvertible {
        let description: String
    }
    var options = Options(index: defaultIndex)
    var rest = arguments.dropFirst().makeIterator()
    while let argument = rest.next() {
        switch argument {
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--index":
            guard let path = rest.next() else { throw Bad(description: "--index needs a path") }
            options.index = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        case "--only":
            guard let identifier = rest.next() else {
                throw Bad(description: "--only needs a dictionary identifier")
            }
            options.only.append(identifier)
        case "--reader":
            guard let tag = rest.next() else { throw Bad(description: "--reader needs a language tag") }
            options.reader = tag
        case "--all":
            options.reader = nil
        case "--force": options.force = true
        case "--quiet": options.quiet = true
        default:
            throw Bad(description: "unknown argument: \(argument)")
        }
    }
    return options
}

let options: Options
do {
    options = try parse(CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("xdict-index: \(error)\n\n\(usage)\n".utf8))
    exit(2)
}

// MARK: - The dictionaries to build from

let installed = DictionaryLocator.installed()
guard !installed.isEmpty else {
    FileHandle.standardError.write(Data("""
        xdict-index: no .dictionary bundle was found. macOS keeps them under
          /System/Library/AssetsV2/com_apple_MobileAsset_DictionaryServices_dictionary3macOS
          /Library/Dictionaries, ~/Library/Dictionaries
        A bundle whose Info.plist names no CFBundleIdentifier is skipped, because a rebuild needs a
        stable key and inventing one would produce rows that change on the next run.\n
        """.utf8))
    exit(1)
}

// **The audience first, then `--only` within it.** `--only` is for working on one dictionary, so it
// must not quietly widen the set past the reader it is building for.
let forAudience = options.reader.map { reader in installed.filter { $0.serves(reader: reader) } } ?? installed
let selected = options.only.isEmpty ? forAudience : forAudience.filter { bundle in
    options.only.contains { bundle.identifier.localizedCaseInsensitiveContains($0) }
}
guard !selected.isEmpty else {
    if options.only.isEmpty, let reader = options.reader {
        FileHandle.standardError.write(Data("""
            xdict-index: no installed dictionary serves a reader of \(reader). One qualifies by indexing
            English and explaining it either in English or in that reader's own language and script — so a
            Chinese-Chinese dictionary never does, and 譯典通 does not serve a reader of Simplified Chinese.
            Enable one in Dictionary, under Settings, or pass --all.
            """.utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("""
        xdict-index: --only matched nothing. Installed identifiers:
        \(installed.map { "  " + $0.identifier }.joined(separator: "\n"))\n
        """.utf8))
    exit(2)
}

// MARK: - Build

do {
    try FileManager.default.createDirectory(
        at: options.index.deletingLastPathComponent(), withIntermediateDirectories: true)
    let store = try IndexStore(path: options.index.path)
    let rebuilder = IndexRebuilder(store: store)

    if options.force {
        // Discarding is how a rebuild is forced: `needsRebuild` then has nothing to compare against.
        // Expressed through the store's own API rather than a flag on the driver, because "throw this
        // dictionary away" is a thing a caller may legitimately want on its own.
        for bundle in selected { try store.forget(bundle.identifier) }
    }

    let whose = options.reader.map { "for a reader of \($0)" } ?? "for every audience (--all)"
    print("xdict-index: \(selected.count) of \(installed.count) installed, \(whose) → \(options.index.path)")
    var lastStage: String?
    let outcomes = rebuilder.rebuild(selected) { progress in
        guard !options.quiet else { return }
        // One line per stage change, and a count while writing. A dictionary's body is walked three times
        // before a single row is written, so silence here reads as a hang.
        let stage = "\(progress.identifier)/\(progress.stage.rawValue)"
        if progress.stage == .writing {
            print("  \(progress.displayName): \(progress.entriesWritten) entries…")
        } else if stage != lastStage {
            print("  \(progress.displayName): \(progress.stage.rawValue)…")
        }
        lastStage = stage
    }

    print("")
    for outcome in outcomes { print("  " + outcome.summary) }

    let rebuilt = outcomes.filter(\.wasRebuilt).count
    let refused = outcomes.filter(\.wasRefused).count
    let current = outcomes.count - rebuilt - refused
    let senses = try store.dictionaries().reduce(0) { $0 + (try store.senseCount(in: $1.identifier)) }
    print("""

        \(rebuilt) rebuilt, \(current) already current, \(refused) refused.
        The index holds \(senses) senses from \(try store.dictionaries().count) dictionaries.
        """)
    // Refusals are a normal outcome and not a failure — a dictionary whose mapping cannot be certified is
    // *meant* to be skipped. Producing nothing usable at all is the failure.
    exit(try store.dictionaries().isEmpty ? 1 : 0)
} catch {
    FileHandle.standardError.write(Data("xdict-index: \(error)\n".utf8))
    exit(1)
}
