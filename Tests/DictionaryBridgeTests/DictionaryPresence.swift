import DictionaryModel
import Testing
@testable import DictionaryBridge

/// Which dictionaries this Mac has enabled, for the tests that measure one by name.
///
/// **These tests reproduce a measurement, so they must not quietly stop reproducing it.** The
/// per-dictionary sense-key table is a fact about real bundles, re-derived through the live lookup
/// path rather than restated from a note — which is the whole reason they talk to the real
/// framework. A reader who turns a dictionary off in Dictionary.app should not be handed failures
/// about code they did not touch; a reader who turns one off *and never notices the measurement
/// stopped* is the worse outcome, and is what `theDictionariesTheseTestsMeasureAreReported` exists
/// to prevent.
///
/// So: absent dictionaries skip, and the census below says so out loud on every run.
enum DictionaryPresence {
    /// Cached: every trait below asks, and each call crosses into the private API.
    nonisolated(unsafe) private static let enabled: Set<String> = {
        Set(DictionaryBridge.capabilities().map(\.identity.name))
    }()

    /// Whether a dictionary whose name contains `name` is enabled.
    static func isEnabled(_ name: String) -> Bool {
        enabled.contains { $0.contains(name) }
    }

    static var names: [String] { enabled.sorted() }

    /// The dictionaries some test here measures by name, and what each is measured for.
    ///
    /// **譯典通 said "the positional rung" and that was wrong.** Measured 2026-09-28 across the enabled
    /// set: the Oxford American Writer's Thesaurus answers with **11 positional entries and 199
    /// positional senses**, beside 6 publisher entries and 1 with no senses to key — so it exercises all
    /// three rungs by itself, and the positional one was never uncovered. The census was therefore
    /// printing, prominently, that a rung went unmeasured while it was being measured, and telling a
    /// reader of Simplified Chinese to enable a Traditional Chinese dictionary to restore it. A loud
    /// wrong line is worse than a quiet right one.
    ///
    /// What 譯典通 does uniquely carry is the CJK half of the repeated-record premise — it answers 的
    /// with three records under one id — which is a different claim and is what it is listed for now.
    static let measured = [
        ("New Oxford American", "publisher sense ids on every sense"),
        ("牛津", "publisher sense ids, as lexids"),
        ("Oxford American Writer", "the positional rung — 11 entries and 199 senses here"),
        ("譯典通", "the CJK repeated-record premise — 的 answers with three records under one id"),
        ("Collins COBUILD", "a sideloaded conversion with no senses to key"),
    ]

    static var missing: [(String, String)] { measured.filter { !isEnabled($0.0) } }
}

/// **The census, which always runs.** A skipped test is easy to miss in a green run; this is the
/// line that says which measurements this machine could not make. It asserts only what must be
/// true anywhere — that the lookup path answered at all — so it cannot fail for a reader's choice
/// of dictionaries, and cannot pass while measuring nothing.
struct DictionaryCensusTests {
    @Test func theDictionariesTheseTestsMeasureAreReported() throws {
        let names = DictionaryPresence.names
        try #require(!names.isEmpty, "no dictionary is enabled at all — the lookup path answered nothing")
        print("\n  dictionaries enabled on this Mac (\(names.count)): \(names.joined(separator: ", "))")
        let missing = DictionaryPresence.missing
        guard !missing.isEmpty else {
            print("  every dictionary these tests measure is enabled\n")
            return
        }
        print("  NOT MEASURED — enable these in Dictionary.app to restore the checks:")
        for (name, what) in missing { print("    \(name) — \(what)") }
        print("")
    }
}

