import Foundation
import Testing

@testable import XiaolaiDict

/// Restarting the app in place, exactly once.
@MainActor
struct SelfRelaunchTests {
    private final class Log {
        private(set) var launches: [URL] = []
        private(set) var quits = 0
        func launched(_ url: URL) { launches.append(url) }
        func quit() { quits += 1 }
    }

    private func relaunch(
        bundle: URL? = URL(fileURLWithPath: "/Applications/XiaolaiDict.app"), launches: Bool = true
    ) -> (SelfRelaunch, Log) {
        let log = Log()
        return (
            SelfRelaunch(
                bundleURL: { bundle },
                launch: { log.launched($0); return launches },
                quit: { log.quit() }),
            log)
    }

    @Test func itLaunchesTheBundleItIsRunningFromAndThenQuits() async {
        let (relaunch, log) = relaunch()
        #expect(await relaunch.run())
        #expect(log.launches.map(\.path) == ["/Applications/XiaolaiDict.app"])
        #expect(log.quits == 1)
    }

    /// The whole reason this is a value with a flag rather than two free calls. A reader can press
    /// the button again before the app goes away, and a permission poll can answer twice in the
    /// same second — both would otherwise start a second copy.
    @Test func asecondCallDoesNothingAtAll() async {
        let (relaunch, log) = relaunch()
        #expect(await relaunch.run())
        #expect(await !relaunch.run())
        #expect(await !relaunch.run())
        #expect(log.launches.count == 1)
        #expect(log.quits == 1)
    }

    @Test func itSaysWhetherItHasStarted() async {
        let (relaunch, _) = relaunch()
        #expect(!relaunch.hasStarted)
        await relaunch.run()
        #expect(relaunch.hasStarted)
    }

    /// No bundle, no relaunch — and nothing claimed either, so a later call with a bundle still
    /// works. Claiming the flag on a failure would make the app unrestartable for the rest of its
    /// life over a transient answer.
    @Test func withNoBundleItDoesNothingAndStaysAvailable() async {
        let (relaunch, log) = relaunch(bundle: nil)
        #expect(await !relaunch.run())
        #expect(log.launches.isEmpty)
        #expect(log.quits == 0)
        #expect(!relaunch.hasStarted)
    }

    /// Each value owns its own flag. A process-wide one would be shared by every test in a
    /// parallel run, and whether one passed would depend on which ran first.
    @Test func twoRelaunchersDoNotShareAFlag() async {
        let (first, firstLog) = relaunch()
        let (second, secondLog) = relaunch()
        #expect(await first.run())
        #expect(await second.run())
        #expect(firstLog.launches.count == 1)
        #expect(secondLog.launches.count == 1)
    }
}

extension SelfRelaunchTests {
    /// **A refused launch must not take the app with it.** Quitting on a launch that never
    /// happened — a damaged bundle, a Gatekeeper refusal, a missing volume — turns a restart into
    /// a disappearance, and the first version did exactly that: it ignored the asynchronous result
    /// and quit regardless.
    @Test func afailedLaunchDoesNotQuitAndCanBeRetried() async {
        let (relaunch, log) = relaunch(launches: false)
        #expect(await !relaunch.run())
        #expect(log.launches.count == 1, "it should have tried")
        #expect(log.quits == 0, "it quit after a launch that failed")
        // The guard is released, so the reader can try again rather than being stuck for the life
        // of the process.
        #expect(!relaunch.hasStarted)
    }
}
