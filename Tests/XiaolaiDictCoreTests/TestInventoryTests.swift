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
    /// Set to the count on 2026-09-26, the day the split landed — this file's own three included,
    /// which is why `XiaolaiDictCoreTests` reads 543 and not the 540 the incident was measured
    /// against. `Support` is absent because it holds no tests; it is the shared fixture target.
    static let floors = [
        "XiaolaiDictTests": 609,
        "XiaolaiDictCoreTests": 543,
        "DictionaryBridgeTests": 54,
        "LocalModelTests": 47,
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
