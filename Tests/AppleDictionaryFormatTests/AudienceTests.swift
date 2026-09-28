import Foundation
import Testing

@testable import AppleDictionaryFormat

/// **Which dictionaries belong in *this* reader's index.**
///
/// Simplified Chinese, Traditional Chinese and Cantonese are three audiences, each wanting its own
/// bilingual dictionary — a Cantonese reader wants Cantonese glosses, not Mandarin written in
/// Traditional characters. One index file per reader, holding their audience's dictionaries and not the
/// others': measured on the development Mac, indexing everything installed costs 216 s and 478 MB
/// against 82 s and 319 MB scoped, and adding an audience later costs only its own dictionaries —
/// 45 s, with the rest reported "already current".
struct AudienceTests {
    private func bundle(_ id: String, _ pairs: [(String, String)]) -> DictionaryBundle {
        DictionaryBundle(url: URL(fileURLWithPath: "/tmp/\(id).dictionary"), identifier: id,
                         displayName: id, declaredVersion: "1",
                         languages: pairs.map { DeclaredLanguage(index: $0.0, explains: $0.1) })
    }

    private var noad: DictionaryBundle { bundle("NOAD", [("en_US", "en_US")]) }
    private var oawt: DictionaryBundle { bundle("OAWT", [("en_US", "en_US")]) }
    private var hans: DictionaryBundle { bundle("zh_CN-en.OCD", [("zh_CN", "zh_CN"), ("en", "zh_CN")]) }
    private var hant: DictionaryBundle { bundle("zh_TW-en.DrEye", [("zh_TW", "zh_TW"), ("en", "zh_TW")]) }
    private var yue: DictionaryBundle { bundle("yue-en.oup", [("yue", "yue"), ("en", "yue")]) }
    private var hansOnly: DictionaryBundle { bundle("zh_CN.SDCC", [("zh_CN", "zh_CN")]) }

    private var all: [DictionaryBundle] { [noad, oawt, hans, hant, yue, hansOnly] }

    @Test func aSimplifiedReaderGetsTheirBilingualAndTheEnglishMonolinguals() {
        let served = all.filter { $0.serves(reader: "zh-Hans-CN") }.map(\.identifier)
        #expect(served == ["NOAD", "OAWT", "zh_CN-en.OCD"])
    }

    /// The correction that prompted this: Cantonese is its own audience, not a Traditional variant.
    @Test func aCantoneseReaderGetsTheCantoneseDictionaryAndNotTheTraditionalOne() {
        let served = all.filter { $0.serves(reader: "yue-Hant-HK") }.map(\.identifier)
        #expect(served == ["NOAD", "OAWT", "yue-en.oup"])
    }

    @Test func aTraditionalReaderGetsNeitherTheSimplifiedNorTheCantoneseOne() {
        let served = all.filter { $0.serves(reader: "zh-Hant-TW") }.map(\.identifier)
        #expect(served == ["NOAD", "OAWT", "zh_TW-en.DrEye"])
    }

    /// Hong Kong and Taiwan share a script, so they are one audience — region decides the script and
    /// then the script is compared.
    @Test func hongKongAndTaiwanAreTheSameAudience() {
        #expect(all.filter { $0.serves(reader: "zh-Hant-HK") }.map(\.identifier)
                == all.filter { $0.serves(reader: "zh-Hant-TW") }.map(\.identifier))
    }

    /// A Chinese–Chinese dictionary is out for every audience: this product is for reading English, and
    /// a dictionary whose headwords are Chinese can never answer the lookup — ADR-0027.
    @Test func aDictionaryThatDoesNotIndexEnglishIsNeverServed() {
        for reader in ["zh-Hans-CN", "zh-Hant-TW", "yue-Hant-HK", "en-US"] {
            #expect(!hansOnly.serves(reader: reader), "zh_CN.SDCC indexes Chinese, not English")
        }
    }

    /// An English reader gets the monolinguals and no bilingual: none explains in their language.
    @Test func anEnglishReaderGetsTheMonolingualsAlone() {
        #expect(all.filter { $0.serves(reader: "en-US") }.map(\.identifier) == ["NOAD", "OAWT"])
    }

    /// A bundle that declares nothing cannot be placed, and guessing would put a dictionary in an
    /// audience it may not belong to.
    @Test func aBundleDeclaringNoLanguageServesNobody() {
        #expect(!bundle("mystery", []).serves(reader: "zh-Hans-CN"))
    }
}
