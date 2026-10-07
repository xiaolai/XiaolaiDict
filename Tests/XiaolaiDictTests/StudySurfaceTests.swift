import Foundation
import Testing
import XiaolaiDictTestSupport

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
        "Sources/StudyKit/StudyLedger.swift",
        "Sources/StudyKit/StudyLibrary.swift",
        "Sources/StudyKit/StudyOrganisation.swift",
        "Sources/StudyKit/StudyReviewLedger.swift",
        "Sources/StudyKit/StudyExport.swift",
        "Sources/StudyKit/StudyRecovery.swift",
        // The allowance's denominator, which stayed with the ledger when the `StudyDay` struct moved.
        "Sources/StudyKit/StudyIntroductions.swift",
        // The ledger proper: reading history, recovery and erasure are study capabilities too,
        // and `history`, `encounters` and `integrity` are exactly the shape this looks for.
        "Sources/StudyKit/Ledger.swift",
        // The review logic, a target of its own since 2026-10-04 (ADR-0047).
        "Sources/ReviewKit/StudyDay.swift",
        "Sources/ReviewKit/StudyCards.swift",
        "Sources/ReviewKit/ReviewSession.swift",
        "Sources/ReviewKit/MemoryScheduler.swift",
        // The post-confirmation cooldown experiment's rule (review-module-plan §8.3c).
        "Sources/ReviewKit/ConfirmationCooldown.swift",
        // What a Review sitting asks, in what order, and the predicted count (WI-2).
        "Sources/ReviewKit/SittingPlanner.swift",
        // The end of a sitting: the week ahead, and today's one-day increase of the allowance (WI-5).
        "Sources/ReviewKit/Forecast.swift",
        "Sources/ReviewKit/OneDayIncrease.swift",
        // A card's history re-run, and the ledger's read that feeds it (WI-9b).
        "Sources/ReviewKit/Replay.swift",
        "Sources/StudyKit/StudyReplay.swift",
        // The reminder: what to plan, the log of what was asked for, and the reconciler (WI-6), wired by
        // the app's `ReminderCoordinator` (WI-7).
        "Sources/ReviewKit/ReminderSettings.swift",
        "Sources/ReviewKit/ReminderPlanner.swift",
        "Sources/ReviewKit/ReminderLog.swift",
        "Sources/ReviewKit/ReminderReconciler.swift",
        // Keeping, the collection's own predicate, and what is in the way of a kept meaning — Review's
        // count by reason sits beside the count it replaced.
        "Sources/StudyKit/LookupKeeping.swift",
        // R1b: a reading's word-only cards replaced by the meaning chosen on it, a reader option.
        "Sources/StudyKit/WordCardReplacement.swift",
        // A phrase the reader saved as a card from the lookup panel (ADR-0049).
        "Sources/StudyKit/PhraseCollection.swift",
    ]

    /// Where a caller would be — **minus the declaring file's own module**, since a method called
    /// only by its own module is what this looks for, and never the tests, since a test is not a
    /// surface. So a StudyKit capability is wired by the app, the view layer, the dictionary service or
    /// the instruments; a ReviewKit one by any of those or by StudyKit, which became a legitimate
    /// outside caller the day the review logic left the core. `ReviewKit` is not a calling root: it
    /// depends on nothing, so it cannot call anything declared here but its own.
    ///
    /// **`StudyKit` replaced `XiaolaiDictCore` here when the ledger left the core (2026-10-08), and the
    /// core is no root at all**: it depends on neither `StudyKit` nor `ReviewKit` any more, so it cannot
    /// call a capability declared in either — kept, it could only vouch for one by a name that happens to
    /// match. The unwired set and the exemption table were the same before and after the change.
    private static let calling = [
        "Sources/StudyKit", "Sources/XiaolaiDict", "Sources/XiaolaiDictUI",
        "Sources/XiaolaiDictService", "Tools",
    ]

    /// **What each calling root must be seen to read** — named, not counted (`SourceScan.unread`): a root
    /// that walked other files, or none of its own, would report every capability declared elsewhere as
    /// wired or unwired by accident.
    private static let callingCanaries: [String: [String]] = [
        "Sources/StudyKit": ["Ledger.swift"],
        "Sources/XiaolaiDict": ["XiaolaiDictApp.swift"],
        "Sources/XiaolaiDictUI": ["LibraryView.swift"],
        "Sources/XiaolaiDictService": ["main.swift"],
        "Tools": ["e2e.sh"],
    ]

    /// A calling root that did not read the files it is known to hold.
    struct Unread: Error, CustomStringConvertible {
        let root: String
        let files: [String]
        var description: String { "the walk of \(root) did not read \(files)" }
    }

    /// The calling roots for one declaring file: every root but the module it lives in.
    static func callers(of declaringFile: String) -> [String] {
        calling.filter { !declaringFile.hasPrefix("\($0)/") }
    }

    /// Called only from inside its own module, on purpose. **Each row is a reason**: a bare
    /// allow-list is how a rule like this dies, and `everyExemptionIsRealAndEveryUnwiredMethodIsListed`
    /// fails in both directions so a name cannot rot here after it gains a caller.
    private static let exempt: [String: String] = [
        "hasAnyNote(": "Compatibility existence query; effective collection surfaces use collectedCount.",
        "notes(": """
            The whole collection, decoded. **No longer a surface**: the app asks hasAnyNote for             existence and library(_:) for a page, both of which read what they need. What is left             is the tests' way of seeing every row after a write, and that is worth keeping.
            """,
        "isDue(at:": "A predicate on a value, used wherever a card is judged.",
        "readiness(of:": "One note's facts, gathered for the library's own query.",
        // WI-2: the window plans its sitting through `SittingPlanner` over `sittingCandidates`.
        "dueCards(at:": """
            The SQL spelling of the queue, kept as the reference the planner is held to             (thePlannerReproducesTheSqlQueueOrder) and as the filter-before-LIMIT witness. The             window draws from sittingCandidates.
            """,
        "scheduledDays(stability:": "The scheduler's own arithmetic.",
        // WI-8: the coordinator asked it about *now* after a grade, which is not a reminder's question.
        "askableCount(at:": """
            The predicted count at a fire instant, asked inside ReviewKit by ReminderPlanner.plan, \
            which the app's ReminderCoordinator calls on every pass.
            """,
        "link(noteID:": "Joins a note to a lookup inside enrol, which is the only correct caller.",
        // Visible once LookupKeeping.swift joined the scan (WI-4): the same shape as `link`.
        "explicitlyKeep(noteID:": "Marks a note as one the reader asked for, inside enrol, the only correct caller.",
        "locators(of:": "Evidence carried with a phrase note; read by the note's own equality.",
        "existingCard(of:": "Reads without creating; the timeline and the queue use it.",
        // WI-5: `OneDayIncrease` keeps its day as seconds since 1970, as the ledger does, so it spells
        // its own encoding rather than let `JSONEncoder` choose one for a `Date`.
        "encode(to:": """
            Encodable's requirement, called by JSONEncoder and never by name: inside \
            OneDayIncreaseStore.raise, and for the reminder log, its days and its content inside \
            ReminderLogStore's save.
            """,
        "history(of:": "A lemma's lookups, read by the drawer's own projection.",
        "reviews(ofCard:": "One card's events, gathered by `timeline`.",
        "answer(of:": "One note's answer, read by `enroll`, `export` and `revealed`.",
        // **Exposed by the label-aware match**, which stopped one overload vouching for another.
        // Each had an in-Core caller all along and was hidden behind a namesake that did not.
        "lookupIDs(fromSource:": "One source's lookups, counted by the erasure impact.",
        "remove(noteID:": "One note, removed by `removeFromStudy`.",
        "note(for:": "Looks a target up during `enroll`, to decide new against existing.",
        // **Exposed by audit-fix round 1**: each was vouched for by an app wrapper nothing called — dead
        // code that made a Core method read as wired. The wrappers went; the in-Core callers were there all
        // along.
        "enroll(": "Every enrolment goes through `keep`, which calls it inside the ledger.",
        "delete(lookup:": "One lookup, removed by `deleteReading` for each reading the reader erases.",
        // **Exposed by audit-fix round 2**, the same way: `LedgerStore.tag(noteID:)` had no caller.
        "tag(noteID:": "One note, tagged by `tag(noteIDs:)` for each note in the selection.",
        "interval(stability:": "The scheduler's own arithmetic.",
        "recall(elapsedDays:": "The forgetting curve; the scheduler's own arithmetic.",
        // Newly visible once `public static func` stopped being skipped: the erasure path's own
        // helper, called twice inside `StudyRecovery`.
        "appManagedBackups(besides:": "The copies this app made; read by the impact count and the erase.",
        // **Named, not forgiven.** These are gaps with no surface designed yet, and saying so here
        // is what stops the next audit rediscovering them as new — ADR-0038.
        "card(of:": "Creates the card for a note; enrol is the only correct caller.",
        "integrity(": "GAP — D01 has no recovery surface.",
        "replayVerdicts(": """
            GAP — read by integrity, which reports the histories that do not account for their \
            cards; the legacy grades it names reach nobody until D01 has a recovery surface.
            """,
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
        #expect(Set(Self.callingCanaries.keys) == Set(Self.calling), "every calling root names what it must read")
    }

    /// Which public study methods no surface calls.
    static func unwired() throws -> Set<String> {
        var declaredIn: [String: [String]] = [:]
        for path in declaring {
            let code = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            declaredIn[path] = publicFunctions(in: code)
        }
        // Thrown, never defaulted: a scanner that finds nothing to scan guards nothing.
        guard declaredIn.values.contains(where: { !$0.isEmpty }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var callersIn: [String: String] = [:]
        for root in calling {
            var text = ""
            let directory = Self.root.appending(path: root)
            let walk = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil,
                // **Build products are not callers.** `Tools/makeicon` is its own package, and
                // reading its `.build` checkout found "callers" in Swift's own source — which is
                // how a scan reports a capability as wired when nothing in this app touches it.
                options: [.skipsHiddenFiles])
            var seen = 0
            var read: [URL] = []
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
                text += try String(contentsOf: file, encoding: .utf8)
                seen += 1
                read.append(file)
            }
            guard seen > 0 else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let unread = SourceScan.unread(callingCanaries[root] ?? [], in: read)
            guard unread.isEmpty else { throw Unread(root: root, files: unread) }
            // **Comments and string literals are not callers.** Raw substring matching counted a
            // commented-out call as wiring, so removing the last caller by commenting it out left
            // this check satisfied — the exact move the table is meant to catch.
            callersIn[root] = Self.stripped(text)
        }
        // **A member call with its first label** — `.card(of:`, not `card(`. Two earlier
        // spellings were each too wide: a bare `name(` matched `symlink(` for `link` and a
        // drawer's own `hide()` for the ledger's, and `.name(` still let one overload vouch for
        // another. A scan is only as wide as the spelling it searches for.
        var unwired: Set<String> = []
        for (path, declared) in declaredIn {
            let live = callers(of: path).compactMap { callersIn[$0] }.joined(separator: "\n")
            unwired.formUnion(declared.filter { !live.contains(".\($0)") })
        }
        return unwired
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
        // **A call may break its line after the parenthesis**, and `.name(\n    label:` is the same
        // call as `.name(label:`. Matching only the second reported `reviewSitting(from:` as unwired
        // while the Review window called it (WI-2): a scan is only as wide as its spelling.
        return out.replacing(/\(\s+/, with: "(")
    }

    /// **Both directions.** An unwired method must be exempt with a reason, and an exemption whose
    /// method has since gained a caller must be removed — otherwise the table slowly becomes a
    /// list of names nobody has checked.
    @Test func everyExemptionIsRealAndEveryUnwiredMethodIsListed() throws {
        let unwired = try Self.unwired()
        let listed = Set(Self.exempt.keys)

        let unexplained = unwired.subtracting(listed).sorted()
        #expect(unexplained.isEmpty, """
            these ledger methods have no caller outside their own module: \(unexplained). \
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
            contentsOf: Self.root.appending(path: "Sources/StudyKit/StudyIntroductions.swift"),
            encoding: .utf8))
        #expect(declared.contains("introductions(since:"), "the scan read the file it thinks it did")
        #expect(Self.callers(of: "Sources/StudyKit/Ledger.swift")
                == ["Sources/XiaolaiDict", "Sources/XiaolaiDictUI", "Sources/XiaolaiDictService", "Tools"],
                "a StudyKit method is not wired by StudyKit itself")
        #expect(Self.callers(of: "Sources/ReviewKit/StudyCards.swift") == Self.calling,
                "a ReviewKit method is wired by StudyKit too")
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
        #expect(Self.stripped("a.b(\n        of: x)").contains(".b(of:"),
                "a call that breaks its line after the parenthesis is still a call")
        #expect(Self.publicFunctions(in: "    private func abc(").isEmpty)
    }
}
