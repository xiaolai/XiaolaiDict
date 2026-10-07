import Foundation
import Testing
import XiaolaiDictTestSupport

/// **A target that stops running its tests looks exactly like a target whose tests pass.**
///
/// `swift test` prints one `Test run with N tests` line per target, and `AGENTS.md` already records
/// that a *missing* line is a target that never ran. What it did not record is that a line can stay,
/// say "passed", and mean almost nothing — because `N` fell.
///
/// Measured here on 2026-09-26, during the module split, by a scripted edit that destroyed five
/// files: a Python one-liner of the shape `open(p, "w").write(… open(p).read() …)`, where the
/// truncating `open` is the receiver and so runs *before* the read. 660 lines of the model service
/// and 837 lines of its tests became empty files. Everything still compiled — an empty `main.swift`
/// is a valid executable and an empty test file is a valid test file — and `swift test` answered
/// **exit 0 with all four lines present and every one of them "passed"**, while `LocalModelTests`
/// went from **47 tests in 4 suites to 4 tests in 1 suite**. The only thing on screen that said
/// anything was wrong was the number.
///
/// So the floors below are the assertion, not the fix. They are floors and not equalities on
/// purpose: adding a test must never need a second edit here, and only a *drop* is ever a signal.
/// Raising one is a deliberate line in a diff, which is exactly the conversation a deleted test
/// should cause.
///
/// It counts `@Test` in the sources rather than parsing a run, because the run's four lines are
/// anonymous — nothing in them says which target answered — and because a scan cannot be fooled by
/// the run that did not happen.
struct TestInventoryTests {
    /// Per target: the fewest `@Test` declarations that may be present.
    ///
    /// Set to the count on 2026-09-26, the day the split landed. `Support` is absent because it
    /// holds no tests; it is the shared fixture target.
    ///
    /// **A floor is allowed to lag the real count, and raising one is optional.** That is the
    /// trade: requiring an edit here for every test added would make this a line people bump
    /// without reading, and a floor that lags by a handful still catches what it is for — the
    /// incident it was written for was 47 to 4.
    ///
    /// **Exact while the core is split** (2026-10-08, plan-macos-modularisation P0): every floor below was
    /// raised to its target's count, because a split *moves* tests between targets and a floor that lags by
    /// 97 lets a move lose 97 unseen. Each move lowers one floor and raises another by the same number.
    static let floors = [
        // Raised 2026-10-03 to the counts after the hover request lifecycle (ADR-0045, ADR-0046): six
        // source-grep checks of the watcher became behavioural tests, and the new lifecycle, lane,
        // budget, window-choice and site rules brought theirs. Raised 1,092 → 1,184 on 2026-10-04 by
        // WI-3b, to the count with `SelectedSittingWiringTests` (10): the floor had lagged through the
        // review module's wave, and it now records what is there. Raised 1,184 → 1,192 by WI-5's
        // `SittingEndWiringTests` (8): the end of a sitting's forecast and its text, forgot count,
        // slipping words and one-day increase, from the ledger to the model, the badge and the instrument.
        // Raised 1,192 → 1,225 by WI-7's reminder suites (33): `ReminderWiringTests` (18: who asks, a
        // declined grant, off touching nothing, the sitting that withdraws today, the log before any add,
        // every re-plan trigger, the pinned trigger, Later and Skip Today, the route and its fault, the
        // app's wire), `ReminderDeliveryTests` (7: what a banner says, its actions, the answers, one owner
        // of the permission, one file naming the center and its control), `ReminderReportTests` (3) and
        // `ReminderSectionTests` (5: the switch, its reason and its details).
        // Raised 1,225 → 1,233 by WI-8's regressions (8): an answer refused once its card has left the
        // sitting, and no other answer taken while its grade is written; a forgotten new card keeping
        // today's reminder, a lost log adding no second banner, the instrument planning a lost log as
        // the coordinator does, Review Selected past today's allowance, and the held-key guard driven
        // through `press` with a scan holding every control to it.
        // Raised 1,233 → 1,237 by the WI-8 follow-up (4), each pressing keys through SwiftUI's own
        // shortcuts rather than calling a closure: every card key naming the card drawn, a held key
        // answering that card once, the same into the real model and ledger, and `IconButton` running the
        // action of its latest render — the defect a held `2` on the E2E Mac found and `press` could not.
        // Raised 1,237 → 1,249 by audit-fix round 1 (12): undo refused while a write is in flight, a
        // failed "not today" and a stale failed read said or not, a suggestion past the first page,
        // exports in one second and an export that cannot open, a deleted reading's card, the app's
        // appearance from its own suite, a banner's answer awaited, a grant given back and a study
        // dictionary chosen re-planning, and the instrument that changes no ledger.
        // Raised 1,249 → 1,259 by audit-fix round 2 (+11, −1): a reused rowid refused at the refresh and
        // where a queued write lands, one erase at a time and announced, a copy left behind still
        // deletable, a permanent delete that missed a copy dropping its row and saying so, a selection
        // during a suspended read, a selection planned against its own dictionary's allowance, a failed
        // undo on the summary, practice freezing its study day, and the read-only door writing nothing —
        // less the ordinal headline test, which went with the dead `MemoryStrip.headline`.
        // Raised 1,259 → 1,267 by audit-fix round 3 (8): a click after a read's prune reaching no row the
        // read drops, and a click on an unlisted row reaching nothing; a partial undo reloading and saying
        // what it left; a preview landing after Cancel or during an erase dropped; a revealed card brought
        // back by undo with its answer; Save keying its note by the lookup's language through the app's
        // wire; a phrase-only primary recording no other dictionary's word; and the export's labels
        // catalogued.
        // Raised 1,267 → 1,274 by the closing pass after round 3 (7): a selection reaching nothing
        // Suggested hides, by a filter switch, a pane round trip and a search; an answer edited while the
        // sitting is held graded once seen, a revealed card whose answer was edited shown again as it is
        // now, and no renewal while a grade is written; and the export-label scan made to fail.
        // Raised 1,274 → 1,292 by the Settings options for R1b, R1c and R3 (18): Choose a Meaning with
        // the word-card option off and on, a reviewed or damaged word-only card, twice, an automatic
        // draft and the app's own suite (`WordCardReplacementWiringTests`, 7); the study options off by
        // default, one key each, a hand-set switch, the minimum's reason and the wait History's Confirm
        // applies, off and off the menu (`StudyOptionsWiringTests`, 8); the reminder details' reason (1);
        // and Later's delay chosen and refused (2).
        // Raised 1,292 → 1,308 by *Save This Phrase* (16, ADR-0049): `PhraseCollectingTests` (10: the study
        // dictionary's meaning leading the notice, what is offered and what is refused and why, the answer
        // as shown and never another dictionary's, proposals, the control's states and the unwired default)
        // and `PhraseCollectWiringTests` (6: the app's hook to the ledger, a save held for its own row,
        // already saved, a discarded reading, the panel's forwarding, the runner handing the phrase over).
        // Raised 1,308 → 1,318 by the final closing pass (10): one phrase, one card at the runner-to-ledger
        // seam — a phrase kept as its own entry's sense then saved, saved then met again, and a phrase filed
        // inside another word (`PhraseCollectWiringTests`, 3); and a card that can no longer be asked
        // leaving a Review sitting — replaced by R1b and graded, dropped on resume, paused, its reading
        // deleted, never drawn, passed over by Undo, and kept where it is askable again by the time the
        // reason is read (`ReviewWiringTests`, 7).
        // Raised 1,318 → 1,370 on 2026-10-08 to the exact count before the core was split (see above): it had
        // lagged by 52.
        "XiaolaiDictTests": 1_370,
        // **865 → 840 on 2026-10-04, a transfer and not a loss**: 25 tests moved to `ReviewKitTests`
        // with the code they test (ADR-0047) — parity 6, ReviewSession 11, the StudyDay struct 6 and
        // ReviewInstant 2. Core counted 894 before the move and 881 after it: 869 plus the 12 that WI-1
        // added here (the reopen fixture and its corrupt-row checks, the ReviewKit boundary checks).
        // Raised 840 → 900 the same day by WI-9b, to the count with `StudyReplayTests` (10): the
        // ledger's history replayed by `integrity()` — order, undo, practice, legacy grades, and every
        // way the check goes red. The floor had lagged since WI-1; it now records what is there.
        // Raised 900 → 905 by WI-3b's `SelectedCandidatesTests` (5): the Selected sitting's read, its
        // modes reaching their calls, and the commit refusing a card drawn while hidden.
        // Raised 905 → 907 by WI-5: R09's rule refusing undone and practised Forgot answers, and
        // asking it writing nothing — the rule the end of a sitting names slipping words by.
        // Raised 907 → 908 by WI-7: neither XPC service imports `ReviewKit` or `UserNotifications`,
        // nor depends on `ReviewKit`.
        // Raised 908 → 911 by WI-8 (3): a non-default scheduler's grade unreplayable, and half a memory
        // state corrupt in an event and on a card.
        // Raised 911 → 915 by audit-fix round 1 (4): a backup folder that cannot be listed, a busy
        // write-ahead log said by kind, a damaged note refused while lookups go on, and a practice just
        // before a retention window.
        // Raised 915 → 922 by audit-fix round 2 (7): a ledger migrated from each older schema shaped as a
        // fresh one and keeping every row, a regrade after an undo counted as the introduction, three
        // reads refusing an id they cannot name (bulk pause, archive, and the rest of the class), and an
        // erase whose rewrite failed after the delete reporting it.
        // Raised 922 → 926 by audit-fix round 3 (4): an answer edit making a drawn grade stale, a stored
        // value a read cannot name refused across the class (note id, target kind, disposition, script),
        // a card whose reading was deleted exported with its answer and tags, and the caller's labels.
        // Raised 926 → 930 by closing the scanner hole for every target (4): the compiler's import list
        // judging every target's table and dependencies, the planted bindings it refuses in a copy (the
        // regex-literal, backtick, `;`-directive and plain spellings, and hidden imports in a release's,
        // a bundle's and a sibling's `canImport` clause), the verdict failing every way it claims to, and
        // a list the compiler could not make throwing (ADR-0047, addendum 2026-10-05).
        // Raised 930 → 941 by R1b's ledger transform (11, `WordCardReplacementTests`): answer and tags
        // carried and the word-only card archived, with or without an answer; kept for reviews, for
        // practice and for an answer that differs; once only; all or nothing over a damaged answer and
        // refused over a damaged enrollment; which cards; and a note that is not a meaning.
        // Raised 941 → 959 by `PhraseCollectionTests` (18, ADR-0049): a saved phrase's note, its locators
        // and only its own dictionary's, once and said so, spellings refused and accepted, a damaged note
        // and answer, a discarded and a missing reading, a proposal and no answer, the queue agreeing,
        // the Library and the review card naming it, the export keeping its meaning, and a reading kept
        // under its word with the word still suggested.
        // Raised 959 → 973 by the final closing pass (14): a save recognising its own entry's meaning
        // already a card, at the sense and the entry rung, and only that entry, dictionary and language,
        // a phrase card made before still the answer, and a damaged note refused (`PhraseCollectionTests`,
        // 5); a card's reason for leaving named exactly where a grade is refused (`StudyReviewTests`, 1);
        // and in `ModuleBoundaryTests` (8) every target's conditions judged as the parser reads them, the
        // reviewer's two `canImport` plants and one after a `;`, the verdict failing every way, its flags
        // read off the script, an unlistable directory throwing, a target name with a digit, and the
        // manifest reader held to SwiftPM's own reading with a control it fails.
        // Raised 973 → 1,072 on 2026-10-08 to the exact count before the core was split: 1,070 were there (the
        // floor had lagged by 97), and two came with the split's guards — an undeclared import planted in a copy
        // of a test target refused, and each service refusing every module it may never bind.
        // **1,072 → 686 the same day, a transfer and not a loss**: 386 `@Test` left for `StudyKitTests` with the
        // ledger they test — 385 in 29 files, and `aCardAsksTheLemmatizerRatherThanRepeatingIt`, split out of
        // `LemmatizerTests` as the one test that mixed the two subjects.
        "XiaolaiDictCoreTests": 686,
        // Added 2026-10-08 with the target, at the 386 that moved out of `XiaolaiDictCoreTests` above.
        "StudyKitTests": 386,
        // Raised 54 → 83 on 2026-10-08 to the exact count before the core was split.
        "DictionaryBridgeTests": 83,
        "LocalModelTests": 48,
        // Added 2026-09-27 at 117, raised to 151 after three audit rounds and to 162 after a fourth, each
        // round adding regression tests. **It had no floor at all before that**, which
        // `everyTestTargetHasAFloor` existed to catch and did: the target shipped with the module and
        // was never registered, so the guard covered four of the five directories on disk. The count
        // was 45 before `PLAN.md` steps 0–5 and is not backdated — a floor records what is there, and
        // a drop from here is the signal. 162 before the sense aligner, 187 with it. Raised 206 → 300 on
        // 2026-10-08 to the exact count before the core was split.
        "AppleDictionaryFormatTests": 300,
        // Added 2026-09-29 with the target, at the count it shipped with. The three translations between a
        // reader's sentence and the matcher — lemma form, a captured range to a word, a word range back to
        // UTF-16 — have each been a defect class here before, so this floor guards the thin part.
        // Raised 10 → 16 on 2026-10-05: it had lagged at the shipping count (15 by then), and ADR-0049's
        // filings carrying the build and the walk that read them add one. Raised 16 → 29 on 2026-10-08 to the
        // exact count before the core was split.
        "PhraseLookupTests": 29,
        // Added 2026-10-04 with the target, at the 25 that moved out of `XiaolaiDictCoreTests` above.
        // The target links ReviewKit alone, so these passing is itself evidence the logic runs
        // without the Mac's modules. Raised to 28 the same day by WI-4's cooldown rule, the arm and the
        // surface it may be set from (`ConfirmationCooldownTests`): a target this small guards its
        // thin part only if the floor follows it. Raised to 41 the same day by WI-2's `SittingPlannerTests`
        // (13): the order and its pinned shuffle, the allowance under every order, the counts, and the
        // predicted count the reminder will ask. Raised to 51 by WI-9b's `ReplayTests` (10): the preimage
        // search against the clock and its limit, the pinned legacy boundary, and the chain's verdicts.
        // Raised to 63 by WI-3b's `SelectedSittingTests` (12): the allowance, put-away and sibling rules,
        // the mode frozen at the draw, the order, and the sitting's counts over random selections.
        // Raised to 75 by WI-5: `ForecastTests` (7: study days across daylight saving, the allowance,
        // put-away cards, one per note), `OneDayIncreaseTests` (3: expiry at the next study day, raising,
        // decoding) and two `ReviewSessionTests` (forgot over its denominator, practice apart, undo).
        // Raised to 116 by WI-6's reminder suites (41): `ReminderPlannerTests` (17: N at the fire instant,
        // never in the past, the cutoff, both 2026 clock changes, the pinned zone, no string in the
        // content), `ReminderLogTests` (9: Later, withdrawals, add outcomes, off and on, decoding that
        // fails closed, pruning, identifiers) and `ReminderReconcilerTests` (15: the intent → add → added
        // protocol, the write before any action, the prefix, a fixpoint, one banner a day undisturbed and
        // at most two under sixty simulated months of failures).
        // Raised to 119 by WI-8 (3): the search complete at its documented boundary, a scheduler's
        // identity naming every parameter but retention, and a lost log spending today alone.
        // Raised to 125 by audit-fix round 1 (6): an interval past `Int.max` capped, an elapsed span past
        // it refused, the replay of that span a verdict, a list that is not a list an unreadable log, and
        // a skipped cutoff moving only its own day, from both sides of every 2026 transition.
        // Raised to 126 by the closing pass after round 3 (1): the card in front of the reader renewed at
        // the revision it is at now, as a new showing, and nothing else in the sitting.
        // Raised to 130 by the Settings options (4): the cooldown's minimum chosen and a stored one off
        // the menu, and Later's delay chosen and offered with the one kept.
        // Raised to 131 by the final closing pass (1): a card that left a sitting counted by reason, not
        // answered, and passed over by Undo.
        "ReviewKitTests": 131,
    ]

    private static let testsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func everyTargetStillRunsTheTestsItHad() throws {
        var shortfalls: [String] = []
        for (target, floor) in Self.floors.sorted(by: { $0.key < $1.key }) {
            let found = try Self.tests(in: target)
            if found < floor { shortfalls.append("\(target): \(found) @Test, floor \(floor)") }
        }
        #expect(shortfalls.isEmpty, """
            a test target lost tests — \(shortfalls.joined(separator: "; ")).
            If they were deliberately deleted, lower the floor in the same change and say why.
            """)
    }

    /// **The floors have to name every target, or the guard covers whatever it happens to list.**
    /// The same defect as a source scan that names one directory: it passes forever while its
    /// subject moves out from under it.
    @Test func everyTestTargetHasAFloor() throws {
        let directories = try FileManager.default
            .contentsOfDirectory(at: Self.testsRoot, includingPropertiesForKeys: nil)
            .filter(\.hasDirectoryPath)
            .map(\.lastPathComponent)
            .filter { $0 != "Support" }
        #expect(Set(directories) == Set(Self.floors.keys), """
            test targets on disk: \(directories.sorted()); targets with a floor: \
            \(Self.floors.keys.sorted())
            """)
    }

    /// **And the floors must be reachable — a floor of zero, or one nobody can fail, guards nothing.**
    /// Checked by asking each count to be *above* zero as well as at or above its floor: a target
    /// whose whole directory became unreadable would otherwise pass the scan by producing nothing.
    @Test func noFloorIsVacuous() throws {
        for (target, floor) in Self.floors {
            #expect(floor > 0, "\(target) has a floor of \(floor), which nothing can fail")
            #expect(try Self.tests(in: target) > 0, "no @Test found in \(target) at all")
        }
    }

    /// `@Test` occurrences under `Tests/<target>`. Full-line comments are stripped for the same
    /// reason `SourceScan` strips them: a doc comment explaining `@Test` is not a test.
    private static func tests(in target: String) throws -> Int {
        let root = testsRoot.appending(path: target)
        var count = 0
        for (_, code) in try SourceScan.code(under: root) {
            count += code.components(separatedBy: "@Test").count - 1
        }
        return count
    }
}
