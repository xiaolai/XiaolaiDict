import Foundation
import Testing
import XiaolaiDictTestSupport

/// **An end-to-end assertion that greps for text the app no longer says cannot fail — it goes
/// vacuous.** `Tools/e2e.sh` reads surfaces through Accessibility and asserts on their words. When a
/// view's wording changes and the script does not, the `grep` stops matching, that branch is never
/// taken, and the stage goes on passing: the assertion is not red, it is *absent*.
///
/// `AGENTS.md` already records this happening — "when the lookup panel became a card with no lemma
/// row and no WebKit page, the shortcut and deadline stages went on waiting for `→ meet`" — and the
/// rule it left behind was to grep `Tools/e2e.sh` by hand in the same change. **It happened again on
/// 2026-09-26**, when the too-little-memory row was reworded to name the requirement and the setup
/// stage went on looking for the old sentence. Two instances of one shape is a class, so this is the
/// mechanical check rather than a third reminder.
///
/// It is deliberately the *opposite* direction from `StringCatalogTests`. That one asks whether
/// everything the reader sees has a key; this asks whether everything the harness looks for is still
/// something the reader sees.
struct EndToEndTextTests {
    private static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // XiaolaiDictTests
            .deletingLastPathComponent()                             // Tests
            .deletingLastPathComponent()                             // the repository
    }

    private static var scriptURL: URL { repository.appendingPathComponent("Tools/e2e.sh") }

    // MARK: - Pulling the phrases out of the script

    /// **Every spelling the script matches text with**, because a scan is only as wide as the
    /// spellings it knows — the same defect as a source scan that names one directory. Three exist
    /// in `Tools/e2e.sh` today, and each takes either quote:
    ///
    /// | Spelling | Example |
    /// |---|---|
    /// | a `grep` pattern, with any flags | `grep -q "Not now"` |
    /// | a `case` glob | `*"did not answer"*` |
    /// | Python's `in` | `"drawn" in texts` |
    ///
    /// A fourth would be invisible here, which is why `everyMatcherSpellingInTheScriptIsKnown`
    /// counts what these find against the number of matcher calls in the file.
    private static let matchers = [
        #"grep\s+(?:-[A-Za-z0-9]+\s+)*(?:"((?:[^"\\\n]|\\.)*)"|'([^'\n]*)')"#,
        #"\*(?:"((?:[^"\\\n]|\\.)*)"|'([^'\n]*)')\*"#,
        #"(?:"((?:[^"\\\n]|\\.)*)"|'([^'\n]*)')\s+in\s"#,
    ]

    /// The script with full-line comments dropped: a phrase discussed in a comment is not an
    /// assertion, and the comments here quote old wording on purpose.
    private static func script() throws -> String {
        try String(contentsOf: scriptURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    /// The literals in matcher position that **look like something a reader is shown**: two or more
    /// words, opening with a letter, carrying a lowercase one, and free of the shell, JSON and regex
    /// machinery that marks a pattern as being about the harness's own plumbing rather than about
    /// the app's words.
    ///
    /// Two words and not four, because the shortest ones are the likeliest to be reworded: `Not
    /// now`, `misreads some`, `download stopped`. One word is not enough to be sure it is prose.
    private static func phrases(in script: String) throws -> Set<String> {
        var found: Set<String> = []
        for pattern in matchers {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(script.startIndex..., in: script)
            for match in regex.matches(in: script, range: range) {
                for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                    guard let r = Range(match.range(at: group), in: script) else { continue }
                    let text = String(script[r])
                    if isProse(text) { found.insert(text) }
                }
            }
        }
        return found
    }

    private static func isProse(_ text: String) -> Bool {
        guard text.split(separator: " ").count >= 2 else { return false }
        guard let first = text.first, first.isLetter else { return false }
        guard text.contains(where: \.isLowercase) else { return false }
        // `$` `{` `[` `|` `\` `<` `=` and friends are shell expansion, JSON structure or regex
        // alternation — a pattern carrying one is about the plumbing, not about a sentence.
        return !text.contains { "${}[]|\\<>=".contains($0) }
    }

    // MARK: - The corpus the phrases must still be in

    /// Everything the app can show, comments stripped. **Stripped because a comment recording an old
    /// wording would otherwise keep a stale assertion green** — which is precisely the failure this
    /// test is about, since the comment beside a reworded string usually quotes what it used to say.
    ///
    /// `Sources` alone, not `Tools`: text a helper prints is the harness talking to itself, and
    /// admitting it would let an assertion pass because the script echoes its own vocabulary.
    private static func readerText() throws -> String {
        try SourceScan.code(under: repository.appendingPathComponent("Sources"))
            .map(\.code).joined(separator: "\n")
    }

    /// A phrase spanning a `\(…)` interpolation, or supplied by the harness itself, cannot be found
    /// verbatim in `Sources`. **Each exemption names what must exist instead, so it is a narrower
    /// check rather than a hole** — and `everyExemptionIsStillNeeded` fails once a phrase can be
    /// found the ordinary way, so the table cannot quietly outlive its reason.
    private static let exemptions: [(phrase: String, because: String, insteadRequire: [String])] = [
        (phrase: "Downloading Qwen3.5",
         because: """
             it spans an interpolation: the row writes `Downloading \\(size.displayName)`, and the \
             name comes from the catalogue. Neither half contains the phrase.
             """,
         insteadRequire: ["Text(\"Downloading \\(size.displayName)", "\"Qwen3.5 \\(parameters)\""]),
        (phrase: "stopped meeting at noon",
         because: """
             it is the harness's own sentence, typed into TextEdit by the script and expected back \
             out of the panel — not something the app ever says. Requiring the script to contain it \
             outside a matcher is what keeps the sentence typed and the sentence asserted the same.
             """,
         insteadRequire: []),
    ]

    // MARK: - The checks

    @Test func everyPhraseTheHarnessLooksForIsStillSomethingTheAppSays() throws {
        let text = try Self.readerText()
        let exempt = Set(Self.exemptions.map(\.phrase))
        var stale: [String] = []
        for phrase in try Self.phrases(in: Self.script()).sorted() where !exempt.contains(phrase) {
            // `.*` in a grep pattern is a wildcard; every literal piece around it must be there.
            let pieces = phrase.components(separatedBy: ".*").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !pieces.allSatisfy(text.contains) { stale.append(phrase) }
        }
        #expect(stale.isEmpty, """
            Tools/e2e.sh asserts on wording no source file contains: \(stale.map { "\u{201c}\($0)\u{201d}" }.joined(separator: ", ")).
            Those greps cannot match, so their stage branches are never taken and never fail.
            Move the assertion onto the new wording, or add an exemption naming what must exist instead.
            """)
    }

    /// **An exemption that is no longer needed is a hole nobody notices.** Checked in both
    /// directions: each exempt phrase must genuinely be unfindable, and whatever it points at
    /// instead must be findable.
    @Test func everyExemptionIsStillNeededAndWhatItPointsAtExists() throws {
        let text = try Self.readerText()
        let script = try Self.script()
        for exemption in Self.exemptions {
            #expect(!text.contains(exemption.phrase), """
                \u{201c}\(exemption.phrase)\u{201d} is in Sources now, so its exemption is a hole — delete the row.
                """)
            for required in exemption.insteadRequire {
                #expect(text.contains(required), """
                    \u{201c}\(exemption.phrase)\u{201d} is exempt because \(exemption.because)
                    But \u{201c}\(required)\u{201d} is not in Sources any more, so the exemption now covers nothing.
                    """)
            }
            if exemption.insteadRequire.isEmpty {
                // The harness's own data: it has to appear somewhere in the script that is not a
                // matcher, or the thing asserted was never the thing supplied.
                let uses = script.components(separatedBy: exemption.phrase).count - 1
                #expect(uses >= 2, """
                    \u{201c}\(exemption.phrase)\u{201d} is exempt as the harness's own text, but appears \
                    \(uses) time(s) in Tools/e2e.sh — it must be supplied somewhere as well as asserted.
                    """)
            }
        }
    }

    /// **The phrase list must not be able to go quietly empty.** A regex that stopped matching, a
    /// script that moved, or a prose filter tightened too far would each leave every assertion above
    /// passing over nothing.
    @Test func theScanFindsPhrasesAtAll() throws {
        let phrases = try Self.phrases(in: Self.script())
        #expect(phrases.count >= 12, "only \(phrases.count) reader phrases found in Tools/e2e.sh")
        #expect(phrases.contains("Not now"), "a phrase known to be asserted was not extracted")
    }

    /// **And the matcher list must be as wide as the script.** Counted rather than assumed: a fourth
    /// way of matching text — `awk`, `expr`, a bare `[[ … =~ … ]]` — would be invisible to the
    /// extraction above, and every phrase behind it unguarded.
    ///
    /// The floor is the number of *matcher calls* the spellings account for, not the number of
    /// phrases: most matchers test JSON or a flag rather than prose, and those are not this test's
    /// business. A `grep` count that climbs well past what the patterns find is the signal that a
    /// spelling has been added.
    @Test func everyMatcherSpellingInTheScriptIsKnown() throws {
        let script = try Self.script()
        let greps = script.components(separatedBy: "grep ").count - 1
        let regex = try NSRegularExpression(pattern: Self.matchers[0])
        let seen = regex.numberOfMatches(in: script, range: NSRange(script.startIndex..., in: script))
        // Every `grep` in the script either takes a quoted pattern, a `-f` file of patterns, or a
        // shell variable. If the quoted ones stop being the bulk of them, the extraction has gone
        // blind to however they are being written now.
        #expect(seen * 2 >= greps, """
            \(greps) greps in Tools/e2e.sh but only \(seen) with a quoted pattern this test can read \
            — a new spelling has appeared, and the phrases behind it are unguarded.
            """)
    }
}
