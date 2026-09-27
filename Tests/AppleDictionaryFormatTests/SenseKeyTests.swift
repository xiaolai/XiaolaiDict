import Testing
@testable import AppleDictionaryFormat

/// Every fixture is invented. A definition cut from a shipped dictionary would put licensed text in
/// the repository and would test that dictionary's content rather than the keying scheme.
@Suite struct SenseKeyTests {
    @Test func aKeyIsAFunctionOfTheDefinition() {
        let a = SenseKey.content(dictionary: "d", entry: "e", definition: "a marsh plant that glows")
        let b = SenseKey.content(dictionary: "d", entry: "e", definition: "a marsh plant that glows")
        #expect(a == b)
    }

    @Test func rewordingChangesTheKey() {
        // Deliberate: the sense changed, and silently re-pointing a reader's card would be worse.
        let a = SenseKey.content(dictionary: "d", entry: "e", definition: "a marsh plant that glows")
        let b = SenseKey.content(dictionary: "d", entry: "e", definition: "a marsh plant that glimmers")
        #expect(a != b)
    }

    @Test func theNamespaceSeparatesDictionaries() {
        // Keyed globally the forward validation was 99.39%: sense ids repeat across dictionaries.
        let a = SenseKey.content(dictionary: "noad", entry: "e1", definition: "the same wording")
        let b = SenseKey.content(dictionary: "ocd", entry: "e1", definition: "the same wording")
        #expect(a != b)
        #expect(a.value == b.value, "the digest is the same; the namespace is what separates them")
    }

    @Test func punctuationAndCaseAndSpacingDoNotMatter() {
        let plain = SenseKey.digest(of: "A Marsh Plant That Glows")
        for variant in ["a marsh plant that glows.", "  a   marsh plant that glows  ",
                        "a marsh plant that glows。", "a marsh plant that glows!"] {
            #expect(SenseKey.digest(of: variant) == plain, "variant should normalise: \(variant)")
        }
    }

    @Test func distinctDefinitionsGetOrderIndependentKeys() {
        let forward = SenseKey.keys(dictionary: "d", entry: "e", definitions: ["first", "second", "third"])
        let reversed = SenseKey.keys(dictionary: "d", entry: "e", definitions: ["third", "second", "first"])
        #expect(Set(forward.map(\.value)) == Set(reversed.map(\.value)),
                "reordering an entry's senses must not rename them")
    }

    /// 2.53% of content keys mapped to more than one publisher id, every one of them two senses whose
    /// definitions read identically. This is that case.
    @Test func identicalDefinitionsAreSeparatedByOrdinal() {
        let keys = SenseKey.keys(dictionary: "d", entry: "e",
                                 definitions: ["same wording", "different", "same wording"])
        #expect(Set(keys.map(\.value)).count == 3, "all three senses need distinct keys")
        #expect(keys[1].value.contains(":") == false, "an uncollided sense keeps a bare digest")
        #expect(keys[0].value.contains(":"), "a collided sense gains an ordinal")
        #expect(keys[2].value.contains(":"))
    }

    @Test func aPublisherKeyIsMarkedAsOne() {
        let publisher = SenseKey.publisher(dictionary: "d", entry: "e", id: "m_en_gbus0000030.005")
        #expect(publisher.origin == .publisher)
        #expect(SenseKey.content(dictionary: "d", entry: "e", definition: "x").origin == .content)
    }
}
