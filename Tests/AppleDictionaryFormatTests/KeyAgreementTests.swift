import Foundation
import Testing
@testable import AppleDictionaryFormat

/// The oracle the confidence gate rests on. Each case below is a shape that really occurs in the
/// catalogue, written with invented words — the shapes are the finding, the words are not.
struct KeyAgreementTests {
    @Test func aKeyIdenticalToItsHeadwordAgrees() {
        #expect(KeyAgreement.agrees(key: "wibble", headword: "wibble"))
    }

    /// **Pronunciation after the headword.** Apple delimits it with `|`, so `roo | ro͞oru |` has to be cut
    /// back to `roo` before anything is compared.
    @Test func aPronunciationAfterTheHeadwordIsIgnored() {
        #expect(KeyAgreement.agrees(key: "wibble", headword: "wibble | ˈwɪbəl |"))
        #expect(KeyAgreement.base("wibble | ˈwɪbəl |").trimmingCharacters(in: .whitespaces) == "wibble")
    }

    /// **Pronunciation inside the headword.** `zh_TW.wn` interleaves Bopomofo between every character, so
    /// there is no delimiter to cut at and containment can never match. This scored 6.9% under containment
    /// while resolving correctly.
    @Test func bopomofoInterleavedInsideTheHeadwordIsIgnored() {
        // Invented: two CJK characters with Bopomofo spliced between them, the way that dictionary writes it.
        #expect(KeyAgreement.agrees(key: "山水", headword: "山ㄕㄢ水ㄕㄨㄟˇ | shān shuǐ |"))
    }

    /// **Inflection.** A suffix-inflected form is not a substring of its base, but it begins like it.
    /// Russian `вое`/`вои`/`воя` under `вой` scored 7.9% under containment.
    @Test func anInflectedFormAgreesWithItsBase() {
        #expect(KeyAgreement.agrees(key: "wibbles", headword: "wibble"))
        #expect(KeyAgreement.agrees(key: "wibbla", headword: "wibbly"))
    }

    /// **Derived forms and compounds.** Bengali `অংশ করা` belongs under `অংশ`; the key is longer than the
    /// headword, so the prefix runs the other way.
    @Test func aCompoundKeyAgreesWithItsBaseHeadword() {
        #expect(KeyAgreement.agrees(key: "wibble making", headword: "wibble"))
    }

    /// Hyphens, spaces and case disagree between a key and its headword routinely — Danish `a aktier`
    /// against `A-aktier` is one word written two ways.
    @Test func hyphensSpacesAndCaseDoNotMatter() {
        #expect(KeyAgreement.agrees(key: "a wibbler", headword: "A-wibbler"))
        #expect(KeyAgreement.fold("A-Wibbler, Karla") == "awibblerkarla")
    }

    /// **The case that must still fail.** A real mis-resolution found while checking this oracle mapped the
    /// key `сок` to the headword `во́лос` — unrelated words, and nothing about them shares an opening.
    @Test func anUnrelatedWordDoesNotAgree() {
        #expect(!KeyAgreement.agrees(key: "wibble", headword: "frobnitz"))
        #expect(!KeyAgreement.agrees(key: "sok", headword: "volos"))
    }

    /// One shared opening letter is not relatedness, or every word beginning `a` would agree with every
    /// other. The floor is two.
    @Test func oneSharedLetterIsNotEnough() {
        #expect(!KeyAgreement.agrees(key: "wibble", headword: "wonder"))
        #expect(KeyAgreement.requiredPrefix("abc", "abd") == 2)
    }

    @Test func anEmptyOrPurelyPhoneticStringAgreesWithNothing() {
        #expect(!KeyAgreement.agrees(key: "", headword: "wibble"))
        #expect(!KeyAgreement.agrees(key: "wibble", headword: ""))
        #expect(!KeyAgreement.agrees(key: "wibble", headword: "| ˈwɪbəl |"))
    }
}
