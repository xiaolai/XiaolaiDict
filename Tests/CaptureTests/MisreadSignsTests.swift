import CaptureModel
import Testing

/// **A sentence read off the pixels can be wrong, and Vision's own confidence does not say so.**
///
/// Every fixture here is a sentence the owner's ledger recorded from an optical read (2026-10-11),
/// copied verbatim. Vision reported 1.0 for each garbled one — its confidence is quantised to
/// 0.3, 0.5 and 1.0 and is per observation, not per character — so the signal has to come from the
/// text itself. Measured over all 94 optical rows: the two shapes below flag 7 rows, every one a
/// real misread, and no correctly read sentence.
struct MisreadSignsTests {
    /// `comfortable（你用的）` on screen, the Chinese read as Latin: a currency sign inside a run of
    /// letters (ledger ids 120, 121).
    @Test func aSymbolInsideAWordIsAMisread() {
        #expect(MisreadSigns.found(in: "comfortable (1TÆ฿J)") == .symbolInsideAWord)
    }

    /// One alphabet's letter standing in for another's inside a word — Cyrillic `Л`, `с` and `а` for
    /// Latin (ids 76, 116). Invisible to a reader, and still not what was on screen.
    @Test func twoAlphabetsInOneWordAreAMisread() {
        #expect(MisreadSigns.found(in: "Лlhat incudesmv twelve addedlcase-table entrles") == .mixedAlphabets)
        #expect(MisreadSigns.found(
            in: "so the next build dies with \"unable to spawn process /Applications/XiaolaiDict.аpp") == .mixedAlphabets)
    }

    /// **The true negatives.** Correctly read sentences, Chinese glued to English, an arrow between
    /// versions, and accented Latin, which is a language and not a misread.
    @Test(arguments: [
        "My recommendation is (1) alone, then re-read the ledger after a week of real use before adding keys or modes - because the cheapest thing that could happen is that (1) is sufficient and you never need to give up Option.",
        "It's small and self-contained: one refusal case, one activity watcher, and the tests are pure.",
        "Nothing is committed yet: nine files in ambages are changed and uncommitted.",
        "Both ships then vanished.",
        "Such a trend was acknowl-edged by China's Supreme People's Procuratorate, which in a 2023 report on telecom and online",
        "Latent Space Latent Space（潜空间）是神经网络内部学习到的低维稠密向量空间，用于压缩高维原始数据（如图像像素、文本token）并保留语义关系。",
        "• 0.0.4 is live and installed. brew upgrade took it 0.0.3 → 0.0.4, and the upgraded copy carries the quarantine flag",
        "They met at a café in Zürich and spoke of naïveté.",
        "Budget 2600 → 4400 kB, measured at 4.19 MB.",
    ])
    func aSentenceReadCorrectlyHasNoSign(_ sentence: String) {
        #expect(MisreadSigns.found(in: sentence) == nil)
    }

    /// **What this cannot see**, kept as a record rather than a goal: real-looking words that are the
    /// wrong ones (`AI` read as `Al`, id 96), and word salad made only of Latin letters (ids 67, 91).
    /// Catching those needs a lexicon, which is a different instrument.
    @Test(arguments: [
        "I have Al delirium.",
        "claudepot andmecha tormulae both decaredaverslon and then bult thelr urs iromltwhlchaudili reiects as redundant: deleting it would have emptied the interpolation.",
    ])
    func aMisreadOfOnlyLatinLettersIsNotSeen(_ sentence: String) {
        #expect(MisreadSigns.found(in: sentence) == nil)
    }

    /// Scoped to optical reads: an app's own characters are what it holds, whatever they look like.
    @Test func onlyAnOpticalReadIsDoubted() throws {
        let optical = try #require(CaptureQuality(source: .opticalRecognition, confidence: 1, context: .complete))
        let exact = CaptureQuality.accessibility(.accessibilityTextRange, context: .complete)
        #expect(optical.doubts(sentence: "comfortable (1TÆ฿J)"))
        #expect(!exact.doubts(sentence: "comfortable (1TÆ฿J)"))
        #expect(!optical.doubts(sentence: "Both ships then vanished."))
        #expect(!optical.doubts(sentence: nil))
    }
}
