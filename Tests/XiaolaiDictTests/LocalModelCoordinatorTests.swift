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

    private func coordinator(memory: UInt64 = 48 * gigabyte) -> LocalModelCoordinator {
        let store = ModelStore(root: FileManager.default.temporaryDirectory
            .appending(path: "xiaolaidict-coordinator-\(UUID().uuidString)", directoryHint: .isDirectory))
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
        coordinator.choice.cancel()
    }
}
