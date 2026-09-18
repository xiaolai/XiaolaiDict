import Foundation

/// How XiaolaiDict was asked to run.
enum LaunchMode: Equatable {
    /// The menu-bar app.
    case app
    /// `--lookup TERM [--repeat N] [--interval SECONDS]`: lookups through the real XPC path.
    case lookup(term: String, repeats: Int, interval: Duration)
    /// `--read-selection BUNDLE_ID`: what the reader would see from that app's selection.
    case readSelection(bundleID: String)
}

struct UsageError: Error, Equatable, CustomStringConvertible {
    let description: String
}

/// Parses the command line in order, strictly: a verification command that accepted a typo would
/// report success for something nobody asked for.
enum LaunchArguments {
    static let usage = """
        usage: XiaolaiDict                                              run the menu-bar app
               XiaolaiDict --lookup TERM [--repeat N] [--interval SECONDS]
               XiaolaiDict --read-selection BUNDLE_ID
        """

    static let repeatRange = 1...1_000
    static let intervalRange = 0.0...3_600.0

    /// Commands are XiaolaiDict's double-dash words; any other double-dash first argument is a mistyped
    /// command, refused rather than launching the app in its place. Single-dash arguments launch
    /// the app: LaunchServices and Xcode pass their own (`-psn_…`,
    /// `-NSDocumentRevisionsDebugMode YES`), and the app must not refuse them.
    static func parse(_ arguments: [String]) -> Result<LaunchMode, UsageError> {
        switch arguments.first {
        case "--lookup": lookup(Array(arguments.dropFirst()))
        case "--read-selection": readSelection(Array(arguments.dropFirst()))
        case let first? where first.hasPrefix("--"): fail("unknown command \(first)")
        default: .success(.app)
        }
    }

    private static func lookup(_ arguments: [String]) -> Result<LaunchMode, UsageError> {
        // The term is positional and comes first, so a term is never mistaken for an option.
        guard let term = arguments.first, !term.hasPrefix("--") else { return fail("--lookup needs a TERM") }
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail("the TERM is blank") }
        var repeats: Int?
        var interval: Double?
        var rest = arguments.dropFirst()
        while let option = rest.popFirst() {
            guard option == "--repeat" || option == "--interval" else { return fail("unknown option \(option)") }
            guard let value = rest.popFirst() else { return fail("\(option) needs a value") }
            switch option {
            case "--repeat":
                guard repeats == nil else { return fail("--repeat given twice") }
                guard let count = Int(value), repeatRange.contains(count) else {
                    return fail("--repeat needs a whole number from \(repeatRange.lowerBound) to \(repeatRange.upperBound), not \(value)")
                }
                repeats = count
            default:
                guard interval == nil else { return fail("--interval given twice") }
                guard let seconds = Double(value), intervalRange.contains(seconds) else {
                    return fail("--interval needs seconds from 0 to \(Int(intervalRange.upperBound)), not \(value)")
                }
                interval = seconds
            }
        }
        return .success(.lookup(term: term, repeats: repeats ?? 1, interval: .seconds(interval ?? 0)))
    }

    private static func readSelection(_ arguments: [String]) -> Result<LaunchMode, UsageError> {
        guard let bundleID = arguments.first, !bundleID.hasPrefix("--"),
              !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fail("--read-selection needs a BUNDLE_ID") }
        guard arguments.count == 1 else { return fail("unexpected \(arguments[1]) after the BUNDLE_ID") }
        return .success(.readSelection(bundleID: bundleID))
    }

    private static func fail(_ reason: String) -> Result<LaunchMode, UsageError> {
        .failure(UsageError(description: reason))
    }
}
