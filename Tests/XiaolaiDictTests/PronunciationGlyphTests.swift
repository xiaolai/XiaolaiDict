import AppKit
import CoreText
import Testing
@testable import XiaolaiDictUI

/// **Every pronunciation the reader's dictionaries print is drawn by the card's own font, glyph for glyph** (measured
/// 2026-10-11 over 38 entries of NOAD, 牛津英汉汉英词典 and 牛津粵英雙語詞典: 52 distinct code points — IPA, NOAD's
/// respelling with its macrons and combining double macrons, stress and length marks, parentheses — every one drawn by
/// the system font at 12 and 24 pt, with no fallback and no missing glyph). The card and the pinned note set a
/// pronunciation in `.system(size: scale.text.body)`; this holds that font to the measured strings at every size.
struct PronunciationGlyphTests {
    /// The measured pronunciations, as extracted (phonetic notation, not definitions).
    static let samples = [
        "ˈkʌmf(ə)təbl", "ˈkəmfərdəb(ə)l", "ɪˈfɛm(ə)r(ə)l", "əˈfem(ə)rəl", "ˈθʌrə", "ˈTHərō", "ˈʃɛdjuːl", "ˈskeˌjo͞ol",
        "ˈʌɪðə", "ˈēT͟Hər", "ˈɡarɑː(d)ʒ", "ɡəˈräZH", "təˈmɑːtəʊ", "təˈmādō", "ˈrɪð(ə)m", "ˈriT͟Həm", "ˈɛnvələʊp",
        "ˈenvəˌlōp", "nʌɪˈiːv", "näˈēv", "ˈk(r)wasɒ̃", "ˌk(r)wäˈsän(t)", "ˈmɪstʃɪvəs", "ˈmisCHəvəs", "ˈfɛbr(ər)i",
        "ˈfeb(y)əˌwerē",
    ]

    /// The fonts that draw `text` in the card's pronunciation font at `size`, and how many glyphs came out missing.
    static func drawn(_ text: String, size: CGFloat) -> (fonts: Set<String>, missing: Int) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]))
        var fonts = Set<String>(), missing = 0
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            // CTFont is toll-free bridged to NSFont.
            if let font = attributes[kCTFontAttributeName] as? NSFont { fonts.insert(font.fontName) }
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: glyphs.count), &glyphs)
            missing += glyphs.filter { $0 == 0 }.count
        }
        return (fonts, missing)
    }

    @Test(arguments: TextSize.allCases)
    func everyMeasuredPronunciationIsDrawnByOneFontWithNoMissingGlyph(size: TextSize) {
        let body = Scale(size).text.body, card = NSFont.systemFont(ofSize: body).fontName
        for sample in Self.samples {
            let drawn = Self.drawn(sample, size: body)
            #expect(drawn.missing == 0, "\(sample) at \(size): \(drawn.missing) missing glyphs")
            #expect(drawn.fonts == [card], "\(sample) at \(size) fell back to \(drawn.fonts)")
        }
    }

    /// **The positive control**: a code point the system font has no glyph for is seen — it falls back to another font
    /// or comes out missing — so the check above can fail.
    @Test func aCodePointTheFontLacksIsCaught() {
        let body = Scale(.standard).text.body
        let drawn = Self.drawn("ˈfɛ\u{E000}", size: body)
        #expect(drawn.missing > 0 || drawn.fonts != [NSFont.systemFont(ofSize: body).fontName])
    }
}
