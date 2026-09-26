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
    /// **What this cannot see, stated rather than implied:** a text assertion written with `awk`,
    /// `sed` or `[[ … =~ … ]]` is invisible to all three, and `everyGrepInTheScriptIsOneThisTestCanRead`
    /// inventories `grep` alone — so migrating a check to another tool would take its phrase out of
    /// the scan without failing anything. `theScanFindsPhrasesAtAll`'s floor is the partial guard:
    /// set just under the real count, it catches a wholesale move but not a single one.
    ///
    /// A fourth would be invisible here, which is why `everyGrepInTheScriptIsOneThisTestCanRead`
    /// accounts for every `grep` in the file rather than trusting this list.
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
                    // **An alternation is several phrases.** `grep -qE 'Looking up|No entry for|could
                    // not be asked'` is three reader sentences, and treating the pattern as one blob
                    // meant `|` reached `isProse`, which rejects it — so all three went unguarded.
                    // **The trimmed form is what gets inserted, not the raw one.** Trimming inside
                    // `isProse` alone let `^Old reader text` through to the corpus check, which then
                    // demanded the caret in `Sources` and failed against correct wording — a fix that
                    // turned a silent gap into a false alarm.
                    for alternative in String(script[r]).components(separatedBy: "|") {
                        let phrase = trimmingRegexEdges(alternative)
                        if isProse(phrase) { found.insert(phrase) }
                    }
                }
            }
        }
        return found
    }

    /// Strips the regex punctuation a pattern wraps a sentence in — `^`, `$` and grouping
    /// parentheses — so the sentence inside can be compared with what the app says.
    ///
    /// Both were found by an adversarial reader, one after the other: `'^Old reader text|^Gone reader
    /// text'` was inventoried and yielded no phrases because of the carets, and
    /// `'^(Old reader text)|^(Gone reader text)'` did the same again once only the carets were trimmed.
    private static func trimmingRegexEdges(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "^$()"))
    }

    private static func isProse(_ text: String) -> Bool {
        let text = trimmingRegexEdges(text)
        guard text.split(separator: " ").count >= 2 else { return false }
        guard let first = text.first, first.isLetter else { return false }
        guard text.contains(where: \.isLowercase) else { return false }
        // `$` `{` `[` `\` `<` `=` and friends are shell expansion or JSON structure — a pattern
        // carrying one is about the plumbing, not about a sentence. **`|` is not in that set**: in a
        // `grep -E` pattern it separates alternatives that are each a real sentence, and rejecting
        // the whole pattern silently dropped three reader phrases at `Tools/e2e.sh`'s waiting-panel
        // check. `phrases(in:)` splits on it instead, so each alternative is guarded on its own.
        return !text.contains { "${}[]\\<>=".contains($0) }
    }

    // MARK: - The corpus the phrases must still be in

    /// Everything the app can show, **every** comment stripped. Stripped because a comment recording
    /// an old wording would otherwise keep a stale assertion green — which is precisely the failure
    /// this test is about, since the comment beside a reworded string usually quotes what it used to
    /// say.
    ///
    /// **`SourceScan.code` is not enough, and believing it was is how this promise came to be false.**
    /// It drops a line whose *trimmed* text begins with `//`, which leaves a trailing `let x = 1 //
    /// "the old sentence"` and every `/* … */` block in the corpus. The doc comment above claimed the
    /// opposite for a day. `strippingComments` finishes the job here rather than in `SourceScan`,
    /// because the other scanners that use it are looking for API names — where a full-line filter is
    /// right and a literal-preserving tokeniser would be more machinery than they need.
    ///
    /// `Sources` alone, not `Tools`: text a helper prints is the harness talking to itself, and
    /// admitting it would let an assertion pass because the script echoes its own vocabulary.
    private static func readerText() throws -> String {
        let files = try SourceScan.code(under: repository.appendingPathComponent("Sources"))
        // **Refuse input the scanner cannot parse, rather than mis-parsing it quietly.** A multiline
        // literal interpolating another multiline literal — `\("""` inside `"""` — is valid Swift and
        // desynchronises the scanner below, after which every later comment survives as code and a
        // stale assertion reads as green. Supporting it means tracking interpolation depth; refusing
        // it costs one check and fails loudly on the day someone writes one. Measured 2026-09-26:
        // zero occurrences in `Sources`, so this is a guard and not a restriction on anybody.
        let unparseable = files.filter { $0.code.contains(#"\(""""#) }.map(\.file.lastPathComponent)
        guard unparseable.isEmpty else {
            throw Failure.tooHardToParse(files: unparseable)
        }
        return files.map { strippingComments(from: $0.code) }.joined(separator: "\n")
    }

    enum Failure: Error, CustomStringConvertible {
        case tooHardToParse(files: [String])

        var description: String {
            switch self {
            case .tooHardToParse(let files):
                """
                \(files.joined(separator: ", ")) interpolate a multiline string inside a multiline \
                string, which this test's comment scanner cannot follow — it would read the nested \
                opener as the outer closer and keep every later comment. Teach `strippingComments` \
                interpolation depth, or write that sentence another way.
                """
            }
        }
    }

    /// Removes `//` and `/* … */` comments **while keeping string literals intact**, which is the
    /// whole difficulty: `Text("https://example.com")` holds a `//` that is not a comment, and a
    /// naive strip would cut the sentence this test exists to find.
    ///
    /// A small hand-rolled scanner rather than a regex, because the two states — inside a literal,
    /// inside a comment — cannot be expressed as one. Swift's nested block comments are honoured by
    /// counting depth; raw strings are not handled, and nothing in `Sources` uses one to hold reader
    /// prose (asserted by `everyPhraseTheHarnessLooksForIsStillSomethingTheAppSays` passing).
    ///
    /// **A `"""` block is its own state, and treating its quotes as ordinary ones desynchronised the
    /// whole file.** A multiline literal containing a lone `"` — legal Swift, since a single quote
    /// needs no escape there — flipped the scanner inside-out, after which every comment to the end of
    /// the file was preserved as code. Measured 2026-09-26 before the fix: 74 `"""` delimiters in
    /// `Sources` and **zero** blocks with an odd number of unescaped quotes, so the corpus was intact
    /// and the hazard was latent. Fixed anyway, because "no file triggers it today" is the property
    /// that changes when someone writes a sentence with a quotation mark in it.
    static func strippingComments(from code: String) -> String {
        var out = ""
        var index = code.startIndex
        var inLiteral = false
        var inMultiline = false
        var blockDepth = 0

        func peek(_ offset: Int) -> Character? {
            let i = code.index(index, offsetBy: offset, limitedBy: code.endIndex)
            guard let i, i < code.endIndex else { return nil }
            return code[i]
        }

        while index < code.endIndex {
            let c = code[index]
            if blockDepth > 0 {
                if c == "/" && peek(1) == "*" { blockDepth += 1; index = code.index(index, offsetBy: 2); continue }
                if c == "*" && peek(1) == "/" { blockDepth -= 1; index = code.index(index, offsetBy: 2); continue }
                index = code.index(after: index)
                continue
            }
            if inMultiline {
                out.append(c)
                if c == "\\", let next = peek(1) {
                    out.append(next)
                    index = code.index(index, offsetBy: 2)
                    continue
                }
                if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    out.append("\"\"")
                    inMultiline = false
                    index = code.index(index, offsetBy: 3)
                    continue
                }
                index = code.index(after: index)
                continue
            }
            if inLiteral {
                out.append(c)
                // A backslash escape takes the next character with it, so `\"` does not end the
                // literal — without this, an escaped quote flips the state and the rest of the file
                // is read inside-out.
                if c == "\\", let next = peek(1) {
                    out.append(next)
                    index = code.index(index, offsetBy: 2)
                    continue
                }
                if c == "\"" { inLiteral = false }
                index = code.index(after: index)
                continue
            }
            // `"""` is tested before `"`, or the multiline opener reads as an empty literal followed
            // by the start of another one — which is the desynchronisation itself.
            if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                inMultiline = true
                out.append("\"\"\"")
                index = code.index(index, offsetBy: 3)
                continue
            }
            if c == "\"" { inLiteral = true; out.append(c); index = code.index(after: index); continue }
            if c == "/", peek(1) == "/" {
                while index < code.endIndex, code[index] != "\n" { index = code.index(after: index) }
                continue
            }
            if c == "/", peek(1) == "*" { blockDepth = 1; index = code.index(index, offsetBy: 2); continue }
            out.append(c)
            index = code.index(after: index)
        }
        return out
    }

    /// A phrase spanning a `\(…)` interpolation, or supplied by the harness itself, cannot be found
    /// verbatim in `Sources`. **Each exemption names what must exist instead, so it is a narrower
    /// check rather than a hole** — and `everyExemptionIsStillNeeded` fails once a phrase can be
    /// found the ordinary way, so the table cannot quietly outlive its reason.
    private static let exemptions: [(phrase: String, because: String, insteadRequire: [String],
                                     fixture: String?)] = [
        (phrase: "Downloading Qwen3.5",
         because: """
             it spans an interpolation: the row writes `Downloading \\(size.displayName)`, and the \
             name comes from the catalogue. Neither half contains the phrase.
             """,
         insteadRequire: ["Text(\"Downloading \\(size.displayName)", "\"Qwen3.5 \\(parameters)\""],
         fixture: nil),
        (phrase: "stopped meeting at noon",
         because: """
             it is the harness's own sentence, read out of a fixture and expected back out of the \
             panel — not something the app ever says. **The fixture is where it has to be checked:** \
             requiring it twice in the script proved nothing, because all three occurrences there are \
             expectations and the sentence itself is supplied by Tools/e2e/notes.txt, which the first \
             draft of this exemption never read. Editing that file left the exemption passing.
             """,
         insteadRequire: [],
         fixture: "Tools/e2e/notes.txt"),
    ]

    /// **A `grep` whose pattern is an expansion, and the literals it stands for.** The extraction
    /// cannot resolve `$row`, and guessing at shell semantics to try would be a worse check than
    /// admitting the limit — so the grep is named here together with every phrase it can match, and
    /// each of those is required in `Sources` exactly as an extracted phrase would be.
    ///
    /// This is the same trade as `exemptions` above: the hole becomes several narrower checks rather
    /// than a hole. And it is not optional cleverness — `grep -q "$row"` passed the first draft of
    /// `everyGrepInTheScriptIsOneThisTestCanRead` silently, which is how the five row labels of the
    /// setup board came to be asserted by the harness and guarded by nothing.
    private static let expandedGreps: [(grep: String, stands: [String])] = [
        (grep: #"grep -q "$row""#,
         stands: ["Accessibility", "Screen Recording", "Study dictionary", "Lookup shortcut",
                  "Translation and sense picking"]),
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
                // **The harness's own data is checked at its source, not by counting mentions.** The
                // fixture is what the run actually feeds in; the script only states what to expect.
                // Counting occurrences in the script conflated the two, so an edited fixture and a
                // matching one read the same — all three occurrences there are expectations.
                // **The named fixture, not any file under Tools/e2e.** Scanning the directory accepted
                // the phrase sitting in a `notes.txt.bak` while the harness read a `notes.txt` that no
                // longer held it — a check satisfied by a file nothing opens.
                let fixture = Self.repository.appendingPathComponent(exemption.fixture ?? "")
                let supplied = (try? String(contentsOf: fixture, encoding: .utf8))?
                    .contains(exemption.phrase) ?? false
                #expect(supplied, """
                    \(exemption.fixture ?? "(no fixture named)") does not supply this exempt \
                    sentence, so the sentence asserted is not the sentence fed in.
                    """)
                #expect(script.contains(exemption.phrase), """
                    this exempt sentence is supplied by a fixture but no longer asserted in \
                    Tools/e2e.sh, so its exemption covers nothing.
                    """)
            }
        }
    }

    /// **What an unresolvable `grep` stands for is checked phrase by phrase.** Without this the
    /// `expandedGreps` table would be a way to silence the accounting check rather than a narrower
    /// form of it — which is the failure mode of every exemption list.
    @Test func everyExpandedGrepStandsForPhrasesTheAppStillSays() throws {
        let text = try Self.readerText()
        let script = try Self.script()
        for entry in Self.expandedGreps {
            #expect(script.contains(entry.grep), """
                \(entry.grep) is no longer in Tools/e2e.sh, so its row in `expandedGreps` covers \
                nothing — delete the row.
                """)
            #expect(!entry.stands.isEmpty, "\(entry.grep) stands for no phrases, which checks nothing")
            for phrase in entry.stands {
                #expect(text.contains(phrase), """
                    \(entry.grep) can match “\(phrase)”, and no source file contains it any more \
                    — that branch of the harness cannot fire.
                    """)
            }
        }
    }

    /// **The comment scanner is tested against the inputs that broke it**, because its whole job is
    /// invisible: a corpus that silently keeps a comment looks exactly like one that stripped it, and
    /// the test above then passes for the wrong reason.
    @Test func commentsAreStrippedAndStringLiteralsSurvive() {
        let cases: [(name: String, code: String, keeps: [String], drops: [String])] = [
            (name: "a trailing inline comment",
             code: "let x = 1 // Old reader text\nText(\"Kept sentence\")",
             keeps: ["Kept sentence"], drops: ["Old reader text"]),
            (name: "a block comment",
             code: "/* Old reader text */ Text(\"Kept sentence\")",
             keeps: ["Kept sentence"], drops: ["Old reader text"]),
            (name: "a nested block comment",
             code: "/* outer /* Old reader text */ still comment */ Text(\"Kept sentence\")",
             keeps: ["Kept sentence"], drops: ["Old reader text"]),
            (name: "a // inside a string literal",
             code: "Text(\"see https://example.com now\")",
             keeps: ["see https://example.com now"], drops: []),
            (name: "an escaped quote in a literal",
             code: "Text(\"a \\\" quote\") // Old reader text",
             keeps: ["a \\\" quote"], drops: ["Old reader text"]),
            // **The one that desynchronised the whole file.** A lone `"` needs no escape inside a
            // multiline literal, so the scanner read it as a closing delimiter and every comment after
            // it survived as code. Reported by an adversarial reader with exactly this input.
            (name: "a lone quote inside a multiline literal",
             code: "let x = \"\"\"\nA lone \" quote.\n\"\"\"\nlet y = 1 // Old reader text",
             keeps: ["A lone \" quote."], drops: ["Old reader text"]),
        ]
        for c in cases {
            let stripped = Self.strippingComments(from: c.code)
            for keep in c.keeps {
                #expect(stripped.contains(keep), "\(c.name): the literal \(keep) was destroyed")
            }
            for drop in c.drops {
                #expect(!stripped.contains(drop), "\(c.name): a comment survived into the corpus")
            }
        }
    }

    /// **The phrase list must not be able to go quietly empty.** A regex that stopped matching, a
    /// script that moved, or a prose filter tightened too far would each leave every assertion above
    /// passing over nothing.
    @Test func theScanFindsPhrasesAtAll() throws {
        let phrases = try Self.phrases(in: Self.script())
        // 19 on 2026-09-26, up from 17 when alternations began to be split. The floor is close under
        // it rather than far below, because that is the difference between noticing a matcher moved
        // and noticing only that the whole mechanism collapsed.
        #expect(phrases.count >= 17, "only \(phrases.count) reader phrases found in Tools/e2e.sh")
        #expect(phrases.contains("Not now"), "a phrase known to be asserted was not extracted")
        // From the alternation at the waiting-panel poll — the three that were unguarded until `|`
        // stopped disqualifying a pattern. `could not all be asked` is there because splitting them
        // out is what exposed that the harness had been grepping for `could not be asked`, wording
        // the app does not have, so that third of the guard could never fire.
        #expect(phrases.isSuperset(of: ["Looking up", "No entry for", "could not all be asked"]),
                "the waiting-panel alternatives are unguarded again")
    }

    /// **Every `grep` in the script is accounted for exactly**, not as a ratio. A pattern the
    /// extraction cannot read is a phrase nobody is guarding, and the interesting case is the one
    /// that arrives later: a pattern moved into a shell variable, a `-f` file, or a switch to `awk`
    /// or `[[ … =~ … ]]`.
    ///
    /// Two outcomes are allowed, and every other one is named in the failure:
    ///
    /// | Form | Why it is fine |
    /// |---|---|
    /// | a quoted literal pattern | `phrases(in:)` reads it |
    /// | a bare literal token — `grep -q opticalRecognition` | it has no space, so it cannot be prose |
    ///
    /// Measured 2026-09-26: **49 greps, 45 quoted, 4 bare** — the bare ones `opticalRecognition` and
    /// `DONE`, each twice. An earlier draft of this comment said 53/49/4, from counting the substring
    /// `"grep "`, which also matches `pgrep`. The number in a comment is as worth checking as the code.
    ///
    /// **Four ways this check has been wrong, all found by trying them rather than by reading:**
    ///
    /// 1. The bare form allowed any run of non-space characters, so `grep -q $needle` — a pattern in a
    ///    variable, the very case this exists to catch — counted as readable.
    /// 2. Excluding `$` did not fix it: the flag group is `*`, so with zero flags matched the regex
    ///    read `-q` itself as the pattern. Hence the leading character may not be `-`.
    /// 3. **Quoted did not mean readable.** `grep -q "$needle"` satisfied the quoted form, and then
    ///    `isProse` rejected the expansion — so the phrase behind it was guarded by nothing while the
    ///    call counted as understood. A quoted pattern must now be free of `$` and backtick too.
    /// 4. **A bare token has to end where the shell ends it.** `grep -q Old$needle` and
    ///    `grep -q Old" reader text"` both matched the prefix `grep -q Old` and passed. The bare form
    ///    now has to reach a space, a `;`, a `|`, or the end of the line.
    ///
    /// **There is no `grep -f` in the script, and a previous version of this comment said there were
    /// four.** They are `pgrep -f "MacOS/XiaolaiDict …"`, which `\bgrep\b` does not match at all — so
    /// the paragraph justifying them as readable was describing calls that do not exist. If a real
    /// `grep -f` ever appears, what is quoted is a *path* and the phrases live in that file: it will
    /// fall out as unreadable here, which is the correct answer.
    @Test func everyGrepInTheScriptIsOneThisTestCanRead() throws {
        let script = try Self.script()
        // Neither form may contain an expansion: `$` and a backtick are what turn a pattern into
        // something whose text lives elsewhere, and both forms admitted one until this was written.
        // Both forms must **end** at a token boundary. Without it `grep -q "Old""$needle"` satisfied
        // the quoted form by matching `grep -q "Old"` alone, while the shell handed grep the single
        // pattern `Old reader text` and extraction guarded none of it.
        // **A flag cluster containing `f` disqualifies the call**, because `grep -f FILE` reads its
        // patterns from a file: what is quoted is a path, and the phrases are somewhere this cannot
        // see. `grep -qf "patterns.txt"` satisfied the quoted form until this lookahead was added.
        let quoted = try NSRegularExpression(
            pattern: #"grep\s+(?:-(?![A-Za-z0-9]*f)[A-Za-z0-9]+\s+)*(?:"[^"\\\n$`]*"|'[^'\n$`]*')(?=[\s;|)]|$)"#)
        // A bare *literal* token: flags, then a run of non-space characters with no quote, no pipe,
        // no `$` or backtick — and it must **end** at a shell token boundary, or a prefix of a longer
        // word counts as the whole pattern.
        // `\` is excluded as well as `$`: `grep -q Old\ reader\ text` is one shell word, and a form
        // that stopped at `Old\` and found a space after it counted the call as understood while the
        // pattern it actually matched went unguarded.
        // **It must begin with a letter, not merely with a non-dash.** `grep -q -m 1 -f patterns.txt`
        // was accepted by reading `1` — the argument of `-m`, which this does not model — as the
        // pattern, while the real patterns sat in a file. A bare pattern that is a bare number is not
        // a sentence, and refusing it is cheaper than teaching this every option's arity.
        let bare = try NSRegularExpression(
            pattern: #"grep\s+(?:-(?![A-Za-z0-9]*f)[A-Za-z0-9]+\s+)*[A-Za-z][^\s"'|$`\\]*(?=[\s;|)]|$)"#)
        let full = NSRange(script.startIndex..., in: script)

        var unreadable: [String] = []
        var readable = 0
        for match in try NSRegularExpression(pattern: #"\bgrep\b"#).matches(in: script, range: full) {
            let rest = NSRange(location: match.range.location, length: full.length - match.range.location)
            let isQuoted = quoted.firstMatch(in: script, options: .anchored, range: rest) != nil
            let isBare = bare.firstMatch(in: script, options: .anchored, range: rest) != nil
            if isQuoted || isBare { readable += 1; continue }
            // The whole line, so the failure says which call to look at.
            let from = Range(rest, in: script)!.lowerBound
            let line = script[from...].prefix(while: { $0 != "\n" })
            // An expansion this test cannot resolve, but whose literals are named in the table above
            // and checked by `everyExpandedGrepStandsForPhrasesTheAppStillSays`.
            if Self.expandedGreps.contains(where: { line.hasPrefix($0.grep) }) { readable += 1; continue }
            unreadable.append(String(line.prefix(80)))
        }

        #expect(unreadable.isEmpty, """
            Tools/e2e.sh matches text in a way this test cannot read, so the phrases behind it are \
            unguarded: \(unreadable.joined(separator: " | ")).
            Add the spelling to `matchers`, or say in the table above why it carries no reader text.
            """)
        // A count that collapsed would make the loop above vacuous.
        #expect(readable >= 40, "only \(readable) greps found in Tools/e2e.sh — has the script moved?")
        // **And the forms this check rejects are exercised here, not just described above.** Each of
        // these passed at some point; a regex edit that re-admits one fails by name.
        // Every construction that has ever slipped past this check, kept as a row. Six of the eight
        // were found by an adversarial second reader rather than by writing the regex more carefully,
        // which is the argument for keeping them: the next edit to either pattern is checked against
        // the whole history and not against the case its author had in mind.
        for bypass in ["grep -q $needle", #"grep -q "$needle""#, "grep -q Old$needle",
                       #"grep -q Old" reader text""#, #"grep -q "Old""$needle""#,
                       #"grep -qf "patterns.txt""#, #"grep -q Old\ reader\ text"#,
                       #"grep -q "Old"$needle"#,
                       // Unquoted, so only the **bare** form's `f` guard can refuse it. Without this
                       // row, removing that guard left all eight earlier rows passing — a mutation the
                       // list could not see, reported by the second reader rather than found here.
                       "grep -qf patterns.txt",
                       // `1` is the argument of `-m`, and was being read as the pattern.
                       "grep -q -m 1 -f patterns.txt"] {
            let probe = NSRange(bypass.startIndex..., in: bypass)
            let readsAsQuoted = quoted.firstMatch(in: bypass, options: .anchored, range: probe) != nil
            let readsAsBare = bare.firstMatch(in: bypass, options: .anchored, range: probe) != nil
            #expect(!readsAsQuoted && !readsAsBare,
                    "\(bypass) counts as a pattern this test can read, and it is not one")
        }
    }
}
