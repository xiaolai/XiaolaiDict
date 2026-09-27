import Foundation
import Testing
@testable import AppleDictionaryFormat

@Suite struct LanguageAdapterTests {
    @Test func everyLanguageIsCovered() {
        let languages = Set(LanguageAdapters.all.map { $0.language })
        #expect(languages == ["zh-Hans", "zh-Hant", "yue", "ko", "ja"])
    }

    @Test func noIdentifierIsClaimedTwice() {
        var seen: [String: String] = [:]
        for adapter in LanguageAdapters.all {
            for d in adapter.dictionaries {
                #expect(seen[d.identifier] == nil,
                        "\(d.identifier) claimed by both \(seen[d.identifier] ?? "") and \(adapter.language)")
                seen[d.identifier] = adapter.language
            }
        }
    }

    /// **An adapter must not be able to override a measured depth.**
    ///
    /// `LanguageAdapters.profile(for:)` consults the adapters first and falls through to
    /// `DictionaryProfile.profile(for:)` only for a dictionary no adapter claims. So an adapter that
    /// names its own depth wins over the retention measurement — which is the wrong way round, since the
    /// measurement is over the whole catalogue and the adapter is one language's declaration.
    ///
    /// The previous version of this test asserted `senseDepth == 1` for every adapter-declared
    /// dictionary. That passed, and was true, and was still the wrong assertion: it locked in a
    /// hardcoded 1 rather than checking that the measured table is what decides. It would also have
    /// failed for the right reason at the wrong place the moment a Vietnamese or Greek adapter was
    /// added, pointing at the depth instead of at itself.
    @Test func anAdapterCannotOverrideAMeasuredDepth() {
        // The real declarations: each must agree with what the table measured for it, whatever that is.
        for adapter in LanguageAdapters.all {
            for d in adapter.dictionaries {
                #expect(d.profile.senseDepth == DictionaryProfile.profile(for: d.identifier).senseDepth,
                        "\(d.identifier): adapter says \(d.profile.senseDepth)")
            }
        }
        // The mechanism, exercised on a dictionary that *is* in the override table. No adapter claims
        // Vietnamese today, so only a synthetic descriptor can reach this path — and it is the path that
        // silently cost 77% of that dictionary's definitions.
        let vietnamese = DictionaryDescriptor(
            identifier: "com.apple.dictionary.vi.oup", title: "Vietnamese", kind: .bilingual,
            author: "Oxford University Press", senseIDAttribute: nil)
        #expect(vietnamese.profile.senseDepth == 2,
                "an adapter reset Vietnamese to depth \(vietnamese.profile.senseDepth)")
    }

    /// Only Simplified Chinese and Cantonese have an Oxford-authored work. The rest are Sanseido,
    /// DIOTEK and INVENTEC "under licence to Oxford University Press", which is a distribution
    /// arrangement — recorded so a product claim built on "Oxford" cannot quietly overreach.
    @Test func authorshipIsRecordedRatherThanAssumed() {
        let oxford = LanguageAdapters.all.flatMap { $0.dictionaries }
            .filter { $0.author.contains("Oxford") }.map(\.identifier)
        #expect(oxford.contains("com.apple.dictionary.zh_CN-en.OCD"))
        #expect(oxford.contains("com.apple.dictionary.yue-en.oup"))
        #expect(!oxford.contains("com.apple.dictionary.ja-en.WISDOM"))
        #expect(!oxford.contains("com.apple.dictionary.ko-en.NewAce"))
        #expect(!oxford.contains("com.apple.dictionary.zh_TW-en.DrEye"))
    }

    /// Keeps the declarations honest. Gated on `XIAOLAIDICT_BUNDLES` so the ordinary suite does not
    /// depend on which dictionaries a machine has; where they are present, a declared `senseIDAttribute`
    /// must actually appear on that dictionary's senses.
    @Test func declaredIDAttributesMatchRealBundles() throws {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else {
            print("LanguageAdapterTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        let bundles = DictionaryLocator.installed(in: [URL(fileURLWithPath: root)])
        var checked = 0
        for adapter in LanguageAdapters.all {
            for (descriptor, bundle) in adapter.installed(from: bundles) {
                let entries = try ContainerReader.entries(in: bundle.url).prefix(200)
                let indexer = EntryIndexer(dictionary: bundle.identifier, profile: descriptor.profile)
                let indexed = entries.compactMap(indexer.index)
                let senses = indexed.flatMap(\.senses)
                guard !senses.isEmpty else { continue }
                checked += 1
                let publisher = senses.filter { $0.key.origin == .publisher }.count
                let share = Double(publisher) / Double(senses.count)
                if !descriptor.profile.expectsPublisherID {
                    // **Not `publisher == 0` — that is circular.** A profile declaring no attribute
                    // makes a publisher key unreachable, so the indexer trivially produces none and the
                    // assertion would pass whatever the dictionary contains. Instead index the same
                    // entries again with a profile that accepts both attributes: if ids were really
                    // there, that pass finds them and the declaration is wrong.
                    let permissive = DictionaryProfile(identifier: bundle.identifier,
                                                       senseIDAttributes: ["lexid", "id"])
                    let openMinded = EntryIndexer(dictionary: bundle.identifier, profile: permissive)
                    let found = entries.compactMap(openMinded.index)
                        .flatMap(\.senses).filter { $0.key.origin == .publisher }.count
                    let total = entries.compactMap(openMinded.index).flatMap(\.senses).count
                    let share = total > 0 ? Double(found) / Double(total) : 0
                    #expect(share < 0.10, Comment(rawValue: String(
                        format: "%@ declares no sense id, but a permissive read found one on %.0f%% of senses",
                        descriptor.identifier, share * 100)))
                } else {
                    let attribute = descriptor.senseIDAttribute ?? "?"
                    let percent = Int(share * 100)
                    let complaint = "\(descriptor.identifier) declares \(attribute) but only \(percent)% of senses carried one"
                    #expect(share > 0.5, Comment(rawValue: complaint))
                }
            }
        }
        print("LanguageAdapterTests: checked \(checked) installed dictionaries against their declarations")
    }
}
