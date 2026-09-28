import Testing
@testable import AppleDictionaryFormat

@Suite struct DictionaryProfileTests {
    /// 78 of 84 dictionaries put senses at `x_xd1`, so the default has to be that and the table has to
    /// hold only departures.
    @Test func theDefaultIsDepthOne() {
        let p = DictionaryProfile.profile(for: "com.apple.dictionary.NOAD")
        #expect(p.senseDepth == 1)
        #expect(p.marksSense(classAttribute: "se2 x_xd1 hasSn"))
        #expect(!p.marksSense(classAttribute: "se1 x_xd0"))
    }

    /// The bug this field exists to prevent: accepting any `x_xdN` as a sense broke 牛津英汉汉英, where
    /// only `x_xd1` carries `lexid` and `x_xd2`/`x_xd3` are subsenses.
    @Test func aDeeperBlockIsNotASenseInAShallowDictionary() {
        let p = DictionaryProfile.profile(for: "com.apple.dictionary.zh_CN-en.OCD")
        #expect(p.senseDepth == 1)
        #expect(!p.marksSense(classAttribute: "x_xd2"))
        #expect(!p.marksSense(classAttribute: "x_xd3"))
    }

    /// **Every one of the 84 readable dictionaries is depth 1** under the strict test — the block must
    /// carry a definition, not merely an `id`. An earlier table named six exceptions read off a looser
    /// probe and all six were artifacts; these are the three it got wrong.
    @Test func onlyRetentionPutsADictionaryInTheOverrideTable() {
        // The five that lose definitions at depth 1, measured through the indexer.
        #expect(DictionaryProfile.profile(for: "com.apple.dictionary.vi.oup").senseDepth == 2)
        #expect(DictionaryProfile.profile(for: "com.apple.dictionary.el.oup").senseDepth == 3)
        #expect(DictionaryProfile.overrides.count == 5)
        // These three were named by a looser probe and are artifacts — they index fine at depth 1.
        for identifier in ["com.apple.dictionary.sa-en.oup", "com.apple.dictionary.ko.NewAce",
                           "com.apple.dictionary.zh_HK-en.idioms.cp"] {
            #expect(DictionaryProfile.profile(for: identifier).senseDepth == 1, "\(identifier)")
        }
    }

    /// The field that does vary: `lexid` in 33 dictionaries, `id` in 24, none in 27.
    @Test func theIDAttributeIsWhatDiffers() {
        #expect(LanguageAdapters.profile(for: "com.apple.dictionary.zh_CN-en.OCD").senseIDAttribute == "lexid")
        #expect(LanguageAdapters.profile(for: "com.apple.dictionary.ja-en.WISDOM").senseIDAttribute == "id")
        #expect(LanguageAdapters.profile(for: "com.apple.dictionary.zh_TW-en.DrEye").senseIDAttribute == nil)
    }

    /// `Int("1sub")` is nil, so subsenses fall out by construction rather than by a special case.
    @Test func subsensesAreNeverSenses() {
        let p = DictionaryProfile.profile(for: "com.apple.dictionary.NOAD")
        #expect(!p.marksSense(classAttribute: "msDict x_xd1sub t_first"))
        #expect(!p.marksSense(classAttribute: "x_xd1sub"))
    }

    /// The class attribute is a space-separated list; substring matching reads `x_xd1sub` as a sense.
    @Test func matchingIsByWholeToken() {
        let p = DictionaryProfile.profile(for: "com.apple.dictionary.NOAD")
        #expect(!p.marksSense(classAttribute: "notx_xd1"))
        #expect(p.marksSense(classAttribute: "a x_xd1 b"))
        #expect(!p.marksSense(classAttribute: nil))
        #expect(!p.marksSense(classAttribute: ""))
    }

    /// 27 of 84 carry no publisher sense id; a profile must be able to say so rather than name an
    /// attribute the dictionary does not have.
    @Test func aProfileCanDeclareNoPublisherID() {
        let p = DictionaryProfile(identifier: "x", senseIDAttribute: nil)
        #expect(p.senseIDAttribute == nil)
    }

    /// **A depth token is compared, not parsed.** `Int("01") == 1` and `Int("+1") == 1`, so `x_xd01` and
    /// `x_xd+1` matched depth 1 — distinct class names silently opening a sense region.
    @Test func aDepthTokenIsNotParsedAsANumber() {
        let profile = DictionaryProfile(identifier: "test", senseDepth: 1)
        #expect(profile.marksSense(classAttribute: "x_xd1"))
        for variant in ["x_xd01", "x_xd+1", "x_xd 1", "x_xd1x", "x_xd１"] {
            #expect(!profile.marksSense(classAttribute: variant), "\(variant) was read as a sense")
        }
    }

    /// The same for a sub-entry token, which decides whether a phrasal verb's senses are opened.
    @Test func aSubEntryTokenRequiresACanonicalPositiveNumber() {
        let profile = DictionaryProfile(identifier: "test", senseDepth: 1)
        for good in ["x_xo1", "x_xo2", "x_xo9", "x_xo12"] {
            #expect(profile.marksSubEntry(classAttribute: good), "\(good) should open a sub-entry")
        }
        for bad in ["x_xo0", "x_xo01", "x_xo+1", "x_xo-1", "x_xo", "x_xoh", "x_xoLblBlk", "x_xo1x"] {
            #expect(!profile.marksSubEntry(classAttribute: bad), "\(bad) was read as a sub-entry")
        }
    }
}
