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
