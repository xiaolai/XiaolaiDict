import Foundation
import Testing
@testable import XiaolaiDict
import XiaolaiDictCore

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
///
/// **The rule is `TranslationCheck`'s, and the report has none of its own.** It used to carry a
/// copy, which fell behind: byte-identical normalisation, but no quotation-mark trimming and no
/// refusal of an answer still in the source language — the two failures the shipped path had
/// already met and been taught to refuse. So the "real" column graded Apple's translator by a
/// weaker rule than the pane applies, and would have passed exactly what the reader is shown a
/// fallback for. The cases below are the report's verdict, which is to say the pane's.
struct TranslationReportVerdictTests {
    /// The report's own English probe, so these are the sentences the instrument grades and not a
    /// convenient stand-in for them.
    private static let source = TranslationReport.english

    /// The report names the language it asked for, so the check can refuse an answer that came
    /// back in the language it started in. Dropped, the copy could only ever compare two strings.
    private static func isReal(
        _ target: String, of source: String = TranslationReportVerdictTests.source,
        into language: String = "zh-Hans"
    ) -> Bool {
        TranslationCheck.isTranslation(target, of: source, into: language)
    }

    @Test func realTranslationIsAcceptedAsSuccess() {
        #expect(Self.isReal("船舱是满的。"))
    }

    @Test func emptyOutputIsNotSuccess() {
        #expect(!Self.isReal(""))
        #expect(!Self.isReal("   \n "))
    }

    /// An echo is the failure that reads as success.
    @Test func echoingTheInputIsNotSuccess() {
        #expect(!Self.isReal(Self.source))
        #expect(!Self.isReal("  the ship's HOLD was full.  "))
    }

    /// **A quoted echo is still an echo.** Both sides are unwrapped the same way, so a translator
    /// that hands the sentence back inside quotation marks — which a model asked for a translation
    /// does — is caught rather than counted. The copy compared the quoted answer against an
    /// unquoted source and called them different.
    @Test(arguments: [("\"", "\""), ("“", "”"), ("「", "」")])
    func aQuotedEchoIsNotSuccess(opening: String, closing: String) {
        #expect(!Self.isReal(opening + Self.source + closing))
    }

    /// **And an answer still in the source's language is not a translation**, however unlike the
    /// input it reads. A paraphrase is not word-for-word the sentence it came from, so the copy's
    /// string comparison passed it — and the column said Apple had translated a sentence it had
    /// merely restated.
    @Test func anAnswerStillInTheSourceLanguageIsNotSuccess() {
        #expect(!Self.isReal("The cargo space of the ship was completely full."))
    }
}

/// **The wire, not the value.** The verdict above is only the report's if the report asks for it:
/// the copy this replaced passed every test it had while the "real" column went on being decided
/// by a weaker rule. What can fail is the call itself, so the call is what is read — including
/// `into:`, without which the source-language refusal above is unreachable from here.
///
/// Mechanical because a behavioural check cannot run: `TranslationReport.run` needs the Translation
/// framework, a downloaded language pack per pair, and the signed bundle around it.
struct TranslationReportWiringTests {
    @Test func theReportGradesByTheShippedCheck() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDict/TranslationReport.swift")
        // Whitespace removed rather than matched, so the assertion is about the call and its
        // arguments and not about where the line was wrapped.
        let code = try String(contentsOf: file, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined()
        #expect(code.contains("TranslationCheck.isTranslation(response.targetText,of:pair.sample,into:pair.target)"),
                "the report does not grade its \"real\" column with the shipped check, told which language it asked for")
        #expect(!code.contains("funcnormalised"),
                "the report has a verdict helper of its own again, which is what drifted")
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
