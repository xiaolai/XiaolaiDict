import AppKit
import Testing
@testable import XiaolaiDict

/// **The real checker, against plan-spelling-suggestion §2's table** — the one test here that asks the operating
/// system rather than a fake, because what `correction` answers is the whole premise of the feature.
///
/// Skipped, with the reason shown, on a Mac whose spell checker has no English at all: there the adapter answers nil
/// by design, and a table of English corrections has nothing to measure.
///
/// **`ambages` is measured by the instrument, not here.** The plan's table has it answering nothing, and it does on the
/// development Mac; on the E2E Mac — the same macOS build, 26A434 — the same call answered `ambles` (2026-10-09). That is the
/// checker's state on the Mac, not this code, so a unit test could only assert the Mac it ran on, and one that printed
/// it could not fail (audit round 2). The `lookup` E2E stage asks `--spelling-report recieve ambages` and prints what the
/// E2E Mac's checker said of it, failing if the report has no line for it. `rn`, `qqqq`, `arid` and `cabbages` answer
/// nothing on both Macs, and they are what refuses a checker that reached for the guess list: its first guesses are
/// `Ron`, `acid` and `cabbage`.
///
/// **Each assertion is gated on the languages it asks** (audit round 2, 2026-10-09). A question with no variant is asked
/// in plain `en` — the table was measured there, and `tbe` and `aboud` answer nothing under `en_GB` — so the suite needs
/// `en` itself, not any English; the British assertion needs `en_GB` as well; and the fallback a missing variant takes is
/// tested with the checker's list of languages given, rather than hoped for on a Mac that happens to lack one.
@MainActor
@Suite(.enabled("this Mac's spell checker has no plain English (en), which every question here without a variant is asked in") {
    await MainActor.run { NSSpellChecker.shared.availableLanguages.contains("en") }
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

    /// **Plain English is American**: `modernisation` is a typo there, asked with no variant and as `en-US` alike.
    @Test func plainEnglishCorrectsABritishSpelling() async {
        let checker = SystemSpellChecker()
        #expect(await checker.suggestion(for: "modernisation", language: nil) == "modernization")
        #expect(await checker.suggestion(for: "modernisation", language: "en-US") == "modernization")
    }

    /// **A British reader is asked in British English**, where the checker has it — and there `modernisation` is a word.
    @Test(.enabled("this Mac's spell checker has no British English (en_GB)") {
        await MainActor.run { NSSpellChecker.shared.availableLanguages.contains("en_GB") }
    })
    func aBritishReaderIsAskedInBritishEnglish() async {
        #expect(await SystemSpellChecker().suggestion(for: "modernisation", language: "en-GB") == nil)
    }

    /// **A variant the checker lacks is asked in plain English** — the supported fallback: a checker that lists only `en`
    /// asks a British reader's question in `en`, where `modernisation` is a typo. Given the list, so this holds on every
    /// Mac with plain English, whatever variants it also has.
    @Test func aVariantTheCheckerLacksIsAskedInPlainEnglish() async {
        let checker = SystemSpellChecker(languages: { ["en"] })
        #expect(await checker.suggestion(for: "modernisation", language: "en-GB") == "modernization")
        #expect(await checker.suggestion(for: "teh", language: "en-GB") == "the")
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
