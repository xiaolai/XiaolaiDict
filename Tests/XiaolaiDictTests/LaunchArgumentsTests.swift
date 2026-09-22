import AVFoundation
@testable import XiaolaiDict
import Testing

/// The command line is parsed in order and strictly: a verification command that accepted a typo
/// would report success for something nobody asked for.
struct LaunchArgumentsTests {
    private func parse(_ arguments: String...) -> Result<LaunchMode, UsageError> {
        LaunchArguments.parse(arguments)
    }

    private func refused(_ arguments: String...) -> Bool {
        if case .failure = LaunchArguments.parse(arguments) { return true }
        return false
    }

    @Test func noArgumentsRunTheApp() {
        #expect(LaunchArguments.parse([]) == .success(.app))
    }

    /// LaunchServices and Xcode pass arguments of their own; the app must still launch.
    @Test func argumentsTheSystemPassesStillRunTheApp() {
        #expect(parse("-psn_0_12345") == .success(.app))
        #expect(parse("-NSDocumentRevisionsDebugMode", "YES") == .success(.app))
    }

    @Test func aLookupWithDefaults() {
        #expect(parse("--lookup", "ephemeral") == .success(.lookup(term: "ephemeral", repeats: 1, interval: .zero)))
    }

    @Test func aLookupWithOptionsInEitherOrder() {
        let expected = LaunchMode.lookup(term: "ephemeral", repeats: 3, interval: .seconds(1.5))
        #expect(parse("--lookup", "ephemeral", "--repeat", "3", "--interval", "1.5") == .success(expected))
        #expect(parse("--lookup", "ephemeral", "--interval", "1.5", "--repeat", "3") == .success(expected))
    }

    @Test func readSelection() {
        #expect(parse("--read-selection", "com.apple.TextEdit") == .success(.readSelection(bundleID: "com.apple.TextEdit")))
    }

    /// Found by audit: an option with its value missing indexed past the end of the arguments and
    /// crashed.
    @Test func anOptionWithoutItsValueIsRefusedNotACrash() {
        #expect(refused("--lookup", "ephemeral", "--repeat"))
        #expect(refused("--lookup", "ephemeral", "--interval"))
    }

    /// A command without its operand used to fall through and launch the menu-bar app — a
    /// long-running process where a script expected an answer.
    @Test func aCommandWithoutItsOperandIsRefused() {
        #expect(refused("--lookup"))
        #expect(refused("--read-selection"))
        #expect(refused("--lookup", "  "))
        #expect(refused("--lookup", "--repeat", "3"))
        #expect(refused("--read-selection", "--lookup"))
    }

    @Test(arguments: [
        ["--repeat", "0"], ["--repeat", "-2"], ["--repeat", "three"], ["--repeat", "1001"],
        ["--interval", "-1"], ["--interval", "nan"], ["--interval", "inf"], ["--interval", "3601"],
        ["--repeat", "2", "--repeat", "3"], ["--interval", "1", "--interval", "2"],
        ["--verbose"], ["--repeat", "2", "extra"],
    ])
    func badOptionsAreRefused(options: [String]) {
        #expect(refused(of: ["--lookup", "ephemeral"] + options))
    }

    /// Found by the verifier: a mistyped command launched the menu-bar app in its place.
    @Test func aMistypedCommandIsRefused() {
        #expect(refused("--lokup", "ephemeral"))
        #expect(refused("--help"))
    }

    @Test func extraArgumentsAfterABundleIDAreRefused() {
        #expect(refused("--read-selection", "com.apple.TextEdit", "com.apple.Safari"))
    }

    private func refused(of arguments: [String]) -> Bool {
        if case .failure = LaunchArguments.parse(arguments) { return true }
        return false
    }
}

/// Spike S1's instrument has to be reachable, and reachable only as written.
struct SpeechReportArgumentTests {
    @Test func theReportIsACommand() {
        #expect(LaunchArguments.parse(["--speech-report"]) == .success(.speechReport))
    }

    @Test func itTakesNoArguments() {
        #expect(throws: (any Error).self) {
            try LaunchArguments.parse(["--speech-report", "extra"]).get()
        }
    }

    /// One voice per quality, plus Siri — enough to answer the question without synthesising 180
    /// times.
    @Test func theProbeIsBoundedAndCoversEachQuality() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let probes = SpeechReport.probes(among: voices)
        #expect(probes.count <= 4)
        #expect(Set(probes.map(\.identifier)).count == probes.count, "a voice was probed twice")
        for probe in probes { #expect(voices.contains { $0.identifier == probe.identifier }) }
    }
}

/// The hover instrument's command line. A verification command that accepted a typo would report
/// success for something nobody asked for.
struct ReadPointArgumentTests {
    @Test func aPointIsParsed() {
        #expect(LaunchArguments.parse(["--read-point", "120", "340.5"]) == .success(.readPoint(x: 120, y: 340.5)))
        #expect(LaunchArguments.parse(["--read-point", "-5", "0"]) == .success(.readPoint(x: -5, y: 0)))
    }

    @Test(arguments: [["--read-point"], ["--read-point", "120"],
                      ["--read-point", "120", "340", "extra"],
                      ["--read-point", "x", "340"], ["--read-point", "120", "nan"]])
    func anythingElseIsRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { try LaunchArguments.parse(arguments).get() }
    }
}

/// **Every command XiaolaiDict answers to is in the usage text, and every command in the usage text
/// works.** Two halves of one rule, asserted mechanically rather than by remembering.
///
/// Written when `--settings-report` was added, because the three instruments before it went in
/// with no coverage of this shape at all — a command wired but undocumented is one nobody can find,
/// and a command documented but unwired sends a reader to "unknown command". Both had to be caught
/// by reading the file, which is exactly the check a test can do every time instead.
struct CommandCoverageTests {
    /// The parser's own source, which is where the truth about what it accepts lives.
    private var parserSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDict/LaunchArguments.swift")
    }

    /// The double-dash words in the usage text, excluding the bracketed options of a command.
    private var documented: Set<String> {
        Set(LaunchArguments.usage
            .split(separator: "\n")
            .compactMap { line in
                line.split(separator: " ").first { $0.hasPrefix("--") }.map(String.init)
            })
    }

    @Test func everyDocumentedCommandIsAccepted() throws {
        let commands = documented
        // A pattern that matched nothing would pass every assertion below on an empty set, which
        // is the vacuous green this project has been bitten by before.
        #expect(commands.count >= 6, "the usage text parsed as \(commands.sorted())")
        for command in commands {
            // Some need arguments; what must never happen is the parser not knowing the word.
            if case .failure(let error) = LaunchArguments.parse([command]) {
                #expect(!error.description.contains("unknown command"),
                        "\(command) is in the usage text and the parser does not know it")
            }
        }
    }

    /// **Each command answers to its own name.** The two tests above ask only whether the parser
    /// knows the word and whether the usage text lists it — `--model-status` wired to `.modelReport`
    /// passes both, and a reader asking what is installed gets a model loaded and timed instead.
    /// The mapping is therefore asserted one command at a time, by name.
    ///
    /// Every command here is a whole command: it takes no operand, so anything after it was
    /// mistyped and is refused rather than ignored.
    @Test(arguments: [
        ("--speech-report", LaunchMode.speechReport),
        ("--translation-report", LaunchMode.translationReport),
        ("--history-report", LaunchMode.historyReport),
        ("--settings-report", LaunchMode.settingsReport),
        ("--model-status", LaunchMode.modelStatus),
        ("--model-report", LaunchMode.modelReport),
        ("--sense-report", LaunchMode.senseReport),
    ])
    func aCommandParsesToItsOwnModeAndTakesNothingElse(command: String, mode: LaunchMode) {
        #expect(LaunchArguments.parse([command]) == .success(mode))
        if case .success(let parsed) = LaunchArguments.parse([command, "extra"]) {
            Issue.record("\(command) accepted an argument and parsed as \(parsed)")
        }
    }

    @Test func everyAcceptedCommandIsDocumented() throws {
        let source = try String(contentsOf: parserSource, encoding: .utf8)
        // The command switch alone. Scanning the whole file also found `--repeat` and `--interval`
        // — options of `--lookup`, which are documented inside its own usage line and are not
        // commands. A scanner that cannot tell those apart reports a gap that is not there.
        let start = try #require(source.range(of: "switch arguments.first {"))
        let end = try #require(source.range(of: "default: .success(.app)"))
        let commandSwitch = source[start.upperBound..<end.lowerBound]
        let cases = commandSwitch.split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("case \"--") else { return nil }
                return trimmed.split(separator: "\"").dropFirst().first.map(String.init)
            }
        #expect(cases.count >= 6, "the parser's cases read as \(cases.sorted())")
        let documented = documented
        for command in cases {
            #expect(documented.contains(command), "\(command) is a command and the usage text omits it")
        }
    }
}
