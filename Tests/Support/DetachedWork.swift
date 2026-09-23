import Foundation

/// **Waiting for work a call started and did not await.**
///
/// `LocalModelController.refresh()` fires a prune on a detached task and returns at once. That
/// prune *creates* `.staging` and the store lock inside the store's root — so one that outran the
/// scratch directory's removal put the directory back **after** `TemporaryDirectory` had deleted
/// it, and left it there for good with the lock inside. Measured 2026-09-23: four such directories,
/// one per full run, each holding exactly `.staging/store.lock`.
///
/// A fixed sleep would be the wrong shape twice — too short under load, and wasted otherwise. The
/// lock is the last thing the prune writes, so waiting for it to appear is waiting for the work to
/// be over.
public enum DetachedWork {
    /// How long to wait in total, and how often to look. A prune of an empty store takes
    /// microseconds; the bound is here so a test that is wrong about what it is waiting for fails
    /// in two seconds rather than hanging the suite.
    private static let tries = 400
    private static let interval = Duration.milliseconds(5)

    /// Waits for `url` to exist. Answers whether it arrived, so a caller that needs it to can say
    /// so — most callers only need the wait.
    @discardableResult
    public static func settles(at url: URL) async -> Bool {
        for _ in 0..<tries {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: interval)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
