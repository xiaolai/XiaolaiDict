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
        let senses = ["first", "second", "third"].map { PositionedDefinition(definition: $0) }
        let forward = SenseKey.keys(dictionary: "d", entry: "e", senses: senses)
        let reversed = SenseKey.keys(dictionary: "d", entry: "e", senses: senses.reversed())
        #expect(Set(forward.keys.map(\.value)) == Set(reversed.keys.map(\.value)),
                "reordering an entry's senses must not rename them")
    }

    /// 2.53% of content keys mapped to more than one publisher id, every one of them two senses whose
    /// definitions read identically. Where the markup distinguishes them by position they no longer
    /// collide at all; where it does not, the ordinal is the last resort and
    /// `SenseKeyStabilityTests` states the properties that hold around it.
    @Test func definitionsIdenticalInWordingAndPositionAreSeparatedByOrdinal() {
        let same = PositionedDefinition(definition: "same wording")
        let other = PositionedDefinition(definition: "different")
        let assignment = SenseKey.keys(dictionary: "d", entry: "e", senses: [same, other, same])
        #expect(Set(assignment.keys.map(\.value)).count == 3, "all three senses need distinct keys")
        #expect(!assignment.keys[1].value.contains(":"), "an uncollided sense keeps a bare digest")
        #expect(!assignment.keys[0].value.contains(":"), "the first occurrence keeps the bare digest")
        #expect(assignment.keys[2].value.contains(":"), "the repeat gains an ordinal")
        #expect(assignment.ordinalled == [2], "the fallback is reported, not silent")
    }

    /// The same two words at two declared positions are two senses, and neither needs an ordinal.
    @Test func positionSeparatesIdenticallyWordedSenses() {
        let assignment = SenseKey.keys(dictionary: "d", entry: "e", senses: [
            PositionedDefinition(definition: "to stop", position: SensePosition(senseNumber: "1")),
            PositionedDefinition(definition: "to stop", position: SensePosition(senseNumber: "2")),
        ])
        #expect(Set(assignment.keys.map(\.value)).count == 2)
        #expect(!assignment.neededOrdinals)
    }

    @Test func aPublisherKeyIsMarkedAsOne() {
        let publisher = SenseKey.publisher(dictionary: "d", entry: "e", id: "m_en_gbus0000030.005")
        #expect(publisher.origin == .publisher)
        #expect(SenseKey.content(dictionary: "d", entry: "e", definition: "x").origin == .content)
    }
}
