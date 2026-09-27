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
    static let measured = [
        ("New Oxford American", "publisher sense ids on every sense"),
        ("牛津", "publisher sense ids, as lexids"),
        ("譯典通", "sense structure with no ids — the positional rung"),
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
