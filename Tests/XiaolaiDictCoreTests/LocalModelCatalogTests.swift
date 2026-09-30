@testable import ModelKit
import Testing
@testable import XiaolaiDictCore

/// **The pins themselves, checked mechanically.** These manifests are hand-transcribed from what
/// the mirror published: a path, a byte count and a hash per file, for each size the catalogue
/// carries. A typo in one is a download that fails hours in, or — for a path — a write outside the
/// model's own directory. Nothing decodes a manifest, so this is where a bad pin is caught.
struct LocalModelCatalogPinTests {
    /// A parameterised test over an empty list passes every assertion in it, which is the vacuous
    /// green this project has been bitten by — so the list is asserted before it is walked.
    ///
    /// **The floor is 2, lowered from 3 on 2026-09-26 when 2B was removed from the catalogue.** It
    /// is not `LocalModelSize.allCases.count` twice over: the line above already ties the two
    /// together, and this one has to be a number so that *both* going to zero is caught.
    @Test func everySizeHasAPinnedManifest() {
        #expect(ModelManifest.all.count == LocalModelSize.allCases.count)
        #expect(ModelManifest.all.count >= 2)
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

/// **Where each file is fetched from, for every host, spelled out.** A host is a property of the
/// transfer and never of a model's identity; these hold that line from the other side, by
/// asserting the complete URL a reader's Mac would actually ask for.
struct ModelHostTests {
    /// Every `(manifest, host, file)` combination, so a mapping cannot be added without a URL
    /// somebody has read.
    @Test func everyFileResolvesToAcommitOnEveryHostThatServesIt() {
        for manifest in ModelManifest.all {
            for host in ModelHost.allCases {
                for file in manifest.files {
                    let url = file.url(from: host)
                    let text = url.absoluteString
                    #expect(url.scheme == "https", "\(text)")
                    // **A commit, never a branch.** `main` or `master` would mean the bytes can
                    // change under a pin that says they cannot.
                    #expect(text.contains("/resolve/"), "\(text)")
                    let revision = text.components(separatedBy: "/resolve/")[1]
                        .components(separatedBy: "/")[0]
                    #expect(revision.count == 40 && revision.allSatisfy(\.isHexDigit),
                            "\(file.path) on \(host) resolves through '\(revision)', not a commit")
                    #expect(text.hasSuffix("/" + file.path), "\(text)")
                }
            }
        }
    }

    /// The two hosts spell a resolve URL differently, and the commit differs for identical bytes.
    @Test func thetwoHostsSpellTheSameFileTheirOwnWay() throws {
        let large = LocalModelSize.large.manifest
        let weights = try #require(large.files.first { $0.path == "model-00001-of-00002.safetensors" })
        #expect(weights.url(from: .modelScope).absoluteString ==
                "https://modelscope.cn/models/mlx-community/Qwen3.5-9B-4bit/resolve/27ab860cfc825df921f0ac1453133f3fa963a7f2/model-00001-of-00002.safetensors")
        #expect(weights.url(from: .huggingFace).absoluteString ==
                "https://huggingface.co/mlx-community/Qwen3.5-9B-4bit/resolve/8b2b98c00a6b4d291155e4890773ca8f769aee53/model-00001-of-00002.safetensors")
        #expect(weights.url == weights.url(from: .modelScope), "the canonical URL moved host")
    }

    /// **The licence is ModelScope's, whatever host was chosen.** Hugging Face serves 11,544
    /// bytes where the pin says 11,343, and no commit of theirs has the pinned bytes — so asking
    /// them for it would fail the hash after the weights had already arrived.
    @Test func thelicenceIsFetchedFromTheHostItWasPinnedAgainst() throws {
        for manifest in ModelManifest.all {
            let licence = try #require(manifest.files.first { $0.path == "LICENSE" })
            #expect(!licence.isServed(by: .huggingFace))
            #expect(licence.url(from: .huggingFace).host() == "modelscope.cn",
                    "the licence was asked of a host that does not have these bytes")
            #expect(licence.size == 11_343)
        }
    }

    /// And every other file **is** served by both, or choosing a host would quietly do nothing.
    @Test func everyFileButTheLicenceIsServedByBothHosts() {
        for manifest in ModelManifest.all {
            for file in manifest.files where file.path != "LICENSE" {
                #expect(file.isServed(by: .huggingFace), "\(file.path) has no Hugging Face source")
                #expect(file.url(from: .huggingFace).host() == "huggingface.co", "\(file.path)")
            }
        }
    }

    /// **A model's identity does not know what a host is.** The directory it installs into and
    /// the marker that says it is whole are built from the canonical pin alone.
    @Test func ahostIsNotPartOfAmodelsIdentity() {
        for manifest in ModelManifest.all {
            #expect(manifest.identifier == "\(manifest.repository)@\(manifest.revision)")
            #expect(!manifest.identifier.contains("huggingface"))
            #expect(!ModelStore.markerText(for: manifest).contains("huggingface"))
        }
    }
}
