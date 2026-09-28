import Foundation
import Testing
@testable import AppleDictionaryFormat

/// **The property the old scheme did not have: a key is a function of its own sense.**
///
/// The first keying scheme appended `:<ordinal>` to members of a colliding group, counting prior
/// collisions. That made a key depend on how many siblings shared its wording, so:
///
///     definitions ["stop"]          -> ["6c45cb72a36e"]
///     definitions ["stop", "stop"]  -> ["6c45cb72a36e:0", "6c45cb72a36e:1"]
///
/// — the first key *changed* when a second sense was added. Every later step of the plan recovers more
/// definitions, so every later step would have renamed senses a reader had already studied. These are
/// the checks that decide whether that is fixed, and `theLegacyOrdinalSchemeFailsTheseProperties` is the
/// mutation that proves they can fail.
///
/// Generated rather than hand-picked, over a fixed seed so a failure is reproducible.
@Suite struct SenseKeyStabilityTests {
    /// A tiny deterministic generator. `SystemRandomNumberGenerator` would make a failure unrepeatable,
    /// and a failing property test nobody can re-run is not a check.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    static let wordings = ["to adjust", "a small device", "same wording", "to move unsteadily",
                           "a marsh plant", "to withdraw"]
    static let numbers: [String?] = [nil, "1", "2", "3", "a"]
    static let parts: [String?] = [nil, "noun", "verb", "adjective"]
    static let subEntries: [String?] = [nil, "wibble out", "wibble on"]

    /// A list of senses whose `(definition, position)` pairs are all distinct — the realistic case, and
    /// the one the stability properties are stated over. Two senses identical in *both* carry nothing that
    /// could tell them apart, and that residue has its own test below.
    static func distinctSenses(count: Int, using rng: inout Seeded) -> [PositionedDefinition] {
        var seen = Set<String>()
        var out: [PositionedDefinition] = []
        while out.count < count {
            let sense = PositionedDefinition(
                definition: wordings.randomElement(using: &rng)!,
                position: SensePosition(subEntry: subEntries.randomElement(using: &rng)!,
                                        partOfSpeech: parts.randomElement(using: &rng)!,
                                        senseNumber: numbers.randomElement(using: &rng)!))
            let fingerprint = SenseKey.digestInput(sense.definition, sense.position)
            if seen.insert(fingerprint).inserted { out.append(sense) }
        }
        return out
    }

    static func values(_ senses: [PositionedDefinition]) -> [String] {
        SenseKey.keys(dictionary: "d", entry: "e", senses: senses).keys.map(\.value)
    }

    /// **Insert a definition anywhere; every pre-existing key keeps its value.**
    @Test func insertingASenseRenamesNothing() {
        var rng = Seeded(seed: 20_260_927)
        for round in 0 ..< 400 {
            let original = Self.distinctSenses(count: 1 + round % 9, using: &rng)
            let before = Self.values(original)
            // One more sense, distinct from all of them, tried at every insertion point.
            var extended = Self.distinctSenses(count: original.count + 1, using: &rng)
            while extended.contains(where: { s in original.contains(where: { $0 == s }) }) {
                extended = Self.distinctSenses(count: original.count + 1, using: &rng)
            }
            let newcomer = extended[0]
            for at in 0 ... original.count {
                var mutated = original
                mutated.insert(newcomer, at: at)
                let after = Self.values(mutated)
                var survivors = after
                survivors.remove(at: at)
                #expect(survivors == before,
                        "inserting at \(at) renamed a pre-existing key in round \(round)")
            }
        }
    }

    /// **Delete a definition; every surviving key keeps its value.**
    @Test func deletingASenseRenamesNothing() {
        var rng = Seeded(seed: 20_260_928)
        for round in 0 ..< 400 {
            let original = Self.distinctSenses(count: 2 + round % 8, using: &rng)
            let before = Self.values(original)
            for at in original.indices {
                var mutated = original
                mutated.remove(at: at)
                var expected = before
                expected.remove(at: at)
                #expect(Self.values(mutated) == expected,
                        "deleting index \(at) renamed a surviving key in round \(round)")
            }
        }
    }

    /// **Reorder two identically-worded senses; each keeps its own key.**
    ///
    /// This is the case the old scheme got wrong in the way that mattered: document order decided which
    /// sibling owned `:0`, so swapping two identically worded sub-entries swapped their identities.
    @Test func reorderingTwoIdenticallyWordedSensesKeepsBothKeys() {
        let a = PositionedDefinition(definition: "to give up",
                                     position: SensePosition(subEntry: "give in", senseNumber: "1"))
        let b = PositionedDefinition(definition: "to give up",
                                     position: SensePosition(subEntry: "give up", senseNumber: "1"))
        let forward = SenseKey.keys(dictionary: "d", entry: "give", senses: [a, b])
        let reversed = SenseKey.keys(dictionary: "d", entry: "give", senses: [b, a])
        #expect(forward.keys[0].value == reversed.keys[1].value, "`give in`'s sense was renamed by order")
        #expect(forward.keys[1].value == reversed.keys[0].value, "`give up`'s sense was renamed by order")
        #expect(forward.keys[0].value != forward.keys[1].value, "identical wording must not collide")
        #expect(!forward.neededOrdinals, "position separated them, so no ordinal was needed")
    }

    /// **Two senses genuinely identical in wording *and* position still get distinct keys — and it is
    /// reported.**
    ///
    /// Nothing can tell these apart, so the fallback is an ordinal. What must not happen is that it
    /// passes silently: `ordinalled` names every index that needed one.
    @Test func sensesIdenticalInWordingAndPositionAreSeparatedAndReported() {
        let same = PositionedDefinition(definition: "same wording",
                                        position: SensePosition(partOfSpeech: "noun", senseNumber: "1"))
        let other = PositionedDefinition(definition: "different",
                                         position: SensePosition(partOfSpeech: "noun", senseNumber: "2"))
        let assignment = SenseKey.keys(dictionary: "d", entry: "e", senses: [same, other, same])
        #expect(Set(assignment.keys.map(\.value)).count == 3, "all three senses need distinct keys")
        #expect(assignment.ordinalled == [2], "only the repeat needed an ordinal, and it is reported")
        #expect(!assignment.keys[0].value.contains(":"),
                "the first occurrence keeps the bare digest, so appending a repeat does not rename it")
        #expect(assignment.keys[2].value.hasSuffix(":1"))
    }

    /// Appending a colliding sense leaves the earlier one's key alone — which is why the first occurrence
    /// keeps the bare digest rather than the whole group being numbered.
    @Test func appendingARepeatDoesNotRenameTheOriginal() {
        let one = PositionedDefinition(definition: "stop", position: .unplaced)
        let before = SenseKey.keys(dictionary: "d", entry: "e", senses: [one])
        let after = SenseKey.keys(dictionary: "d", entry: "e", senses: [one, one])
        #expect(before.keys[0].value == after.keys[0].value,
                "adding a second identical sense renamed the first — the defect step 0 exists to remove")
        #expect(!before.neededOrdinals)
        #expect(after.ordinalled == [1])
    }

    /// **The mutation.** The legacy scheme — ordinal appended to every member of a colliding group,
    /// position ignored — must fail the properties above. If it passed them they would be decoration.
    ///
    /// Reimplemented here rather than reached for through a flag on the shipping type: a mutation switch
    /// in production code is a way to ship the defect.
    @Test func theLegacyOrdinalSchemeFailsTheseProperties() {
        func legacyValues(_ senses: [PositionedDefinition]) -> [String] {
            let digests = senses.map { SenseKey.digest(of: $0.definition, at: .unplaced) }
            var counts: [String: Int] = [:]
            for d in digests { counts[d, default: 0] += 1 }
            var used: [String: Int] = [:]
            return digests.map { d in
                guard counts[d, default: 0] > 1 else { return d }
                let n = used[d, default: 0]
                used[d] = n + 1
                return "\(d):\(n)"
            }
        }

        // The measured case from the plan: one "stop" becomes two, and the first key changes.
        let stop = PositionedDefinition(definition: "stop", position: .unplaced)
        let one = legacyValues([stop])
        let two = legacyValues([stop, stop])
        #expect(one[0] != two[0], "the legacy scheme is expected to rename on insertion; it did not")
        #expect(two == ["\(one[0]):0", "\(one[0]):1"])

        // And it cannot separate two identically-worded senses by position, so reordering swaps them.
        let a = PositionedDefinition(definition: "to give up",
                                     position: SensePosition(subEntry: "give in", senseNumber: "1"))
        let b = PositionedDefinition(definition: "to give up",
                                     position: SensePosition(subEntry: "give up", senseNumber: "1"))
        #expect(legacyValues([a, b]) == legacyValues([b, a]),
                "the legacy scheme is expected to be blind to position; it was not")

        // Both cases hold under the shipping scheme, which is the contrast that makes the properties real.
        #expect(Self.values([stop])[0] == Self.values([stop, stop])[0],
                "the shipping scheme must not rename on insertion")
        #expect(Self.values([a, b]) == Self.values([b, a]).reversed(),
                "the shipping scheme must move each key with its own sense, not with its index")
    }

    /// Position is part of the digest, not appended to it — so a positioned sense and an unplaced one
    /// worded the same are different senses, and no key is a prefix of another.
    @Test func positionEntersTheDigestRatherThanTheKey() {
        let unplaced = SenseKey.content(dictionary: "d", entry: "e", definition: "to adjust")
        let numbered = SenseKey.content(dictionary: "d", entry: "e", definition: "to adjust",
                                        position: SensePosition(senseNumber: "1"))
        #expect(unplaced.value != numbered.value)
        #expect(unplaced.value.count == numbered.value.count, "both are a bare 12-hex digest")
        #expect(!unplaced.value.contains(":"))
    }

    /// The digest input is length-prefixed, so no pair of fields can be rearranged into another pair's
    /// bytes. A delimiter alone would let a definition ending in it collide with the next field.
    @Test func digestInputCannotBeConfusedBetweenFields() {
        let a = SenseKey.digestInput("ab", SensePosition(subEntry: "c"))
        let b = SenseKey.digestInput("abc", SensePosition(subEntry: ""))
        #expect(a != b)
        let c = SenseKey.digestInput("", SensePosition(partOfSpeech: "noun", senseNumber: "1"))
        let d = SenseKey.digestInput("", SensePosition(partOfSpeech: "noun1"))
        #expect(c != d)
    }

    /// An absent field and an empty one are the same position — a dictionary that prints an empty
    /// sense-number span has not numbered that sense.
    @Test func anEmptyFieldIsTheSameAsAnAbsentOne() {
        #expect(SenseKey.digest(of: "x", at: SensePosition(senseNumber: ""))
                == SenseKey.digest(of: "x", at: .unplaced))
        #expect(SenseKey.digest(of: "x", at: SensePosition(partOfSpeech: " . "))
                == SenseKey.digest(of: "x", at: .unplaced))
    }

    /// **The persisted key format, pinned to literal values.**
    ///
    /// Every other test here compares outputs of the same implementation against each other, so reordering
    /// the digest fields or adding a constant to the digest input would rename every persisted key while
    /// leaving equality, uniqueness and stability all intact. These literals are the thing that cannot move
    /// quietly: a diff that changes them is a migration, and has to be recognised as one.
    @Test func theDigestFormatIsPinnedToLiteralValues() {
        #expect(SenseKey.digestInput("stop", .unplaced) == "4:stop0:0:0:")
        #expect(SenseKey.digestInput("to give up",
                                     SensePosition(subEntry: "give up", partOfSpeech: "verb",
                                                   senseNumber: "1"))
                == "10:to give up7:give up4:verb1:1")
        // Normalisation is part of the format: NFC, lowercased, whitespace collapsed, ends trimmed.
        #expect(SenseKey.digestInput("  A Marsh  Plant. ", .unplaced) == "13:a marsh plant0:0:0:")
        // And the digests those inputs produce.
        #expect(SenseKey.digest(of: "stop") == "301ce0ebe858")
        #expect(SenseKey.digest(of: "a marsh plant that glows") == SenseKey.digest(of: "A marsh plant that glows."))
    }

    /// `description` is an identity and must separate what `SenseKey` separates.
    ///
    /// The readable `dictionary/entry#value` form lost two distinctions: a publisher id that reads like a
    /// digest matched the content key with that digest, and `#` inside a component moved the boundary.
    @Test func keyIdentityIsUnambiguous() {
        let digest = SenseKey.digest(of: "stop")
        let content = SenseKey.content(dictionary: "d", entry: "e", definition: "stop")
        let publisher = SenseKey.publisher(dictionary: "d", entry: "e", id: digest)
        #expect(content.value == publisher.value, "the premise: the same value, different origins")
        #expect(content != publisher)
        #expect(content.description != publisher.description,
                "two unequal keys serialised identically, and the validity measurement keys on this string")
        // A delimiter inside a component must not move the boundary.
        let a = SenseKey(dictionary: "d", entry: "e#a", value: "b", origin: .content)
        let b = SenseKey(dictionary: "d", entry: "e", value: "a#b", origin: .content)
        #expect(a.description != b.description)
        // The readable form is still available, and is still ambiguous — which is why it is not the identity.
        #expect(content.displayForm == "d/e#\(digest)")
    }

    /// A position field that normalises to nothing is nothing — equality, hashing and `isUnplaced` all agree
    /// with the digest, where before they contradicted it.
    @Test func anEmptyPositionFieldIsCanonicalisedAway() {
        #expect(SensePosition(senseNumber: "") == .unplaced)
        #expect(SensePosition(senseNumber: " . ") == .unplaced)
        #expect(SensePosition(senseNumber: "").isUnplaced)
        #expect(SensePosition(senseNumber: "").hashValue == SensePosition.unplaced.hashValue)
        #expect(SensePosition(partOfSpeech: "", senseNumber: "1") == SensePosition(senseNumber: "1"))
    }

    /// Decoding goes through the canonicalising initialiser: the synthesized `Decodable` assigned the stored
    /// properties directly and let an empty field back in by the back door.
    @Test func decodingCanonicalisesAnEmptyField() throws {
        let decoded = try JSONDecoder().decode(
            SensePosition.self, from: Data(#"{"senseNumber":""}"#.utf8))
        #expect(decoded == .unplaced)
        #expect(decoded.isUnplaced)
        // And a round trip of a real position is unchanged.
        let real = SensePosition(subEntry: "give up", partOfSpeech: "verb", senseNumber: "1")
        let round = try JSONDecoder().decode(SensePosition.self,
                                             from: try JSONEncoder().encode(real))
        #expect(round == real)
    }

    /// `description` must agree with `==` on canonically equivalent text. Swift compares `"é"` and
    /// `"e\u{0301}"` as equal, so two equal keys produced different byte lengths and different identities.
    @Test func keyIdentityAgreesWithEqualityOnCanonicallyEquivalentText() {
        let composed = SenseKey(dictionary: "d", entry: "\u{00E9}", value: "v", origin: .content)
        let decomposed = SenseKey(dictionary: "d", entry: "e\u{0301}", value: "v", origin: .content)
        #expect(composed == decomposed, "the premise: Swift compares these equal")
        #expect(composed.description == decomposed.description,
                "two equal keys had different identities")
    }
}
