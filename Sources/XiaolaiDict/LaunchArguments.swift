import Foundation

/// How XiaolaiDict was asked to run.
enum LaunchMode: Equatable {
    /// The menu-bar app.
    case app
    /// `--lookup TERM [--repeat N] [--interval SECONDS]`: lookups through the real XPC path.
    case lookup(term: String, repeats: Int, interval: Duration)
    /// `--read-selection BUNDLE_ID`: what the reader would see from that app's selection.
    case readSelection(bundleID: String)
    /// `--read-point X Y`: the word under a screen point, through the hover paths. The
    /// verification hook for the three Accessibility dialects and the recogniser, without moving
    /// anyone's pointer.
    case readPoint(x: Double, y: Double)
    /// `--speech-report`: the voices this **bundle** actually has, and whether it can synthesise
    /// with them. Only meaningful inside the signed bundle — a bare CLI binary is not a valid
    /// instrument for this API, which is the whole reason Spike S1 exists.
    case speechReport
    /// `--translation-report`: whether this **bundle** can actually translate, not whether an
    /// availability API says it could. Same reason as `--speech-report`: a status that reports
    /// `available` and then fails on a signing-policy check has happened here before.
    case translationReport

    /// Whether the history drawer appears, docked as asked, without activating the app. Only a
    /// running bundle can answer the last part.
    case historyReport

    /// `--settings-report`: whether the settings window is the size of the pane it shows, and
    /// moves between the sizes rather than jumping. A resize can only be watched where one
    /// happens, which is inside a running app.
    case settingsReport

    /// `--model-status`: whether the bundled model service runs, and whether it can run MLX — one op
    /// evaluated on its GPU. Only the signed bundle can answer.
    case modelStatus
    /// `--model-report`: the local model end to end — downloaded from ModelScope into the store if
    /// it is not there, then a sense answer and a translation through the service.
    case modelReport
    /// `--sense-report`: every rung of the sense ladder scored on the labelled set, in the bundle.
    case senseReport
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
               XiaolaiDict --read-point X Y
               XiaolaiDict --speech-report
               XiaolaiDict --translation-report
               XiaolaiDict --history-report
               XiaolaiDict --settings-report
               XiaolaiDict --model-status
               XiaolaiDict --model-report
               XiaolaiDict --sense-report
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
        case "--read-point": readPoint(Array(arguments.dropFirst()))
        case "--speech-report": alone(arguments, is: .speechReport)
        case "--translation-report": alone(arguments, is: .translationReport)
        case "--history-report": alone(arguments, is: .historyReport)
        case "--settings-report": alone(arguments, is: .settingsReport)
        case "--model-status": alone(arguments, is: .modelStatus)
        case "--model-report": alone(arguments, is: .modelReport)
        case "--sense-report": alone(arguments, is: .senseReport)
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

    private static func readPoint(_ arguments: [String]) -> Result<LaunchMode, UsageError> {
        guard arguments.count == 2 else { return fail("--read-point needs X and Y") }
        guard let x = Double(arguments[0]), let y = Double(arguments[1]), x.isFinite, y.isFinite else {
            return fail("--read-point needs two numbers, not \(arguments.joined(separator: " "))")
        }
        return .success(.readPoint(x: x, y: y))
    }

    private static func readSelection(_ arguments: [String]) -> Result<LaunchMode, UsageError> {
        guard let bundleID = arguments.first, !bundleID.hasPrefix("--"),
              !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fail("--read-selection needs a BUNDLE_ID") }
        guard arguments.count == 1 else { return fail("unexpected \(arguments[1]) after the BUNDLE_ID") }
        return .success(.readSelection(bundleID: bundleID))
    }

    /// A command that takes nothing after it. One copy of the check, where there were four — each
    /// naming its own command in its own error message, one typo away from naming another's.
    private static func alone(_ arguments: [String], is mode: LaunchMode) -> Result<LaunchMode, UsageError> {
        arguments.count == 1 ? .success(mode) : fail("unexpected \(arguments[1]) after \(arguments[0])")
    }

    private static func fail(_ reason: String) -> Result<LaunchMode, UsageError> {
        .failure(UsageError(description: reason))
    }
}
