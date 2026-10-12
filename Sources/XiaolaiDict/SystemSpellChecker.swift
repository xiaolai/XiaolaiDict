import AppKit
import XiaolaiDictBase
import XiaolaiDictCore
import os

/// **`NSSpellChecker`, as a lookup asks it** — the one file that names AppKit's spell checker
/// (plan-spelling-suggestion §3).
///
/// **Main-actor isolated, as AppKit requires**, and asked one word at a time: a correction is a few milliseconds on the
/// main thread, asked after the miss is already on the card, so the reader never waits for it.
///
/// **`correction(forWordRange:…)` and nothing else — never `guesses`.** The guess list is ranked for a reader choosing
/// from it, and it is wrong or noise exactly where the correction is silent: `rn` guesses `Ron`, `arid` guesses `acid`,
/// `cabbages` guesses `cabbage` (measured 2026-10-09). No suggestion beats a wrong one.
@MainActor
final class SystemSpellChecker: SpellingSuggesting {
    private let checker: NSSpellChecker
    /// **A spell document of this checker's own**, from `uniqueSpellDocumentTag()` — never the shared 0. What a reader
    /// told the checker to ignore in some other document is that document's business, and a lookup's questions are not
    /// theirs. Read by a test.
    let tag: Int
    /// The languages the checker can be asked in — its own list, unless a test names one, so the fallback a missing
    /// variant takes is tested on every Mac rather than only on one that lacks it.
    private let languages: @MainActor () -> [String]

    init(checker: NSSpellChecker = .shared, languages: (@MainActor () -> [String])? = nil) {
        self.checker = checker
        self.languages = languages ?? { checker.availableLanguages }
        tag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    /// The document is the checker's to forget, and it is forgotten with the adapter that opened it.
    isolated deinit { checker.closeSpellDocument(withTag: tag) }

    /// In the reader's English where the checker has it, plain English otherwise, and **nothing where it has no
    /// English at all** — `SpellingLanguage.checker` decides, against the languages this checker lists.
    func suggestion(for term: String, language: String?) async -> String? {
        let available = languages()
        guard let asked = SpellingLanguage.checker(for: language, available: available) else {
            log.notice("spelling: the checker has no English among \(available.count, privacy: .public) languages")
            return nil
        }
        let answer = checker.correction(
            forWordRange: NSRange(location: 0, length: (term as NSString).length), in: term,
            language: asked, inSpellDocumentWithTag: tag)
        // **What it was asked in and what kind of answer it gave — never a word**: the term is the reader's reading.
        let kind = answer == nil ? "nothing" : answer?.compare(term, options: .caseInsensitive) == .orderedSame
            ? "the word again" : "another word"
        log.notice("spelling: the checker, asked in \(asked, privacy: .public) of \(available.count, privacy: .public) languages, answered \(kind, privacy: .public)")
        return answer
    }

    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "lookup")
}
