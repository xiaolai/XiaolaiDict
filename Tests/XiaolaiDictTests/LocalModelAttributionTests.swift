import ModelKit
import Testing
@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// **What About says about the model is tied to what the app actually downloads.** The attribution
/// is three strings in the view layer and the pins are in the catalogue; nothing but this connects
/// them, so a new model pinned without changing About would go on naming the old one's publisher
/// and licence — which is the one place in the app where being wrong is a legal matter.
struct LocalModelAttributionTests {
    @Test func theFamilyNamedIsTheFamilyPinned() {
        #expect(!ModelManifest.all.isEmpty)
        for manifest in ModelManifest.all {
            #expect(manifest.repository.contains(LocalModelAttribution.family),
                    "About names \(LocalModelAttribution.family) and \(manifest.repository) is pinned")
        }
    }

    /// The licence that comes with the weights is the one About links to when it is there, and the
    /// published copy otherwise — so both must be about the same licence.
    @Test func theLicenceIsTheOneShippedWithTheWeights() throws {
        #expect(LocalModelAttribution.licenceURL != nil)
        for manifest in ModelManifest.all {
            let licence = try #require(manifest.licence, "\(manifest.identifier) ships no licence")
            #expect(licence.path == ModelManifest.licenceFileName)
            // Pinned from the upstream repository, which is the family's own — the MLX mirror
            // publishes none.
            #expect(licence.repository.contains(LocalModelAttribution.family))
        }
    }
}
