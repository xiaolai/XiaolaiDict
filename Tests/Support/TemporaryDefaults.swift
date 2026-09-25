import Foundation
import Synchronization

/// A defaults suite for one test, which leaves nothing behind.
///
/// **Measured 2026-09-22: 4,164 suites from this project's tests had accumulated in
/// `~/Library/Preferences`,** one per test per run. Most tests never cleaned up. The ones that
/// did called `removePersistentDomain(forName:)`, which empties the domain and leaves its plist
/// file where it was — with or without a synchronize after it.
///
/// **And emptying a domain is itself a write, which can land after the file is gone.** cfprefsd
/// writes the emptied domain back asynchronously, and when the process exits first nothing waits
/// for it: a whole run left 37 empty plists behind with removal in place, and a suite emptied
/// twice survived 10 times in 10. So a suite is removed without touching the domain at all —
/// this process's own pending writes are flushed first, so none of them lands later, and then
/// the file is deleted. 0 in 10, either way, in a process on its own — but in a full parallel
/// run a handful still land after the delete (4 per run, measured), so removal at exit is the
/// best this process can do, not a guarantee. The guarantee is made from outside, once every
/// test process has exited and nothing can write for it: `make` runs
/// `Tools/clean-test-defaults.sh` after `swift test`, and it checks that what it removed stays
/// removed.
///
/// Every suite a test makes is registered here and removed when the test process exits, because
/// the tests build them inline — `AppearanceStore(defaults: TemporaryDefaults.suite())` — where no
/// per-test `defer` fits, and a per-test `defer` is what the old tests already got wrong.
///
/// A name carries its process's pid. A run that dies before it exits cannot clean up after
/// itself, so the first suite of the next run removes every suite whose process is gone — and
/// only those, so two test processes running at once never take each other's suites away.
public enum TemporaryDefaults {
    /// Nothing but a test suite starts with this, so no real app's domain can match it.
    public static let prefix = "xiaolaidict.test."

    /// A fresh suite name, registered for removal. For a test that must address the domain by
    /// name — CFPreferences, and the migration between two domains.
    public static func name() -> String {
        _ = sweptAbandoned
        let name = "\(prefix)\(getpid()).\(UUID().uuidString)"
        registered.withLock { $0.append(name) }
        return name
    }

    /// A fresh suite, registered for removal.
    public static func suite() -> UserDefaults {
        // A name built above is always a valid suite name; a nil here is a broken Foundation.
        UserDefaults(suiteName: name())!
    }

    /// Removes a suite completely: flushes this process's writes to it, then deletes its file.
    /// Never by emptying the domain — see the type's comment for why that writes it back.
    public static func remove(_ name: String) {
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: file(of: name))
    }

    /// Where a suite's plist lives, for a test that has to look.
    public static func file(of name: String) -> URL {
        preferences.appendingPathComponent("\(name).plist")
    }

    // MARK: - Removal

    private static let preferences = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences", isDirectory: true)

    private static let registered = Mutex<[String]>([])

    /// Runs once per process, on the first suite asked for: registers removal at exit, then
    /// clears what dead test processes left.
    private static let sweptAbandoned: Void = {
        atexit { TemporaryDefaults.removeRegistered() }
        removeAbandoned()
    }()

    private static func removeRegistered() {
        for name in registered.withLock({ $0 }) { remove(name) }
    }

    /// Suites whose pid names no running process. `kill(pid, 0)` failing with `ESRCH` is the
    /// kernel saying there is no such process; any other answer — including one owned by
    /// someone else — is left alone.
    private static func removeAbandoned() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        for file in files where file.hasPrefix(prefix) && file.hasSuffix(".plist") {
            let name = String(file.dropLast(".plist".count))
            guard let pid = pid_t(name.dropFirst(prefix.count).prefix { $0 != "." }) else { continue }
            if kill(pid, 0) != 0, errno == ESRCH { remove(name) }
        }
    }
}
