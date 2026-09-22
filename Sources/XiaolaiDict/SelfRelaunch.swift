import AppKit
import Foundation

/// Restarting XiaolaiDict in place, once.
///
/// A reader should never be told to quit and reopen an app. When macOS will not hand a
/// freshly-granted permission to a running process, the app is what knows that and the app is what
/// should act on it — the instruction "quit and reopen" is the fix, written down and delegated.
///
/// **Not wired to anything yet, on purpose.** Whether macOS 27 still withholds a Screen Recording
/// grant from a running process is unmeasured: nothing in `dev-docs/` records it, third-party
/// reporting in 2026 says it does, and settling it means revoking the permission on the end-to-end
/// Mac and granting it again with a person in front of the screen — TCC refuses screen capture to
/// anything launched over SSH. Firing this on a guess would restart the app for readers who did not
/// need it, and a restart nobody needed reads as breakage. `dev-docs/plan-first-run-setup.md` §5
/// holds the measurement that decides it.
///
/// The three calls are closures so the decision can be tested without restarting the test runner,
/// which is the only part of this worth testing and the only part that can be got wrong twice.
///
/// A `final class` rather than a struct so the "already started" flag belongs to the value that
/// owns it. A process-wide static would be shared by every test in a parallel run, and whether one
/// passed would depend on which ran first.
///
/// `@MainActor` because every part of it is: `NSApplication.terminate` and `NSWorkspace.shared` are
/// main actor-isolated, and reaching them from a `@Sendable` closure warned rather than being
/// wrong quietly. Restarting an app is a main-thread operation, so the type says so instead of
/// carrying a lock to pretend otherwise.
@MainActor
final class SelfRelaunch {
    let bundleURL: () -> URL?
    /// Starts the replacement, answering whether it actually started. **The answer is the whole
    /// point**: `openApplication` reports failure asynchronously, and a version that ignored it
    /// quit regardless — so a launch that was refused left the reader with no app at all.
    let launch: (URL) async -> Bool
    let quit: () -> Void

    init(
        bundleURL: @escaping () -> URL?,
        launch: @escaping (URL) async -> Bool,
        quit: @escaping () -> Void
    ) {
        self.bundleURL = bundleURL
        self.launch = launch
        self.quit = quit
    }

    static let system = SelfRelaunch(
        bundleURL: { Bundle.main.bundleURL },
        launch: { url in
            let configuration = NSWorkspace.OpenConfiguration()
            // A second copy, deliberately: this process is about to end, and waiting for it to die
            // before starting the replacement is what leaves a reader with no app at all when the
            // quit is refused.
            configuration.createsNewApplicationInstance = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                return true
            } catch {
                return false
            }
        },
        quit: { NSApplication.shared.terminate(nil) })

    /// Restarts the app, and does nothing at all on any later call.
    ///
    /// **Idempotent because every route to it can happen twice.** A reader can press the button
    /// again before the app goes away, and the permission poll can answer twice in the same second;
    /// both would otherwise start a second copy. Returns whether this call was the one that acted,
    /// so a caller can tell "restarting" from "already restarting" rather than guess.
    @discardableResult
    func run() async -> Bool {
        guard let url = bundleURL() else { return false }
        // Claimed before the launch, so a second caller arriving while it is in flight cannot
        // start a third copy.
        guard !hasStarted else { return false }
        hasStarted = true

        // **Quit only once the replacement is running.** Quitting on a launch that was refused —
        // a damaged bundle, a Gatekeeper refusal, a missing volume — is how a restart becomes a
        // disappearance. The guard is released on failure so the reader can try again.
        guard await launch(url) else {
            hasStarted = false
            return false
        }
        quit()
        return true
    }

    /// Whether a relaunch has already been started by this value.
    private(set) var hasStarted = false
}
