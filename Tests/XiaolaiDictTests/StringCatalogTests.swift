import Foundation
import Testing
import XiaolaiDictTestSupport

/// The string catalog is what a translator is given, and `Tools/strings.sh` generates it from the
/// source. Two things have to hold for that to mean anything: what the code says must be in it,
/// and what is in it must reach the reader.
struct StringCatalogTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // XiaolaiDictTests
            .deletingLastPathComponent()                             // Tests
            .deletingLastPathComponent()                             // the repository
    }

    private var catalogURL: URL { repository.appendingPathComponent("Strings/Localizable.xcstrings") }

    private func catalog() throws -> [String: Any] {
        let data = try Data(contentsOf: catalogURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func swiftFiles(under directory: String) throws -> [URL] {
        let root = repository.appendingPathComponent(directory)
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    // MARK: - Reading the source

    /// One string literal, and the text that stood in front of its opening quote.
    private struct Literal {
        let line: Int
        /// Up to and including the opening quote, so a call site is recognised by what it ends with.
        let prefix: String
        let text: String
    }

    /// **Every spelling that hands the compiler a key.** A literal written at one of these and not
    /// synced is a literal no translator ever sees, which is what this test began as.
    ///
    /// The list is the check: a SwiftUI initialiser that takes a `LocalizedStringKey` and is not
    /// named here is a spelling this cannot see. `Text(verbatim:` deliberately matches none of
    /// them — that is what `verbatim:` is for.
    private static let localizingCallSites = [
        "String(localized: \"", "LocalizedStringResource(\"", "LocalizedStringKey(\"",
        "AttributedString(localized: \"",
        "Text(\"", "Label(\"", "Button(\"", "Toggle(\"", "Picker(\"", "TextField(\"",
        "Section(\"", "Link(\"", "Stepper(\"", "Menu(\"", "Tab(\"",
        "navigationTitle(\"", "accessibilityLabel(\"", "help(\"", "confirmationDialog(\"", "alert(\"",
    ]

    /// **Prose the reader is not given a key for at all.** The defect the call-site list cannot
    /// see: a sentence written as a plain `String` — a `switch` arm, a `return`, a labelled
    /// argument — reaches the screen through `Text(_:)`, which then takes the `StringProtocol`
    /// overload and draws it verbatim. `swiftc -emit-localized-strings` never sees it, so the
    /// catalog never holds it, so the sentence ships in English whatever the reader's language.
    /// A whole surface was in that state — both drawer notices, the panel's four messages, every
    /// settings tab title. The one that shows why a scan and not a reading: `Permission.name` gave
    /// *Accessibility* and *Screen Recording* to Settings while `SetupView` wrote the **same two
    /// words** as `Text("…")` and had them translated. One surface would have said one thing and
    /// the other another, and nothing anywhere would have said so.
    ///
    /// So every prose literal in the view layer has to be a key, however it was written. The shape
    /// test is what separates a sentence from a symbol name, and each clause is here for a reason:
    ///
    /// - A **digit** makes it a version, a format or a key — `Qwen3.5`, `Apache License 2.0`.
    /// - `_ / : @ # \ % { } < > [ ] | = + * ~ $` make it a URL, a path, a defaults key or markup.
    /// - A **dot between two letters** makes it a dotted identifier — every SF Symbol name, every
    ///   bundle id.
    /// - A **space** makes it prose, whatever case it starts in: *the dictionary did not name its
    ///   headword* is a sentence.
    /// - Otherwise it is prose only if it is **one capitalised word with no interior capital**.
    ///   That is what admits the four settings tab titles — *Reading*, *Lookup*, *Permissions*,
    ///   *About* — while leaving `TextSize`, `CFBundleVersion` and `ThirdPartyNotices` alone.
    ///
    /// The clauses cut the other way too, and the price is stated rather than hidden: prose with a
    /// number in it, or a lowercase one-word label, is not seen.
    private static func isProse(_ literal: String) -> Bool {
        guard let first = literal.first else { return false }
        if literal.contains(where: \.isNumber) { return false }
        if literal.contains(where: { "_/:@#\\%{}<>[]|=+*~$".contains($0) }) { return false }
        // A dot *between* two letters, never a dot at the end: `book.closed` is a symbol name and
        // "…you met them." is a sentence.
        var previous: Character?
        var beforePrevious: Character?
        for character in literal {
            if previous == ".", let beforePrevious, beforePrevious.isLetter, character.isLetter { return false }
            beforePrevious = previous
            previous = character
        }
        if literal.contains(" ") { return true }
        return first.isUppercase && !literal.dropFirst().contains(where: \.isUppercase)
    }

    /// Prose the view layer holds that is nonetheless not for the reader. **A reason, never a bare
    /// string** — adding to this is a decision about the text, not a way to get the build green.
    private static let notForTheReader: [String: String] = [
        "not used from a nib":
            "the message of a `fatalError` in an initialiser marked unavailable; it is a crash "
            + "reason for whoever reads the log, and is never drawn",
    ]

    /// Every literal in a file, with what preceded it, and continuations rejoined.
    ///
    /// A sentence built with `+` across lines is joined back together, because that is how the
    /// longer ones in Settings are written and skipping them would leave the longest strings in
    /// the app unguarded.
    ///
    /// Two things it steps over rather than reading. **A `#if DEBUG` block** is previews and their
    /// sample fixtures — *The ephemeral beauty of morning frost.* is a specimen, not a sentence the
    /// app ever says. And **the rest of a line after an interpolated literal**: an interpolation can
    /// hold a literal of its own (`joined(separator: ", ")`), and a walk over quotes cannot tell
    /// that one's closing quote from the outer literal's, so it would read the remainder of the
    /// line shifted by one.
    private func literals(in file: URL) throws -> [Literal] {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
        var found: [Literal] = []
        var index = 0
        var debugDepth = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if DEBUG") { debugDepth += 1; index += 1; continue }
            if debugDepth > 0 {
                if trimmed.hasPrefix("#endif") { debugDepth -= 1 }
                index += 1
                continue
            }
            if trimmed.hasPrefix("//") { index += 1; continue }

            var cursor = line.startIndex
            var consumed = 0
            while let quote = line[cursor...].firstIndex(of: "\"") {
                let prefix = String(line[...quote])
                let rest = String(line[line.index(after: quote)...])
                guard var text = Self.literal(from: rest) else { break }
                // Joined across continuations. The `+` sits at the start of the next line in this
                // codebase and at the end of the current one elsewhere, so both count.
                var at = index
                var tail = String(rest.dropFirst(text.count + 1))
                while at + 1 < lines.count {
                    let next = lines[at + 1].trimmingCharacters(in: .whitespaces)
                    let continues = tail.trimmingCharacters(in: .whitespaces).hasSuffix("+") || next.hasPrefix("+")
                    guard continues, let nextQuote = next.firstIndex(of: "\""),
                          let piece = Self.literal(from: String(next[next.index(after: nextQuote)...]))
                    else { break }
                    text += piece
                    at += 1
                    tail = String(next[next.index(after: nextQuote)...].dropFirst(piece.count + 1))
                }
                found.append(Literal(line: index + 1, prefix: prefix, text: text))
                if text.contains("\\(") { break }
                if at != index { consumed = at - index; break }
                // Past this literal's own closing quote, or the next pass would read that quote as
                // the opening one and take the code between two literals for a string.
                let closing = line.index(line.index(after: quote), offsetBy: text.count)
                cursor = line.index(after: closing)
            }
            index += consumed + 1
        }
        return found
    }

    /// The text up to the next unescaped quote.
    private static func literal(from rest: String) -> String? {
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Whether this literal is one the catalog has to answer for, and under which rule.
    ///
    /// Interpolated ones are skipped: their key holds `%@` rather than the source text, so matching
    /// them would need the compiler's own formatting rules. A `comment:` argument is the translator's
    /// note, which the catalog keeps beside a key and never as one. `verbatim:` is the author saying
    /// this is not prose, which is the rule AGENTS.md already states for a composed label.
    private static func rule(for literal: Literal, inTheViewLayer: Bool) -> String? {
        guard !literal.text.isEmpty,
              !literal.text.contains("\\("), !literal.text.contains("\\\"") else { return nil }
        if literal.prefix.hasSuffix("comment: \"") || literal.prefix.hasSuffix("verbatim: \"") { return nil }
        if localizingCallSites.contains(where: { literal.prefix.hasSuffix($0) }) {
            return "written at a localizing call site"
        }
        guard inTheViewLayer, isProse(literal.text), notForTheReader[literal.text] == nil else { return nil }
        return "prose in the view layer"
    }

    // MARK: - The checks

    /// **Every string the reader sees is in the catalog.** A string added without running
    /// `make strings` is one no translator will ever see, and nothing else would say so.
    ///
    /// It reads what the source says rather than what the compiler emits, so an interpolated
    /// string is skipped and a concatenated one is rejoined. The catalog stays the source of
    /// truth; this is the guard against the two ways it goes stale.
    ///
    /// The prose rule runs over `Sources/XiaolaiDictUI` alone, and the limit is deliberate rather
    /// than an oversight. The view layer is where reader-facing text belongs, and the app module is
    /// mostly the opposite — instrument output, report keys and log lines, which are not translated
    /// and would swamp the check. What that costs: a sentence written as a bare `String` in
    /// `Sources/XiaolaiDict` is seen only if it sits at one of the call sites above. That is why
    /// the panel's own four messages were moved to `PanelContent`, where they are covered.
    @Test func everyLiteralTheReaderSeesIsInTheCatalog() throws {
        let strings = try #require(try catalog()["strings"] as? [String: Any])
        var missing: [String] = []
        for directory in ["Sources/XiaolaiDictUI", "Sources/XiaolaiDict"] {
            let viewLayer = directory == "Sources/XiaolaiDictUI"
            for file in try swiftFiles(under: directory) {
                for literal in try literals(in: file) {
                    guard let rule = Self.rule(for: literal, inTheViewLayer: viewLayer) else { continue }
                    guard strings[literal.text] == nil else { continue }
                    missing.append("\(file.lastPathComponent):\(literal.line) (\(rule)): \(literal.text)")
                }
            }
        }
        #expect(missing.isEmpty, "run `make strings`; the catalog does not have: \(missing)")
    }

    /// **The scan reaches what it claims to reach.** Every rule above is a filter, and a filter
    /// that has quietly stopped matching reads exactly like a codebase with nothing wrong in it —
    /// which is how the prose half came to be missing in the first place. So both halves are
    /// exercised against literals whose answer is known.
    @Test func theScanSeesBothWaysAStringGoesMissing() throws {
        let catalogued = "Show All"
        let symbol = "clock.arrow.circlepath"

        #expect(Self.isProse(catalogued), "a two-word label is prose")
        #expect(Self.isProse("About"), "one capitalised word is prose — the tab titles are four of them")
        #expect(Self.isProse("the dictionary did not name its headword"),
                "a sentence is prose whatever case it starts in")
        #expect(!Self.isProse(symbol), "an SF Symbol name is not prose")
        #expect(!Self.isProse("CFBundleVersion"), "an interior capital makes it a key")
        #expect(!Self.isProse("Apache License 2.0"), "a digit makes it a name rather than a sentence")
        #expect(!Self.isProse("x-apple.systempreferences:com.apple.preference.security"),
                "a URL is not prose")

        // The two rules, each on a line the other one would miss.
        let bare = Literal(line: 1, prefix: "            title: \"", text: catalogued)
        #expect(Self.rule(for: bare, inTheViewLayer: true) == "prose in the view layer",
                "a literal handed to a String parameter is the defect this half exists for")
        #expect(Self.rule(for: bare, inTheViewLayer: false) == nil, "the prose rule is the view layer's")

        let called = Literal(line: 1, prefix: "        Text(\"", text: catalogued)
        #expect(Self.rule(for: called, inTheViewLayer: false) == "written at a localizing call site")

        let note = Literal(line: 1, prefix: "               comment: \"", text: catalogued)
        #expect(Self.rule(for: note, inTheViewLayer: true) == nil, "a translator's note is not a key")

        let said = Literal(line: 1, prefix: "        Text(verbatim: \"", text: catalogued)
        #expect(Self.rule(for: said, inTheViewLayer: true) == nil, "`verbatim:` says this is not prose")
    }

    /// The catalog's source language is what the keys are written in.
    @Test func theCatalogIsWrittenInEnglish() throws {
        #expect(try catalog()["sourceLanguage"] as? String == "en")
        let strings = try #require(try catalog()["strings"] as? [String: Any])
        #expect(strings.count > 50, "only \(strings.count) strings — extraction is not finding the source")
    }

    /// Every target below the view layer. **A list, because this scan named one directory and the
    /// module split moved two thirds of that directory's files out from under it** — on 2026-09-26,
    /// `DictionaryModel` and `ModelKit` took 19 files with them, and this check would have gone on
    /// passing over a shrinking subject with the test count unchanged. That is the failure
    /// `AGENTS.md` describes as worse than no rule, because it still reads as one.
    static let targetsBelowTheViewLayer = [
        "Sources/XiaolaiDictBase", "Sources/DictionaryModel", "Sources/ModelKit",
        "Sources/XiaolaiDictCore", "Sources/LocalModel", "Sources/DictionaryBridge",
    ]

    /// **No display text below the view layer.** None of these targets has one, so a sentence there
    /// can be shown and never extracted — `Tools/strings.sh` would not find it.
    @Test func noTargetBelowTheViewLayerHoldsDisplayText() throws {
        var offenders: [String] = []
        for directory in Self.targetsBelowTheViewLayer {
            let target = directory.replacingOccurrences(of: "Sources/", with: "")
            for name in try Self.filesHoldingDisplayText(under: repository.appending(path: directory)) {
                offenders.append("\(target)/\(name)")
            }
        }
        #expect(offenders.isEmpty, "these belong in the view layer: \(offenders)")
    }

    /// **And the list has to name every target that has no view layer.** Read off `Package.swift`
    /// rather than kept by hand: a target added later and left off the list above is a target the
    /// scan silently does not cover, which is the same defect one directory deep.
    ///
    /// `XiaolaiDictUI` and `XiaolaiDict` are the view layer and are excluded by name;
    /// the two service executables carry no reader text and are excluded for the reason
    /// `HoverRefusal` stays in the core — what they print is instrument output.
    @Test func everyTargetBelowTheViewLayerIsScanned() throws {
        let manifest = try String(contentsOf: repository.appending(path: "Package.swift"), encoding: .utf8)
        let declared = try Regex(#"\.(?:executableT|t)arget\(\s*name: "([A-Za-z]+)""#)
        let viewLayerOrAnExecutable = [
            "XiaolaiDictUI", "XiaolaiDict", "XiaolaiDictService", "XiaolaiDictModelService",
            "XiaolaiDictTestSupport",
        ]
        let shouldScan = manifest.matches(of: declared)
            .map { String($0.output[1].substring ?? "") }
            .filter { !viewLayerOrAnExecutable.contains($0) }
        let scanned = Self.targetsBelowTheViewLayer.map { $0.replacingOccurrences(of: "Sources/", with: "") }
        #expect(Set(shouldScan) == Set(scanned), """
            targets in Package.swift that have no view layer: \(shouldScan.sorted()); \
            targets this scan covers: \(scanned.sorted())
            """)
    }

    /// **The scan has to be able to fail, and nothing else proves that** — the check Codex named
    /// when it pointed out that moving files preserves a test count while shrinking what a rule
    /// covers.
    ///
    /// **It plants into a temporary directory, never into `Sources/`.** The first version wrote a
    /// forbidden file into each scanned target in turn, and it failed at once — against itself:
    /// tests in a suite run in parallel, so the plant was on disk while
    /// `noTargetBelowTheViewLayerHoldsDisplayText` was reading the same tree, and that check
    /// reported a target holding display text when none does. Worse than a flake: a planted file
    /// left behind by a crash is a file `swift build` then compiles. The predicate is what needs
    /// exercising, and a directory of its own is enough to exercise it; that the *roots* are
    /// complete is `everyTargetBelowTheViewLayerIsScanned`'s job, above.
    @Test func theDisplayTextScanCatchesAPlantedLiteral() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-planted-display-text")
        // Split so this file does not match the search it is testing.
        let forbidden = "String(" + "localized:"
        try "let innocent = 1\n".write(to: scratch.appending("Innocent.swift"), atomically: true, encoding: .utf8)
        var caught = try Self.filesHoldingDisplayText(under: scratch.url)
        #expect(caught.isEmpty, "the scan reported display text in a directory that has none: \(caught)")

        try "let planted = \(forbidden) \"planted\", comment: \"a scan that cannot fail is not a scan\")\n"
            .write(to: scratch.appending("Planted.swift"), atomically: true, encoding: .utf8)
        caught = try Self.filesHoldingDisplayText(under: scratch.url)
        #expect(caught == ["Planted.swift"], "the scan did not see a planted literal: \(caught)")
    }

    /// The one predicate both checks above use, so neither can drift from the other.
    private static func filesHoldingDisplayText(under root: URL) throws -> [String] {
        try SourceScan.offenders(of: "String(localized:", under: root).names.sorted()
    }

    /// **And a translation in the catalog reaches the reader.** The bundle carries compiled
    /// `.strings`, one directory per language, which `xcstringstool compile` writes — so this
    /// compiles a copy of the real catalog with one string translated and reads it back. Nothing
    /// is translated in the shipped catalog yet, so without this the whole path from catalog to
    /// bundle would be unexercised until the first translator finished.
    @Test func aTranslatedStringCompilesIntoSomethingTheBundleCanRead() throws {
        var contents = try catalog()
        var strings = try #require(contents["strings"] as? [String: Any])
        let key = try #require(strings.keys.sorted().first { $0.count > 20 })
        strings[key] = ["localizations": ["de": ["stringUnit": ["state": "translated", "value": "ÜBERSETZT"]]]]
        contents["strings"] = strings

        let scratch = TemporaryDirectory(named: "xiaolaidict-catalog")
        let directory = scratch.url
        let copy = scratch.appending("Localizable.xcstrings")
        try JSONSerialization.data(withJSONObject: contents).write(to: copy)

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["xcstringstool", "compile", copy.path, "--output-directory", directory.path]
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0, "xcstringstool could not compile the catalog")

        let compiled = directory.appendingPathComponent("de.lproj/Localizable.strings")
        try #require(FileManager.default.fileExists(atPath: compiled.path),
                     "no de.lproj was produced, so a translation would never reach the bundle")
        let table = try #require(NSDictionary(contentsOf: compiled) as? [String: String])
        #expect(table[key] == "ÜBERSETZT", "the compiled table does not answer with the translation")
    }
}
