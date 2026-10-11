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
    ///
    /// **An entry is headed as its dictionary heads it and carries its blocks' parts of speech** — what a regular
    /// dictionary form's offer is judged by (`DictionaryForm.isSupported(by:)`): *France* is not *france*, and a noun
    /// has no comparative. `init(_:)` gives each word a lowercase heading and no sense structure, a dictionary like the
    /// sideloaded ones that marks no part of speech.
    final class Dictionaries: Sendable {
        /// One entry: its headword as printed, and one block per part of speech — none for an unstructured entry.
        struct Headed: Sendable {
            let headword: String
            let partsOfSpeech: [String]
            init(_ headword: String, _ partsOfSpeech: [String] = []) {
                self.headword = headword
                self.partsOfSpeech = partsOfSpeech
            }
        }

        private let entries: [String: [Headed]]
        private let asked = Mutex<[String]>([])
        init(_ words: Set<String>) {
            entries = Dictionary(uniqueKeysWithValues: words.map { ($0, [Headed($0)]) })
        }
        /// Each looked-up word with the entries it is answered with.
        init(entries: [String: [Headed]]) { self.entries = entries }
        var questions: [String] { asked.withLock { $0 } }
        func lookUp(_ term: String) throws(CancellationError) -> LookupOutcome {
            asked.withLock { $0.append(term) }
            guard let headed = entries[term], !headed.isEmpty else { return .notFound(serviceFailure: nil) }
            let found = headed.enumerated().map { index, entry in
                let document = entry.partsOfSpeech.isEmpty ? nil : EntryDocument(
                    isStyled: true, entryID: "e\(index)", homograph: nil,
                    blocks: entry.partsOfSpeech.enumerated().map {
                        SenseBlock(number: $0.offset + 1, partOfSpeech: $0.element, senses: [])
                    })
                return DictionaryEntry(dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad"),
                                       headword: entry.headword, lookedUp: term, html: "<p/>", document: document)
            }
            return .entries(NonEmpty(found)!, unreadable: [])
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
        let the = SpellingSuggestion(term: "teh", word: "the", evidence: .correction(.transposition))
        #expect(offer == .offered(the))
        #expect(offer.suggestion == the)
        #expect(checker.questions == ["teh"])
        #expect(checker.askedIn == ["en-GB"], "the checker was not asked in the reader's English")
        #expect(dictionaries.questions == ["the"])
    }

    /// **Verify before offering** (§2, conclusion 2): a correction the reader's dictionaries do not have is never
    /// offered — the checker knowing a word says nothing about the dictionaries.
    @Test func aCorrectionNoDictionaryHasIsNotOffered() async throws {
        let checker = Checker(["mochii": "mochi"]), dictionaries = Dictionaries(["the"])
        let offer = try await suggester(checker, dictionaries).offer(for: "mochii", outcome: Self.miss)
        #expect(offer == .abstained(.unverified))
        #expect(offer.suggestion == nil)
        #expect(dictionaries.questions == ["mochi"], "the dictionaries were not asked before the offer was refused")
    }

    /// **No confident correction, or the term again up to case, is none — and costs the dictionaries nothing.**
    @Test func noCorrectionAsksTheDictionariesNothing() async throws {
        let checker = Checker(["teh": "TEH"]), dictionaries = Dictionaries(["teh", "TEH"])
        #expect(try await suggester(checker, dictionaries).offer(for: "teh", outcome: Self.miss)
                == .abstained(.noCandidate))
        #expect(try await suggester(checker, dictionaries).offer(for: "ambages", outcome: Self.miss)
                == .abstained(.noCandidate))
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
