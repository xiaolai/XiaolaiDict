import Foundation
import XiaolaiDictCore
#if canImport(Translation)
import Translation
#endif

/// Whether a **Developer ID-signed bundle** can actually translate — not whether an availability
/// API says it could.
///
/// The precedent is exact and expensive: `PrivateCloudComputeLanguageModel` reported `available` on
/// this machine and then failed every request in ~10 ms on a signing-policy check. An availability
/// flag is a claim about the platform; it is not a claim about *this* app.
///
/// So this translates a real sentence and inspects the result, in the same spirit as `SpeechReport`
/// counting audio frames rather than trusting that `speak` returned quietly. The failure it exists
/// to catch is the one that reads as success: an empty string, or the input handed straight back.
enum TranslationReport {
    /// A language pair, by BCP-47 identifier.
    struct Pair: Sendable, Equatable {
        let source: String
        let target: String
        /// The sentence this pair is probed with, **in its own source language**. A pair fed the
        /// wrong language can only ever echo, which the verdict correctly rejects and which
        /// therefore measures nothing. Measured 2026-09-20: zh-Hans→en did exactly that.
        let sample: String
    }

    /// The reader's pairs, not all 21 the framework supports — measured: 21 supported, en→zh-Hans
    /// `.supported`. A probe that walked every pair would measure Apple's catalogue, not XiaolaiDict's
    /// audience, and each pair costs a model download.
    static let pairs: [Pair] = [
        Pair(source: "en", target: "zh-Hans", sample: english),
        Pair(source: "zh-Hans", target: "en", sample: "\u{8239}\u{8231}\u{88C5}\u{6EE1}\u{4E86}\u{3002}"),
        Pair(source: "en", target: "zh-Hant", sample: english),
        Pair(source: "zh-Hant", target: "en", sample: "\u{8239}\u{8259}\u{88DD}\u{6EFF}\u{4E86}\u{3002}"),
    ]

    /// The English probe sentence, and the reason it is this one: *hold* is the project's canonical
    /// polysemy case. Measured 2026-09-20 on the E2E machine, Apple's translator answered it with
    /// \u{8239}\u{7684}\u{8239}\u{6EE1}\u{4E86}\u{3002} — "the ship's ship was full" — taking the wrong sense of *hold*. A pane that
    /// renders that beside a correct entry misleads the reader, which is why the sentence stays.
    static let english = "The ship's hold was full."

    /// The sentence the probe translates: short, unambiguous, and the project's own canonical
    /// example, so a wrong reading is recognisable by eye.

    /// Whether `target` is a translation at all, rather than the two failures that look like one.
    ///
    /// **An echo is the failure that reads as success.** A translator that hands the input back —
    /// or returns nothing — produces a response object indistinguishable from a working one, and
    /// a panel would render it with full confidence.
    static func isRealTranslation(source: String, target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return normalised(trimmed) != normalised(source)
    }

    /// Case and whitespace are not a translation. Compared this way so that "  the ship's HOLD was
    /// full.  " is still recognised as the input coming back.
    private static func normalised(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Measured 2026-09-19, both Macs, bundle and bare binary alike: **every pair reports
    /// `.supported` and then fails `translate` with `.notInstalled`**. So `.supported` describes
    /// Apple's catalogue, not this Mac — and an availability check alone would have shipped a
    /// translation feature that never translates. Before offering one, call `prepareTranslation()`
    /// so the reader is asked to download the pair, or handle `.notInstalled` where it lands.
    static func run(write: (String) -> Void = LookupCommand.writeLine) async -> CommandStatus {
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else {
            write("{\"translation\":false,\"reason\":\"this macOS has no Translation framework\"}")
            return .failure
        }
        let availability = LanguageAvailability()
        var results: [[String: Any]] = []
        for pair in pairs {
            let source = Locale.Language(identifier: pair.source)
            let target = Locale.Language(identifier: pair.target)
            let status = await availability.status(from: source, to: target)
            var row: [String: Any] = [
                "source": pair.source, "target": pair.target,
                "status": String(describing: status),
            ]
            // The measurement that matters: does it produce a translation? A pair can report
            // `.supported` and still have nothing downloaded to translate with.
            let started = ContinuousClock.now
            do {
                let session = TranslationSession(installedSource: source, target: target)
                let response = try await session.translate(pair.sample)
                let took = ContinuousClock.now - started
                row["translated"] = response.targetText
                row["real"] = isRealTranslation(source: pair.sample, target: response.targetText)
                row["milliseconds"] = Int(took.components.seconds * 1000
                    + took.components.attoseconds / 1_000_000_000_000_000)
            } catch {
                row["real"] = false
                row["error"] = "\(error)"
            }
            results.append(row)
        }
        let report: [String: Any] = [
            "bundle": Bundle.main.bundleIdentifier ?? "none",
            "insideBundle": Bundle.main.bundleIdentifier != nil,
            "supportedLanguages": await availability.supportedLanguages.count,
            "pairs": results,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else {
            return .internalError
        }
        write(String(decoding: data, as: UTF8.self))
        // A report in which nothing actually translated is a failed measurement, and says so in
        // its exit status rather than only in its text.
        return results.contains { $0["real"] as? Bool == true } ? .success : .failure
        #else
        write("{\"translation\":false,\"reason\":\"this build has no Translation framework\"}")
        return .failure
        #endif
    }
}
