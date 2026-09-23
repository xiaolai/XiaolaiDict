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
