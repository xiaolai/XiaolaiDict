import Foundation
import Testing
@testable import XiaolaiDict
@testable import XiaolaiDictCore
import XiaolaiDictTestSupport
@testable import XiaolaiDictUI

/// The app's side of the local model: the store and the download on one side, the service on the
/// other. What is asserted here is the **lifecycle between them**, which neither piece can be asked
/// about on its own.
@MainActor
struct LocalModelCoordinatorTests {
    private static let gigabyte: UInt64 = 1_073_741_824

    /// The scratch directories this test made, held for as long as the test instance lives so they
    /// are removed when it ends. A local `let` would be released while the store is still in use.
    private let scratches = Recorder<[TemporaryDirectory]>([])


    private func coordinator(memory: UInt64 = 48 * gigabyte) -> LocalModelCoordinator {
        let scratch = TemporaryDirectory(named: "xiaolaidict-coordinator")
        scratches.withLock { $0.append(scratch) }
        let store = ModelStore(root: scratch.url)
        return LocalModelCoordinator(
            defaults: TemporaryDefaults.suite(), store: store,
            transport: LocalModelControllerTests.Transport(fails: true), physicalMemory: memory)
    }

    /// A coordinator over an **empty** store, talking to a scripted service.
    ///
    /// Empty on purpose: the controller reads the store in its own initialiser, so a store that
    /// already holds the model reads as ready from the first moment and a refresh over it finds
    /// nothing to announce — and the wire under test is never reached. The model is written in
    /// afterwards, which is also how one really arrives without this app downloading it: copied in,
    /// or installed by `--model-report`.
    private func coordinatorOverAnEmptyStore(
        service: ModelClientTests.Service, stillRunning: Recorder<Bool>
    ) -> (LocalModelCoordinator, ModelStore) {
        let scratch = TemporaryDirectory(named: "xiaolaidict-coordinator")
        scratches.withLock { $0.append(scratch) }
        let store = ModelStore(root: scratch.url)
        let client = ModelClient(
            connect: { service.connect($0) },
            servicePresence: { stillRunning.withLock { $0 } ? .running : .gone },
            // Short, because what is being measured is a service that will not go rather than the
            // reader's Mac being slow. The shipped bound is the service's own drain; waiting that
            // out here would measure the constant and not the wire.
            shutdownLimit: .milliseconds(50))
        let coordinator = LocalModelCoordinator(
            defaults: TemporaryDefaults.suite(), store: store, client: client,
            transport: LocalModelControllerTests.Transport(fails: true), physicalMemory: 48 * Self.gigabyte)
        return (coordinator, store)
    }

    /// **Installing a model ends the service holding the one before it.** The wire runs from the
    /// controller's `onInstalled` to the client's `unload`, and it is set in one place — the
    /// coordinator's initialiser — and reached nowhere else: the controller's own tests assign
    /// `onInstalled` themselves, which *overwrites* it, and the quarantine's tests hold it by hand.
    /// Both prove the value. Neither proves anything reads it, which is the shape of the two
    /// defects this file's rule was written for.
    @Test func aModelThatArrivesEndsTheServiceHoldingTheOldOne() async throws {
        let stillRunning = Recorder(true)
        // The real service answers "unloading" and exits a moment later, and it is the exit that
        // `unload` waits for — so here it is this flip, made as the service is asked.
        let service = ModelClientTests.Service(whenUnloaded: { stillRunning.withLock { $0 = false } })
        let (coordinator, store) = coordinatorOverAnEmptyStore(service: service, stillRunning: stillRunning)
        try ModelClientTests.installTheModel(into: store)

        coordinator.refresh()
        await unloadReaches(service)
        // The rung is let go only where the process was **seen** to go, so a second session — a
        // lookup prewarming, which is what the app does next — is the lift and nothing else.
        #expect(await sessionsOpened(prewarming: coordinator, of: service, until: 2) == 2,
                "the local rung was never let go again after the old service had ended")
        await coordinator.pruning?.value
    }

    /// **A service that would not end holds the local rung back.** The process with the replaced
    /// weights may still be answering, and an answer from the model the reader has just replaced is
    /// drawn exactly as confidently as any other. `ModelClientTests` holds the quarantine by hand to
    /// show a held rung answers nothing; what is asserted here is that *installing a model over a
    /// service that will not go* is what puts it there.
    @Test func aServiceThatWillNotEndHoldsTheLocalRungBack() async throws {
        // No `whenUnloaded`: this service is asked to end and stays, which is the failure.
        let service = ModelClientTests.Service()
        let (coordinator, store) = coordinatorOverAnEmptyStore(
            service: service, stillRunning: Recorder(true))
        try ModelClientTests.installTheModel(into: store)

        coordinator.refresh()
        await unloadReaches(service)
        // One: the session the unload itself opened. The rung is held from before the service was
        // asked and can only be let go by a process seen to have gone — so this is a settled state
        // and not an early reading, and `sessionsOpened` goes on asking across the whole window
        // that the test above opens its second session inside.
        #expect(await sessionsOpened(prewarming: coordinator, of: service, until: 2) == 1,
                "the local rung answered again while the replaced model's service was still running")
        await coordinator.pruning?.value
    }

    /// Waits for the wire `refresh()` spawns to reach the service. **Polled, not slept**: it runs on
    /// a task of its own and the unload inside it waits on a real clock, so any fixed wait here
    /// would be a guess that a loaded machine falsifies. The rung is held back *before* the service
    /// is asked, so once this has returned the hold is already in place — which is what makes the
    /// prewarming afterwards a question about the lift alone rather than about timing.
    private func unloadReaches(_ service: ModelClientTests.Service) async {
        for _ in 0..<400 where !service.asked.withLock({ $0.contains(.unload) }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(service.asked.withLock { $0.contains(.unload) },
                "installing a model never asked the service holding the old one to end")
    }

    /// Prewarms the way a lookup does until the service has been asked for `wanted` sessions, and
    /// answers how many it was asked for. Polled for the same reason, and the count rather than the
    /// clock is what is read: a lookup that opens a session is the local rung answering.
    private func sessionsOpened(
        prewarming coordinator: LocalModelCoordinator, of service: ModelClientTests.Service, until wanted: Int
    ) async -> Int {
        for _ in 0..<100 where service.sessions.withLock({ $0 }) < wanted {
            await coordinator.prewarm()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return service.sessions.withLock { $0 }
    }


    /// **The translation pane's download is the one the row offers, not the recommended one.** After
    /// a 9B download stops, the pane's button reads as able because *that* download can be resumed —
    /// and starting the recommended 4B instead fetches another three gigabytes while abandoning the
    /// one the reader asked for part-finished.
    @Test func theTranslationPanesDownloadIsTheOneTheRowOffers() async {
        let coordinator = coordinator()
        coordinator.choice.download(.large)
        for _ in 0..<500 where coordinator.choice.state.isDownloading {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard case .stopped(_, let stopped, _) = coordinator.choice.state else {
            Issue.record("the download did not stop: \(coordinator.choice.state)")
            return
        }
        #expect(stopped == .large)
        #expect(coordinator.choice.downloadable == .large)
        #expect(coordinator.choice.recommended == .standard, "the two would be the same and prove nothing")

        coordinator.translationActions.downloadModel()
        guard case .downloading(_, let size, _) = coordinator.choice.state else {
            Issue.record("the pane's download did not start: \(coordinator.choice.state)")
            return
        }
        #expect(size == .large, "the pane started a different model from the one the row offers")
        // **Waited out, not merely asked to stop.** A cancel is a request; the download's own task
        // goes on for a moment, and it recreates its staging directory — after the scratch
        // directory this test owns has already been removed. That is how one directory per run was
        // still being left behind after everything else had been cleaned up.
        coordinator.choice.cancel()
        for _ in 0..<500 where coordinator.choice.state.isDownloading {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!coordinator.choice.state.isDownloading)
    }
}
