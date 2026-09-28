import AppleDictionaryFormat
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
      --force          Discard what was built from each selected dictionary and rebuild it,
                       even when nothing about it has changed.
      --quiet          Print the per-dictionary result only, without progress.
      --help           This text.

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
}

/// The default lives in Application Support rather than Caches. The index *is* derived data and can always
/// be rebuilt, which argues for Caches — but rebuilding the catalogue is minutes of work, and a reader who
/// loses it to a routine cache purge has lost their study history's names with it.
let defaultIndex = FileManager.default
    .homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/XiaolaiDict/index.sqlite")

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

let selected = options.only.isEmpty ? installed : installed.filter { bundle in
    options.only.contains { bundle.identifier.localizedCaseInsensitiveContains($0) }
}
guard !selected.isEmpty else {
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

    print("xdict-index: \(selected.count) of \(installed.count) installed dictionaries → \(options.index.path)")
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
