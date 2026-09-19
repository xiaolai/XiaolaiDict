import Testing
@testable import XiaolaiDict

/// Spike: whether a **Developer ID-signed bundle** can actually translate, not whether an
/// availability API says it could. The precedent is `PrivateCloudComputeLanguageModel`, which
/// reported `available` on this machine and then failed every request in ~10 ms on a signing
/// policy check (`macos-27-platform-facts.md`).
struct TranslationReportArgumentTests {
    @Test func theReportIsACommand() {
        #expect(LaunchArguments.parse(["--translation-report"]) == .success(.translationReport))
    }

    @Test func itTakesNoArguments() {
        #expect(throws: (any Error).self) {
            try LaunchArguments.parse(["--translation-report", "extra"]).get()
        }
    }

    /// Bounded: the reader's languages, not all 21.
    @Test func theProbeIsBoundedAndCoversTheReadersPairs() {
        let pairs = TranslationReport.pairs
        #expect(pairs.count <= 4)
        #expect(pairs.contains { $0.source == "en" && $0.target == "zh-Hans" })
    }
}

/// The honesty check, and the whole point of running inside the bundle: a translator that echoes
/// its input, or returns nothing, looks exactly like one that worked. This is the analogue of
/// `SpeechReport` counting frames rather than trusting that `speak` returned quietly.
struct TranslationVerdictTests {
    @Test func realTranslationIsAcceptedAsSuccess() {
        #expect(TranslationReport.isRealTranslation(source: "The ship's hold was full.",
                                                    target: "船舱是满的。"))
    }

    @Test func emptyOutputIsNotSuccess() {
        #expect(!TranslationReport.isRealTranslation(source: "The ship's hold was full.", target: ""))
        #expect(!TranslationReport.isRealTranslation(source: "The ship's hold was full.", target: "   \n "))
    }

    /// An echo is the failure that reads as success.
    @Test func echoingTheInputIsNotSuccess() {
        #expect(!TranslationReport.isRealTranslation(source: "The ship's hold was full.",
                                                     target: "The ship's hold was full."))
        #expect(!TranslationReport.isRealTranslation(source: "The ship's hold was full.",
                                                     target: "  the ship's HOLD was full.  "))
    }
}

/// The instrument has to probe each pair in the language that pair actually reads.
///
/// Measured 2026-09-20 on the E2E machine: zh-Hans→en reported `installed` and came back with
/// "The ship's hold was full." — because the probe had handed a **zh→en** translator an English
/// sentence. The echo guard correctly refused to call that a success, but the reading was
/// meaningless: a non-English pair fed English can never do anything except echo.
struct TranslationSampleTests {
    @Test func eachPairIsProbedInItsOwnSourceLanguage() {
        for pair in TranslationReport.pairs {
            let han = pair.sample.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            if pair.source.hasPrefix("zh") {
                #expect(han, "\(pair.source)→\(pair.target) is probed with \"\(pair.sample)\"")
            } else {
                #expect(!han, "\(pair.source)→\(pair.target) is probed with \"\(pair.sample)\"")
            }
        }
    }
}
