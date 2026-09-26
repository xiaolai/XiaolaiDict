import ModelKit
import Testing
@testable import XiaolaiDictCore

/// **The pins themselves, checked mechanically.** These manifests are hand-transcribed from what
/// the mirror published: a path, a byte count and a hash per file, three sizes over. A typo in one
/// is a download that fails hours in, or — for a path — a write outside the model's own directory.
/// Nothing decodes a manifest, so this is where a bad pin is caught.
struct LocalModelCatalogPinTests {
    /// A parameterised test over an empty list passes every assertion in it, which is the vacuous
    /// green this project has been bitten by — so the list is asserted before it is walked.
    @Test func everySizeHasAPinnedManifest() {
        #expect(ModelManifest.all.count == LocalModelSize.allCases.count)
        #expect(ModelManifest.all.count >= 3)
        #expect(Set(ModelManifest.all.map(\.identifier)).count == ModelManifest.all.count)
    }

    @Test(arguments: ModelManifest.all)
    func everyPinnedFileIsNamedSafelyAndMeasured(manifest: ModelManifest) throws {
        #expect(manifest.files.count >= 2, "\(manifest.identifier) lists \(manifest.files.count) files")
        #expect(manifest.licence != nil, "\(manifest.identifier) ships no licence")
        #expect(isCommit(manifest.revision), "\(manifest.identifier) is not pinned to a commit")
        #expect(manifest.repository.split(separator: "/").count == 2, "\(manifest.repository) is not owner/name")
        var seen: Set<String> = []
        for file in manifest.files {
            #expect(!file.path.isEmpty)
            // A path is a name inside the model's own directory. `..` or a leading slash would put
            // the download somewhere else entirely, which is what makes this worth asserting.
            #expect(!file.path.hasPrefix("/"), "\(file.path) is absolute")
            #expect(!file.path.split(separator: "/").contains(".."), "\(file.path) climbs out of the model")
            #expect(file.size > 0, "\(file.path) is listed as \(file.size) bytes")
            #expect(isSHA256(file.sha256), "\(file.path) carries \(file.sha256)")
            #expect(seen.insert(file.path).inserted, "\(file.path) is listed twice")
            #expect(isCommit(file.revision), "\(file.path) is not pinned to a commit")
        }
    }

    private func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func isCommit(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
