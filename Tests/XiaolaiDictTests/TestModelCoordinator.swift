import Foundation
@testable import XiaolaiDict
import ModelKit
import XiaolaiDictCore
import XiaolaiDictTestSupport

/// The model coordinator a test is given: a store in a directory of its own, and a client that can
/// reach no service.
///
/// **Nothing in the suite may touch the reader's own model directory**, which holds gigabytes and is
/// what the app downloads into — nor open a real XPC session to the model service. `XiaolaiDictApp`
/// takes the coordinator for that reason; this is what every test hands it.
extension LocalModelCoordinator {
    private struct NoService: Error {}

    @MainActor
    static func temporary(defaults: UserDefaults) -> LocalModelCoordinator {
        LocalModelCoordinator(
            defaults: defaults,
            store: ModelStore(root: ScratchFile.unmade("app", file: "models")),
            client: ModelClient(connect: { _ in throw NoService() }, servicePresence: { .gone }))
    }
}
