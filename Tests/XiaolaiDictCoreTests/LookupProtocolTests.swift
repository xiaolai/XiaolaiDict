import Foundation
import XiaolaiDictCore
import Testing

/// The messages cross a process boundary as encoded bytes; what arrives must be what was sent.
struct LookupProtocolTests {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private let entries = NonEmpty([
        DictionaryEntry(
            dictionary: "牛津英汉汉英词典", headword: "ephemeral", lookedUp: "ephemeral",
            html: "<html><style>.hw { font-weight: 600; }</style><span class=\"hw\">ephemeral</span> 短暂的</html>"),
        DictionaryEntry(dictionary: "Thesaurus", headword: "ephemeral", lookedUp: "ephemeral", html: "<p/>"),
    ])!

    @Test func entriesSurviveTheBoundary() throws {
        let reply = LookupReply.entries(entries, unreadable: ["Wikipedia"])
        #expect(try roundTrip(reply) == reply)
    }

    @Test(arguments: [
        LookupReply.notFound,
        .failure(.invalidRequest("the term is blank")),
        .failure(.dictionaryServicesUnavailable("DictionaryServices has no DCSGetActiveDictionaries")),
        .failure(.unreadableEntries(dictionaries: ["Oxford Dictionary of English"])),
    ])
    func everyOtherReplySurvivesTheBoundary(reply: LookupReply) throws {
        #expect(try roundTrip(reply) == reply)
    }

    @Test func aRequestCarriesItsTerm() throws {
        #expect(try roundTrip(LookupRequest(term: "转瞬即逝")) == LookupRequest(term: "转瞬即逝"))
    }

    /// "Found nothing" has its own case. An empty success is not a value the type can hold — not
    /// in code, and not arriving from the other process either.
    @Test func anEmptyEntryListCannotBeBuilt() {
        #expect(NonEmpty<DictionaryEntry>([]) == nil)
    }

    @Test func anEmptyEntryListIsRefusedAtTheBoundary() throws {
        let encoded = try JSONEncoder().encode(LookupReply.entries(entries, unreadable: []))
        let emptied = try #require(String(data: encoded, encoding: .utf8))
            .replacingOccurrences(of: #"\[\{.*\}\]"#, with: "[]", options: .regularExpression)
        #expect(emptied.contains("[]"))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LookupReply.self, from: Data(emptied.utf8)) }
    }

    /// A dictionary that answers with another headword — "ran" gets "run" — must not look like
    /// the term's own entry.
    @Test(arguments: [
        ("ephemeral", "ephemeral", DictionaryEntry.Match.exact),
        ("Ephemeral", "ephemeral", .exact),
        ("running", "run", .dictionaryForm),
        ("went", "go", .dictionaryForm),
        ("colour", "color", .otherHeadword),
        ("转瞬即逝", "转瞬即逝", .exact),
    ])
    func anEntryKnowsHowItMatchesTheTerm(term: String, headword: String, match: DictionaryEntry.Match) {
        #expect(DictionaryEntry(dictionary: "D", headword: headword, lookedUp: term, html: "<p/>").match == match)
    }

    /// Found by the verifier: a dictionary that named no headword had the term put in its place and
    /// the entry called exact.
    @Test func aMissingHeadwordIsNotCalledExact() {
        let entry = DictionaryEntry(dictionary: "D", headword: nil, lookedUp: "ephemeral", html: "<p/>")
        #expect(entry.match == .headwordUnknown)
        #expect(entry.headword == "ephemeral")
    }
}
