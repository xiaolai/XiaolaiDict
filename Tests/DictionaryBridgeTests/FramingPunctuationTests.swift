@testable import DictionaryBridge
import DictionaryModel
import Foundation
import Testing

/// A term that arrives with the punctuation that framed it on the page — `hold.`, `(hold)`, `“hold”` —
/// is answered as `hold` **when, and only when, the term as written had no answer.**
///
/// Measured 2026-10-05 on this Mac through the private API: `hold.`, `(hold)` and `“hold”` were
/// notFound while `hold—`, `don’t` and `e-mail` were found, so what the dictionaries accept at the
/// edge is a fact about each dictionary and not a rule this code can guess. The term as written is
/// therefore asked first, and the bare one only on a miss.
///
/// The hover path never meets this — it cuts words with `NLTokenizer`, which drops edge punctuation —
/// but the selection shortcut is deliberately unfiltered, so a drag that took the full stop with the
/// word reaches the service as written.
struct FramingPunctuationTests {
    // MARK: - What counts as framing

    /// **The framing comes off in layers, least first**, so a term whose own punctuation is part of the word is tried with
    /// that punctuation before it is tried without (audit finding 1): `(U.S.)` is `U.S.` before it is `U.S`, `“.NET”` is `.NET`
    /// before `NET`, `“'tis”` is `'tis` before `tis`.
    struct Layered: Sendable, CustomTestStringConvertible {
        let term: String
        let candidates: [String]
        var testDescription: String { term }
    }

    /// **One mark off per layer, the least stripped first**, so every intermediate form is tried — `(Dr.,)` is `Dr.,`, then
    /// `Dr.`, then `Dr`; `(example.com.)` is `example.com.` then `example.com` — and what a word begins with, `.NET` and
    /// `'tis`, is never taken off the start. The cost of trying each is one lookup, and only on a miss.
    static let layered: [Layered] = [
        Layered(term: "(U.S.)", candidates: ["U.S.", "U.S"]),
        Layered(term: "“.NET”", candidates: [".NET"]),
        Layered(term: "“'tis”", candidates: ["'tis"]),
        Layered(term: "\".NET", candidates: [".NET"]),
        Layered(term: "\"'tis", candidates: ["'tis"]),
        Layered(term: "hold.", candidates: ["hold"]),
        Layered(term: "(hold)", candidates: ["hold"]),
        Layered(term: "“hold”", candidates: ["hold"]),
        Layered(term: "\"hold\"", candidates: ["hold"]),
        Layered(term: "'hold'", candidates: ["hold"]),
        Layered(term: "“hold.”", candidates: ["hold.", "hold"]),
        Layered(term: "(U.S.).", candidates: ["(U.S.)", "U.S.", "U.S"]),
        Layered(term: "[hold];", candidates: ["[hold]", "hold"]),
        Layered(term: "hold?!", candidates: ["hold?", "hold"]),
        Layered(term: "hold…", candidates: ["hold"]),
        Layered(term: "hold...", candidates: ["hold..", "hold.", "hold"]),
        Layered(term: "—hold—", candidates: ["hold"]),
        Layered(term: "‘hold’,", candidates: ["‘hold’", "hold"]),
        Layered(term: "  hold.  ", candidates: ["hold"]),
        Layered(term: "水。", candidates: ["水"]),
        Layered(term: "「水」", candidates: ["水"]),
        Layered(term: "((hold))", candidates: ["(hold)", "hold"]),
        Layered(term: "hold)", candidates: ["hold"]),
        Layered(term: "(hold", candidates: ["hold"]),
        Layered(term: "a.b,", candidates: ["a.b"]),
        Layered(term: "U.S.,", candidates: ["U.S.", "U.S"]),
        Layered(term: "e.g.:", candidates: ["e.g.", "e.g"]),
        Layered(term: ".gitignore.", candidates: [".gitignore"]),
        Layered(term: "'tis,", candidates: ["'tis"]),
        Layered(term: "...hold", candidates: [".hold", "hold"]),
        Layered(term: "…hold", candidates: ["hold"]),
        Layered(term: "\"hold", candidates: ["hold"]),
        // The inputs the verification found the first versions got wrong: a chain that peels in the wrong order skips a form.
        // A run of the mark a word may begin with is an ellipsis, a word's own first mark, or both: `....NET`.
        Layered(term: "....NET", candidates: [".NET", "NET"]),
        Layered(term: "’em,", candidates: ["’em"]),
        Layered(term: "(U.S.", candidates: ["U.S.", "(U.S", "U.S"]),
        Layered(term: "(U.S..)", candidates: ["U.S..", "U.S.", "U.S"]),
        Layered(term: "(Dr.,)", candidates: ["Dr.,", "Dr.", "Dr"]),
        Layered(term: "(example.com.)", candidates: ["example.com.", "example.com"]),
    ]

    @Test(arguments: layered)
    func framingComesOffInLayers(_ layered: Layered) {
        #expect(DictionaryBridge.framingCandidates(layered.term) == layered.candidates)
    }

    /// Nothing inside is touched, and nothing that is part of the word is taken off the end.
    @Test(arguments: [
        "hold", "don’t", "e-mail", "a.b", "U.S", "C++", "C#", "@home", "100%", "$5", "x=y",
    ])
    func whatIsPartOfTheWordIsLeftAlone(term: String) {
        #expect(DictionaryBridge.framingCandidates(term).isEmpty, "\(term) lost a character that belongs to it")
    }

    /// Punctuation alone has no word to fall back to, and a blank is the caller's refusal to make.
    @Test(arguments: ["...", "()", "“”", "—", "", "   ", "((", "?!"])
    func nothingIsLeftToLookUp(term: String) {
        #expect(DictionaryBridge.framingCandidates(term).isEmpty)
    }

    /// However much is wrapped, the number of extra lookups a miss can cost is bounded.
    @Test func theNumberOfExtraLookupsIsBounded() {
        let wrapped = String(repeating: "(", count: 40) + "hold" + String(repeating: ")", count: 40)
        #expect(DictionaryBridge.framingCandidates(wrapped).count <= DictionaryBridge.maximumFramingCandidates)
    }

    // MARK: - The order of asking

    /// A stand-in for the framework that records what it was asked, so the order is checked without
    /// a dictionary deciding it.
    private final class Recorder: @unchecked Sendable {
        private(set) var asked: [String] = []
        private let answers: [String: DictionaryLookup]

        init(answering answers: [String: DictionaryLookup] = [:]) { self.answers = answers }

        func lookUp(_ term: String) -> DictionaryLookup {
            asked.append(term)
            return answers[term] ?? DictionaryLookup(entries: [], unreadable: [])
        }
    }

    private static func lookup(_ term: String) -> DictionaryLookup {
        DictionaryLookup(
            entries: [DictionaryEntry(
                dictionary: DictionaryIdentity(name: "Test"),
                headword: term, lookedUp: term, html: "<p>\(term)</p>", document: nil)],
            unreadable: [])
    }

    /// **The term as written is asked first and, answered, is the whole lookup.** `U.S.` and `e.g.` carry
    /// their full stops in the dictionary's own key; trimming before asking would lose them.
    @Test func theTermAsWrittenComesFirstAndStopsThere() throws {
        let framework = Recorder(answering: ["U.S.": Self.lookup("U.S.")])
        let answered = try DictionaryBridge.lookUp("U.S.", using: framework.lookUp)
        #expect(framework.asked == ["U.S."])
        #expect(answered.entries.count == 1)
    }

    /// A miss is asked again with the framing taken off a layer at a time, and the first answer ends it.
    @Test func aMissIsAskedAgainOneLayerAtATime() throws {
        let framework = Recorder(answering: ["hold": Self.lookup("hold")])
        let answered = try DictionaryBridge.lookUp("“hold.”", using: framework.lookUp)
        #expect(framework.asked == ["“hold.”", "hold.", "hold"])
        #expect(answered.entries.map(\.headword) == ["hold"])
    }

    /// **Punctuation that belongs to the word is tried before it is taken off**: `(U.S.)` finds `U.S.` and is never asked as `U.S`.
    @Test func lexicalPunctuationIsTriedBeforeItIsStripped() throws {
        let framework = Recorder(answering: ["U.S.": Self.lookup("U.S."), "U.S": Self.lookup("U.S")])
        let answered = try DictionaryBridge.lookUp("(U.S.)", using: framework.lookUp)
        #expect(framework.asked == ["(U.S.)", "U.S."])
        #expect(answered.entries.map(\.headword) == ["U.S."])
    }

    /// Where every layer misses the answer is a miss, and every layer was asked once.
    @Test func aMissThatStaysAMissAsksEachLayerOnce() throws {
        let framework = Recorder()
        let answered = try DictionaryBridge.lookUp("“qzxq.”", using: framework.lookUp)
        #expect(framework.asked == ["“qzxq.”", "qzxq.", "qzxq"])
        #expect(answered.entries.isEmpty)
    }

    /// A term with no framing is asked once: there is nothing to try.
    @Test func aBareTermIsAskedOnce() throws {
        let framework = Recorder()
        _ = try DictionaryBridge.lookUp("qzxq", using: framework.lookUp)
        #expect(framework.asked == ["qzxq"])
    }

    /// **An unreadable entry is an answer, not a miss.** The dictionary had the term and could not show
    /// it; asking again with less would report a word the reader did not select.
    @Test func anUnreadableAnswerIsNotRetried() throws {
        let unreadable = DictionaryLookup(entries: [], unreadable: ["Test"])
        let framework = Recorder(answering: ["hold.": unreadable])
        let answered = try DictionaryBridge.lookUp("hold.", using: framework.lookUp)
        #expect(framework.asked == ["hold."])
        #expect(answered.unreadable == ["Test"])
        // ...and one a later layer finds ends the asking there, with the reader told which dictionary could not show it.
        let later = Recorder(answering: ["hold.": unreadable])
        let reached = try DictionaryBridge.lookUp("“hold.”", using: later.lookUp)
        #expect(later.asked == ["“hold.”", "hold."])
        #expect(reached.unreadable == ["Test"])
    }

    // MARK: - Through the framework

    /// The defect itself, against the dictionaries on this Mac: `hold.` was notFound.
    @Test func aWordWithItsFullStopIsFound() throws {
        let plain = DictionaryBridge.reply(to: LookupRequest(term: "hold"))
        let framed = DictionaryBridge.reply(to: LookupRequest(term: "hold."))
        guard case .entries(let found, _) = framed else {
            Issue.record("hold. was not answered: \(framed)")
            return
        }
        guard case .entries(let expected, _) = plain else {
            Issue.record("hold was not answered: \(plain)")
            return
        }
        #expect(found.map(\.entryID) == expected.map(\.entryID), "the framed term must answer as the bare one does")
        #expect(found.allSatisfy { $0.match == .exact }, "an answer to the bare word is not another headword")
    }

    /// **An abbreviation inside brackets is the abbreviation** (audit finding 1), through the dictionaries on this Mac:
    /// `(U.S.)` answers as `U.S.` — the same entries, never a different word it was stripped down to.
    @Test func aFramedAbbreviationKeepsItsStops() throws {
        let plain = DictionaryBridge.reply(to: LookupRequest(term: "U.S."))
        let framed = DictionaryBridge.reply(to: LookupRequest(term: "(U.S.)"))
        guard case .entries(let expected, _) = plain else {
            Issue.record("U.S. was not answered on this Mac: \(plain)")
            return
        }
        guard case .entries(let found, _) = framed else {
            Issue.record("(U.S.) was not answered: \(framed)")
            return
        }
        #expect(found.map(\.entryID) == expected.map(\.entryID))
        #expect(found.map(\.match) == expected.map(\.match), "the framed term is annotated exactly as the bare one is")
        #expect(found.map(\.headword) == expected.map(\.headword))
    }

    @Test func aFramedMissIsStillAMiss() {
        #expect(DictionaryBridge.reply(to: LookupRequest(term: "qzxqzxqzxqzx.")) == .notFound)
    }
}
