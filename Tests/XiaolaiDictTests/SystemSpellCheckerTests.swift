import AppKit
import Testing
@testable import XiaolaiDict

/// **The real checker, against plan-spelling-suggestion §2's table** — the one test here that asks the operating
/// system rather than a fake, because what `correction` answers is the whole premise of the feature.
///
/// Skipped, with the reason shown, on a Mac whose spell checker has no English at all: there the adapter answers nil
/// by design, and a table of English corrections has nothing to measure.
///
/// **`ambages` is printed and not asserted, and that is a measurement, not a loosening.** The plan's table has it
/// answering nothing, and it does on the development Mac; on `mbp16` — the same macOS build, 26A434 — the same call
/// answered `ambles` (2026-10-09). The difference is the checker's state on that Mac, not this code, so asserting nil
/// would test the machine the suite runs on. `rn`, `qqqq`, `arid` and `cabbages` answer nothing on both, and they are
/// what refuses a checker that reached for the guess list: its first guesses are `Ron`, `acid` and `cabbage`.
@MainActor
@Suite(.enabled("this Mac's spell checker has no English, so there is nothing to measure") {
    await MainActor.run { NSSpellChecker.shared.availableLanguages.contains { $0 == "en" || $0.hasPrefix("en_") } }
})
struct SystemSpellCheckerTests {
    nonisolated private static let typos = [
        "teh", "recieve", "definately", "accomodate", "seperate", "pnuemonia", "embarassing", "thier", "hte", "tbe",
        "aboud", "clairvoyent",
    ]
    nonisolated private static let corrections = [
        "the", "receive", "definitely", "accommodate", "separate", "pneumonia", "embarrassing", "their", "the", "the",
        "about", "clairvoyant",
    ]

    /// **The twelve common typos: one confident answer, right every time.**
    @Test(arguments: zip(typos, corrections))
    func aCommonTypoIsCorrected(typo: String, correction: String) async {
        #expect(await SystemSpellChecker().suggestion(for: typo, language: nil) == correction)
    }

    /// **Silent where the guess list is noise**: a two-letter OCR confusion, nonsense, and two words the checker knows.
    @Test(arguments: ["rn", "qqqq", "arid", "cabbages"])
    func noConfidentCorrectionIsNone(word: String) async {
        #expect(await SystemSpellChecker().suggestion(for: word, language: nil) == nil)
    }

    /// Printed, never asserted — see the suite's own comment for why this one word depends on the Mac.
    @Test func whatTheCheckerSaysOfARareRealWordIsPrinted() async {
        let answer = await SystemSpellChecker().suggestion(for: "ambages", language: nil)
        print("SystemSpellChecker: ambages → \(answer ?? "nothing") on this Mac (nothing on the development Mac, ambles on mbp16)")
    }

    /// **The reader's English reaches the checker**: `modernisation` is a typo in plain English and a word in British.
    @Test func theReadersEnglishIsTheLanguageAsked() async {
        let checker = SystemSpellChecker()
        #expect(await checker.suggestion(for: "modernisation", language: nil) == "modernization")
        #expect(await checker.suggestion(for: "modernisation", language: "en-US") == "modernization")
        #expect(await checker.suggestion(for: "modernisation", language: "en-GB") == nil)
    }

    /// **A spell document of its own**, never the shared default of 0: what a reader told the checker to ignore in some
    /// other document is not this lookup's business.
    @Test func eachCheckerHasASpellDocumentOfItsOwn() {
        let first = SystemSpellChecker(), second = SystemSpellChecker()
        #expect(first.tag != 0)
        #expect(second.tag != 0)
        #expect(first.tag != second.tag)
    }
}
