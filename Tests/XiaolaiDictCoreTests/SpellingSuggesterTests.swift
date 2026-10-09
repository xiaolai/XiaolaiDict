import DictionaryModel
import Synchronization
import Testing
import XiaolaiDictBase
import XiaolaiDictCore

/// **Miss → correction → verified → offered**, the one path to a suggestion (plan-spelling-suggestion §3), against a
/// checker and dictionaries of the test's own — so what is asked, and in what order, is counted rather than inferred.
struct SpellingSuggesterTests {
    /// A checker that answers from a table and remembers every question it was asked, with its language.
    final class Checker: SpellingSuggesting {
        private let answers: [String: String]
        private let onAsk: @Sendable () -> Void
        private let asked = Mutex<[String]>([])
        private let languages = Mutex<[String?]>([])
        init(_ answers: [String: String], onAsk: @escaping @Sendable () -> Void = {}) {
            self.answers = answers
            self.onAsk = onAsk
        }
        var questions: [String] { asked.withLock { $0 } }
        var askedIn: [String?] { languages.withLock { $0 } }
        func suggestion(for term: String, language: String?) async -> String? {
            asked.withLock { $0.append(term) }
            languages.withLock { $0.append(language) }
            onAsk()
            return answers[term]
        }
    }

    /// Dictionaries that have the words they are given, and remember every word they were asked about.
    final class Dictionaries: Sendable {
        private let words: Set<String>
        private let asked = Mutex<[String]>([])
        init(_ words: Set<String>) { self.words = words }
        var questions: [String] { asked.withLock { $0 } }
        func lookUp(_ term: String) throws(CancellationError) -> LookupOutcome {
            asked.withLock { $0.append(term) }
            guard words.contains(term) else { return .notFound(serviceFailure: nil) }
            let entry = DictionaryEntry(dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad"),
                                        headword: term, lookedUp: term, html: "<p/>", document: nil)
            return .entries(NonEmpty([entry])!, unreadable: [])
        }
    }

    private static let miss = LookupOutcome.notFound(serviceFailure: nil)

    private func suggester(_ checker: Checker, _ dictionaries: Dictionaries, english: String? = "en-GB") -> SpellingSuggester {
        SpellingSuggester(checker: checker, lookUp: { term throws(CancellationError) in try dictionaries.lookUp(term) },
                          language: { english })
    }

    /// **The whole path**: the checker is asked the trimmed word in the reader's English, the dictionaries are asked
    /// the checker's word, and the offer names the term as the reader looked it up.
    @Test func aVerifiedCorrectionIsOffered() async throws {
        let checker = Checker(["teh": "the"]), dictionaries = Dictionaries(["the"])
        let offer = try await suggester(checker, dictionaries).offer(for: "teh", outcome: Self.miss)
        #expect(offer == .offered(SpellingSuggestion(term: "teh", word: "the")))
        #expect(offer.suggestion == SpellingSuggestion(term: "teh", word: "the"))
        #expect(checker.questions == ["teh"])
        #expect(checker.askedIn == ["en-GB"], "the checker was not asked in the reader's English")
        #expect(dictionaries.questions == ["the"])
    }

    /// **Verify before offering** (§2, conclusion 2): a correction the reader's dictionaries do not have is never
    /// offered — the checker knowing a word says nothing about the dictionaries.
    @Test func aCorrectionNoDictionaryHasIsNotOffered() async throws {
        let checker = Checker(["mochii": "mochi"]), dictionaries = Dictionaries(["the"])
        let offer = try await suggester(checker, dictionaries).offer(for: "mochii", outcome: Self.miss)
        #expect(offer == .unverified("mochi"))
        #expect(offer.suggestion == nil)
        #expect(dictionaries.questions == ["mochi"], "the dictionaries were not asked before the offer was refused")
    }

    /// **No confident correction, or the term again up to case, is none — and costs the dictionaries nothing.**
    @Test func noCorrectionAsksTheDictionariesNothing() async throws {
        let checker = Checker(["teh": "TEH"]), dictionaries = Dictionaries(["teh", "TEH"])
        #expect(try await suggester(checker, dictionaries).offer(for: "teh", outcome: Self.miss)
                == .noCorrection)
        #expect(try await suggester(checker, dictionaries).offer(for: "ambages", outcome: Self.miss)
                == .noCorrection)
        #expect(checker.questions == ["teh", "ambages"])
        #expect(dictionaries.questions.isEmpty)
    }

    /// **A refused lookup asks nobody**: neither the checker nor the dictionaries hear of a found word, a fallback, a
    /// service failure, a phrase or CJK.
    @Test func aRefusedLookupAsksNobody() async throws {
        let checker = Checker(["teh": "the"]), dictionaries = Dictionaries(["the"])
        let suggester = suggester(checker, dictionaries)
        let found = try dictionaries.lookUp("the")
        let cases: [(String, LookupOutcome?, SpellingEligibility.Refusal)] = [
            ("teh", found, .notAMiss),
            ("teh", .plainText("prose", serviceFailure: "crashed"), .notAMiss),
            ("teh", nil, .notAMiss),
            ("teh", .notFound(serviceFailure: "crashed"), .serviceUnanswered),
            ("teh cat", Self.miss, .notOneWord),
            ("水", Self.miss, .notLatinLetters),
        ]
        let before = dictionaries.questions.count
        for (term, outcome, refusal) in cases {
            #expect(try await suggester.offer(for: term, outcome: outcome) == .refused(refusal))
        }
        #expect(checker.questions.isEmpty, "a refused lookup asked the checker: \(checker.questions)")
        #expect(dictionaries.questions.count == before, "a refused lookup asked the dictionaries")
    }

    /// **Cancelled while the checker answered, the dictionaries are never asked.** The checker cannot be stopped; the
    /// lookup that would verify its answer can, and a newer lookup must not cost the service one nobody will see.
    @Test func aLookupCancelledWhileTheCheckerAnswersNeverAsksTheDictionaries() async {
        let dictionaries = Dictionaries(["the"])
        // The checker cancels the task asking it — the reader pressing again while it answered.
        let checker = Checker(["teh": "the"]) { withUnsafeCurrentTask { $0?.cancel() } }
        let suggester = suggester(checker, dictionaries)
        await #expect(throws: CancellationError.self) {
            _ = try await suggester.offer(for: "teh", outcome: Self.miss)
        }
        #expect(checker.questions == ["teh"])
        #expect(dictionaries.questions.isEmpty, "a cancelled offer asked the dictionaries")
    }
}
