import Foundation
import Testing

/// **Every study capability the ledger offers has a surface, or an exemption that says why.**
///
/// `setReaderAnswer` had tests and no caller. So did `repeatedlyLapsed`. Then `postpone(cardID:until:)`.
/// Three of one shape is one defect, and the shape is: *a write exists and the read or the reversal
/// does not* — a tag the reader could add and never see, a word set aside with nothing to set it
/// back, a retention figure computed for nobody. Each cost a manual audit to find, and each would
/// have been found at the commit that introduced it by this scan — ADR-0038.
///
/// **Not a style rule.** A ledger method with no caller is either a feature the reader cannot
/// reach or code that should be deleted, and both are worth being told about.
struct StudySurfaceTests {
    /// Where the study capabilities are declared. **Named as a list and checked against the disk**,
    /// because a rule that names a directory stops covering its subject the day that subject moves.
    private static let declaring = [
        "Sources/XiaolaiDictCore/StudyLedger.swift",
        "Sources/XiaolaiDictCore/StudyLibrary.swift",
        "Sources/XiaolaiDictCore/StudyOrganisation.swift",
        "Sources/XiaolaiDictCore/StudyReviewLedger.swift",
        "Sources/XiaolaiDictCore/StudyExport.swift",
        "Sources/XiaolaiDictCore/StudyRecovery.swift",
        "Sources/XiaolaiDictCore/StudyDay.swift",
        // The ledger proper: reading history, recovery and erasure are study capabilities too,
        // and `history`, `encounters` and `integrity` are exactly the shape this looks for.
        "Sources/XiaolaiDictCore/Ledger.swift",
        "Sources/XiaolaiDictCore/StudyCards.swift",
        "Sources/XiaolaiDictCore/ReviewSession.swift",
        "Sources/XiaolaiDictCore/MemoryScheduler.swift",
    ]

    /// Where a caller would be. The app, the view layer and the instruments — **not**
    /// `XiaolaiDictCore` itself, since a method called only by its own module is what this looks
    /// for, and not the tests, since a test is not a surface.
    private static let calling = [
        "Sources/XiaolaiDict", "Sources/XiaolaiDictUI", "Sources/XiaolaiDictService", "Tools",
    ]

    /// Called only from inside `XiaolaiDictCore`, on purpose. **Each row is a reason**: a bare
    /// allow-list is how a rule like this dies, and `everyExemptionIsRealAndEveryUnwiredMethodIsListed`
    /// fails in both directions so a name cannot rot here after it gains a caller.
    private static let exempt: [String: String] = [
        "isDue(at:": "A predicate on a value, used wherever a card is judged.",
        "readiness(of:": "One note's facts, gathered for the library's own query.",
        "introductions(since:": "The allowance's denominator, counted by dueCards.",
        "scheduledDays(stability:": "The scheduler's own arithmetic.",
        "link(noteID:": "Joins a note to a lookup inside enrol, which is the only correct caller.",
        "locators(of:": "Evidence carried with a phrase note; read by the note's own equality.",
        "lookupIDs(evidencing:": "The timeline's first step, inside the ledger.",
        "existingCard(of:": "Reads without creating; the timeline and the queue use it.",
        "encounters(ofLookup:": "A lookup's senses, read by the reading projection.",
        "repeatedlyLapsed(": """
            R09's programmatic form. Its surface is the library's Struggling filter, which shares             lapseDaysExpression rather than the function — a page narrowed in Swift after the             LIMIT is a short page (ADR-0033).
            """,
        "backUp(to:": "Taken before a migration changes the ledger's shape; not a reader's command.",
        "history(of:": "A lemma's lookups, read by the drawer's own projection.",
        "reviews(ofCard:": "One card's events, gathered by `timeline`.",
        // **Exposed by the label-aware match**, which stopped one overload vouching for another.
        // Each had an in-Core caller all along and was hidden behind a namesake that did not.
        "lookupIDs(fromSource:": "One source's lookups, counted by the erasure impact.",
        "remove(noteID:": "One note, removed by `removeFromStudy`.",
        "note(for:": "Looks a target up during `enroll`, to decide new against existing.",
        "reading(ofLookup:": "One lookup's projection, read by the drawer and the timeline.",
        "interval(stability:": "The scheduler's own arithmetic.",
        "recall(elapsedDays:": "The forgetting curve; the scheduler's own arithmetic.",
        // Newly visible once `public static func` stopped being skipped: the erasure path's own
        // helper, called twice inside `StudyRecovery`.
        "appManagedBackups(besides:": "The copies this app made; read by the impact count and the erase.",
        // **Named, not forgiven.** These are gaps with no surface designed yet, and saying so here
        // is what stops the next audit rediscovering them as new — ADR-0038.
        "card(of:": "Creates the card for a note; enrol is the only correct caller.",
        "integrity(": "GAP — D01 has no recovery surface.",
        "readingImpact(ofSource:": "GAP — erasing one source's reading is not offered.",
        "newlyMetSenses(limit:": "GAP — no surface designed.",
        "studyList(limit:": "GAP — no surface designed.",
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Each `public func` in a file, as **name plus its first argument label** — `card(of:`,
    /// `card(id:`, `allTags(`.
    ///
    /// **The label is what tells overloads apart, exactly as Swift does.** Matching the bare name
    /// made `Ledger.card(id:)` — a read — vouch for `Ledger.card(of:)`, which *creates*, so a
    /// creating call with no caller would have been reported as wired by its read-only namesake.
    /// The same collision cost a rename earlier in this file's history (`hide` → `postpone`); a
    /// label-aware match is the fix that does not need one.
    static func publicFunctions(in code: String) -> [String] {
        code.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            // **Any modifier between `public` and `func`.** Requiring the exact prefix
            // `public func ` skipped `public mutating func` — and every public method on
            // `ReviewSession`, a file this scan explicitly lists, is one. That file contributed
            // nothing at all: `record`, `reveal` and `undoLast` were invisible to a check whose
            // whole job is to notice a capability with no caller.
            guard text.hasPrefix("public ") else { return nil }
            guard let funcRange = text.range(of: " func ") else { return nil }
            let modifiers = text[text.index(text.startIndex, offsetBy: "public".count)..<funcRange.lowerBound]
            // Only declaration modifiers may sit there; `public var funcs: Int` must not match.
            let allowed: Set<Substring> = ["", "static", "mutating", "nonisolated", "final",
                                           "class", "override", "borrowing", "consuming"]
            guard modifiers.split(separator: " ").allSatisfy({ allowed.contains($0) }) else { return nil }
            let rest = text[funcRange.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty else { return nil }
            let after = rest.dropFirst(name.count)
            guard after.hasPrefix("(") else { return nil }
            // **The first identifier after `(` is the external label.** Not "the text before the
            // first colon": in `func f(to path: Int)` the colon follows the *internal* name, so
            // that reading found no label at all and every overload collapsed back onto its bare
            // name. A wildcard `_` and empty parentheses both give a call written `name(`.
            let inside = after.dropFirst()
            let label = inside.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            // **A defaulted first parameter is not a label the call site has to write.**
            // `retention(since:dictionary:)` is called `retention(dictionary:)`, so keying it by
            // `since` reported a wired method as unwired. Where the first parameter can be
            // omitted, fall back to the bare name — less precise, and the only thing that is true.
            let firstParameter = inside.prefix { $0 != "," && $0 != ")" }
            if firstParameter.contains("=") { return "\(name)(" }
            return label.isEmpty || label == "_" ? "\(name)(" : "\(name)(\(label):"
        }
    }

    /// **The roots exist.** A scan pointed at a moved file finds nothing and passes forever.
    @Test func everyDeclaringFileIsOnDisk() throws {
        for path in Self.declaring {
            #expect(FileManager.default.fileExists(atPath: Self.root.appending(path: path).path),
                    "\(path) is named by this scan and is not there")
        }
        for path in Self.calling {
            #expect(FileManager.default.fileExists(atPath: Self.root.appending(path: path).path),
                    "\(path) is named by this scan and is not there")
        }
    }

    /// Which public study methods no surface calls.
    static func unwired() throws -> Set<String> {
        var declared: Set<String> = []
        for path in declaring {
            let code = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            declared.formUnion(publicFunctions(in: code))
        }
        // Thrown, never defaulted: a scanner that finds nothing to scan guards nothing.
        guard !declared.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        var callers = ""
        for root in calling {
            let directory = Self.root.appending(path: root)
            let walk = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil,
                // **Build products are not callers.** `Tools/makeicon` is its own package, and
                // reading its `.build` checkout found "callers" in Swift's own source — which is
                // how a scan reports a capability as wired when nothing in this app touches it.
                options: [.skipsHiddenFiles])
            var seen = 0
            while let file = walk?.nextObject() as? URL {
                guard ["swift", "sh", "py"].contains(file.pathExtension) else { continue }
                guard !file.pathComponents.contains(".build") else { continue }
                // **A test is not a surface**, wherever it lives. `Tools/fsrs/test_fsrs6.py` sits
                // under a calling root, so a scan that reads it lets a test vouch for a method —
                // the one thing this check is built to refuse.
                let name = file.lastPathComponent
                guard !name.hasPrefix("test_"), !name.hasSuffix("Tests.swift"),
                      !file.pathComponents.contains("tests"), !file.pathComponents.contains("Tests")
                else { continue }
                // **Thrown, never defaulted to "".** A file that could not be read contributes no
                // callers and looks exactly like a file with none, so an unreadable tree reports
                // every method as unwired — or, worse, leaves an exemption looking current.
                callers += try String(contentsOf: file, encoding: .utf8)
                seen += 1
            }
            guard seen > 0 else {
                throw CocoaError(.fileReadNoSuchFile)
            }
        }
        // **A member call with its first label** — `.card(of:`, not `card(`. Two earlier
        // spellings were each too wide: a bare `name(` matched `symlink(` for `link` and a
        // drawer's own `hide()` for the ledger's, and `.name(` still let one overload vouch for
        // another. A scan is only as wide as the spelling it searches for.
        // **Comments and string literals are not callers.** Raw substring matching counted a
        // commented-out call as wiring, so removing the last caller by commenting it out left
        // this check satisfied — the exact move the table is meant to catch.
        let live = Self.stripped(callers)
        return declared.filter { !live.contains(".\($0)") }
    }

    /// Source with `//` comments and string literals removed, so neither can vouch for a method.
    static func stripped(_ code: String) -> String {
        var out = ""
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = String(line)
            if let comment = text.range(of: "//") { text = String(text[text.startIndex..<comment.lowerBound]) }
            var kept = "", inString = false, escaped = false
            for character in text {
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { inString.toggle(); continue }
                if !inString { kept.append(character) }
            }
            out += kept + "\n"
        }
        return out
    }

    /// **Both directions.** An unwired method must be exempt with a reason, and an exemption whose
    /// method has since gained a caller must be removed — otherwise the table slowly becomes a
    /// list of names nobody has checked.
    @Test func everyExemptionIsRealAndEveryUnwiredMethodIsListed() throws {
        let unwired = try Self.unwired()
        let listed = Set(Self.exempt.keys)

        let unexplained = unwired.subtracting(listed).sorted()
        #expect(unexplained.isEmpty, """
            these ledger methods have no caller outside XiaolaiDictCore: \(unexplained). \
            Either give the capability a surface, delete it, or add a row to `exempt` saying why \
            it is called only from inside.
            """)

        let stale = listed.subtracting(unwired).sorted()
        #expect(stale.isEmpty, """
            these are listed as unwired and now have a caller: \(stale). Remove the row — an \
            exemption nobody rechecks is how this table stops meaning anything.
            """)
    }

    /// The scan can fail. A name that is not declared anywhere must not be quietly absorbed.
    @Test func thescanSeesWhatItClaimsTo() throws {
        let declared = try Self.publicFunctions(in: String(
            contentsOf: Self.root.appending(path: "Sources/XiaolaiDictCore/StudyDay.swift"),
            encoding: .utf8))
        #expect(declared.contains("introductions(since:"), "the scan read the file it thinks it did")
        #expect(Self.publicFunctions(in: "public func abc(") == ["abc("])
        #expect(Self.publicFunctions(in: "public func abc(of x: Int)") == ["abc(of:"])
        #expect(Self.publicFunctions(in: "public func abc(_ x: Int)") == ["abc("],
                "a wildcard label is written `abc(` at the call site")
        #expect(Self.publicFunctions(in: "public func abc(to x: Int)") == ["abc(to:"],
                "the label is the first identifier, not the text before the first colon")
        #expect(Self.publicFunctions(in: "public func abc(to x: Int = 1, b: Int)") == ["abc("],
                "a defaulted first parameter need not be written at the call site")
        #expect(Self.publicFunctions(in: "public mutating func abc(of x: Int)") == ["abc(of:"],
                "a modifier between `public` and `func` is still a public function")
        #expect(Self.publicFunctions(in: "public static func abc()") == ["abc("])
        #expect(Self.publicFunctions(in: "public var funcs: Int { 0 }").isEmpty,
                "a property whose name contains `func` is not a function")
        #expect(Self.stripped("a.b()  // c.d()").contains(".d(") == false, "a comment is not a caller")
        #expect(Self.stripped("let s = \".x(\"").contains(".x(") == false, "a string is not a caller")
        #expect(Self.stripped("a.b()").contains(".b("), "and real calls survive stripping")
        #expect(Self.publicFunctions(in: "    private func abc(").isEmpty)
    }
}
