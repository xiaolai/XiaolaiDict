import Foundation

/// Which Qwen3.5 the reader has, by the job its size does.
///
/// Three, because that is what was measured on the MacBook Pro 16 on 2026-09-22 and what a Mac can
/// be told apart by: **4B is the default** — every sense and every sentence right, 0.44 s a sense
/// answer, 3.4 GB while loaded; **2B is the floor** for a Mac that cannot hold 4B, with one English
/// leak seen in eight sentences; **9B is an opt-in** — a little more idiomatic at twice the time
/// and memory. 0.8B is not here because it is not usable: *table … until next month* became
/// "submit", the opposite.
public enum LocalModelSize: String, CaseIterable, Codable, Sendable, Comparable {
    case small
    case standard
    case large

    /// What the reader is shown: the model and its size, from the catalogue rather than typed into
    /// each branch of a view — four copies of it were four chances to name a size that is not the
    /// one downloading.
    public var displayName: String { "Qwen3.5 \(parameters)" }

    /// The parameter count, which is how the model is named everywhere else.
    public var parameters: String {
        switch self {
        case .small: "2B"
        case .standard: "4B"
        case .large: "9B"
        }
    }

    /// The **process's** peak footprint, measured on the M4 Max (the Qwen benchmark's `raw` runs):
    /// 2,098, 3,585 and 6,633 MB, all at load — the worst moment, when the weights are being mapped
    /// and MLX's buffers are not yet trimmed. It settles lower afterwards (1,395 / 2,741 / 5,282, and
    /// the E2E service measured 2,733 MB holding the 4B), but the moment that decides whether a Mac
    /// swaps is the peak, not what it relaxes to.
    ///
    /// **Not MLX's own counters** (1,886 / 3,363 / 5,806): they leave out what the OS has mapped for
    /// the process, and sizing on them offered every size about 200–800 MB more cheaply than it costs.
    /// What sizing decides against — **before** loading, because neither MLX's memory limit nor the OS
    /// pressure handler stops a model too large for the Mac (the MLX-in-XPC spike, S3).
    public var peakMemory: UInt64 {
        switch self {
        case .small: 2_098 * Self.megabyte
        case .standard: 3_585 * Self.megabyte
        case .large: 6_633 * Self.megabyte
        }
    }

    public var manifest: ModelManifest {
        switch self {
        case .small: .qwen35Small
        case .standard: .qwen35Standard
        case .large: .qwen35Large
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    static let megabyte: UInt64 = 1_048_576
}

/// One file of a model, pinned by the host's own listing: which repository, which commit, how many
/// bytes and what SHA-256. **The hash is the pin.** A file that arrives with any other is refused,
/// whatever the host says it is.
/// **Not `Codable`, on purpose.** Every manifest in this file is a compile-time constant, checked
/// against what the mirror published; nothing decodes one. The conformance was there unused, and
/// what it implied was untrue — that these values might arrive from outside, where a path of `..`
/// or a negative size would be a real risk rather than a typo a test can catch.
public struct ModelFile: Sendable, Equatable, Hashable {
    public let repository: String
    public let revision: String
    public let path: String
    public let size: Int64
    public let sha256: String

    /// **Internal**, like the manifest's: every pin in this app is a constant in this file, checked
    /// against what the mirror published and asserted by `LocalModelCatalogPinTests`. A public
    /// initialiser would say these can come from somewhere else — and the values are used as
    /// filesystem paths and byte counts, where "somewhere else" is a path that climbs out of the
    /// model's own directory.
    init(repository: String, revision: String, path: String, size: Int64, sha256: String) {
        self.repository = repository
        self.revision = revision
        self.path = path
        self.size = size
        self.sha256 = sha256
    }

    /// ModelScope's resolve endpoint, **by commit**, never by branch: a file fetched from `master`
    /// is not pinned, and "it worked yesterday" is not a property anyone can rely on. It redirects
    /// to a CDN that honours `Range`, which is what makes a download resumable — measured, 206 with
    /// the requested bytes.
    public var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "modelscope.cn"
        components.path = "/models/\(repository)/resolve/\(revision)/\(path)"
        return components.url!
    }
}

/// Everything one model needs on disk, as the host listed it at a pinned commit.
///
/// **Weights from ModelScope, never Hugging Face.** Hugging Face is unreachable from mainland China,
/// a core audience — which is the reason ModelScope was chosen, and the one thing about it not yet
/// measured *from inside* China.
public struct ModelManifest: Sendable, Equatable, Hashable {
    public let size: LocalModelSize
    /// The weights' repository and the commit they are pinned to. The directory the model lives in
    /// is named for both, so a new pin is a new directory and never an overwrite of a working one.
    public let repository: String
    public let revision: String
    public let files: [ModelFile]

    init(size: LocalModelSize, repository: String, revision: String, files: [ModelFile]) {
        self.size = size
        self.repository = repository
        self.revision = revision
        self.files = files
    }

    /// `<repository>@<revision>`, the plan's name for the model's directory.
    public var identifier: String { "\(repository)@\(revision)" }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// The licence, which comes from the **upstream** repository rather than the MLX mirror: the
    /// mirror carries none, and its README declares `license: other` — ModelScope's template, not
    /// a statement about Qwen. Apache 2.0 is what Qwen publishes.
    public var licence: ModelFile? { files.first { $0.path == Self.licenceFileName } }

    public static let licenceFileName = "LICENSE"

    /// Every manifest the app knows, largest last.
    public static let all: [ModelManifest] = LocalModelSize.allCases.map(\.manifest)
}

extension ModelManifest {
    private static let upstreamLicence = ModelFile(
        repository: "Qwen/Qwen3.5-4B", revision: "ed182e32090db791077e12e0f58d22f3daafa173",
        path: licenceFileName, size: 11_343,
        sha256: "50cbab8a892c5f2993b8c7351a99182507472def3b1374558308605d99b86b32")

    /// Listed 2026-09-22 from ModelScope's files API at each pinned commit. The model's own README,
    /// `.gitattributes` and `configuration.json` are left out: none of them is read to load it, and
    /// the README's licence line is wrong.
    private static func mirror(
        _ size: LocalModelSize, _ repository: String, _ revision: String, _ files: [(String, Int64, String)]
    ) -> ModelManifest {
        ModelManifest(
            size: size, repository: repository, revision: revision,
            files: files.map {
                ModelFile(repository: repository, revision: revision, path: $0.0, size: $0.1, sha256: $0.2)
            } + [upstreamLicence])
    }

    /// The configuration and tokenizer files every size shares, byte for byte.
    private static let sharedTokenizer: [(String, Int64, String)] = [
        ("preprocessor_config.json", 390, "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
        ("processor_config.json", 1_300, "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
        ("tokenizer.json", 19_989_343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        ("tokenizer_config.json", 1_139, "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
        ("video_preprocessor_config.json", 385, "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
        ("vocab.json", 6_722_759, "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
    ]

    static let qwen35Small = mirror(
        .small, "mlx-community/Qwen3.5-2B-4bit", "ffa48c63955c56e22d76c1b2acd9b89e26310618", [
            ("chat_template.jinja", 7_755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
            ("config.json", 3_113, "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949"),
            ("model.safetensors", 1_722_271_785, "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"),
            ("model.safetensors.index.json", 81_722, "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d"),
        ] + sharedTokenizer)

    static let qwen35Standard = mirror(
        .standard, "mlx-community/Qwen3.5-4B-4bit", "ab9c7a42fd31095a40634b3362317779dee9e7fa", [
            ("chat_template.jinja", 7_756, "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
            ("config.json", 3_366, "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
            ("model.safetensors", 3_034_300_695, "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
            ("model.safetensors.index.json", 101_944, "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
        ] + sharedTokenizer)

    static let qwen35Large = mirror(
        .large, "mlx-community/Qwen3.5-9B-4bit", "27ab860cfc825df921f0ac1453133f3fa963a7f2", [
            ("chat_template.jinja", 7_756, "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
            ("config.json", 3_331, "a96942cb6a8a1d3f1d17514d81a1925d04362a6a3233b389d13012211baaa9f8"),
            ("model-00001-of-00002.safetensors", 5_349_771_222, "a68b87558c6ef43f74c2bd63ce7e9092ceddc3101f3def0030774bae5f42aadd"),
            ("model-00002-of-00002.safetensors", 600_449_850, "b0a770bf8469c7f3f18756a0e0283f1c1174344a83e059a4e483f6af4907352d"),
            ("model.safetensors.index.json", 123_592, "dd023913fb87cfdae27fb11dcf695117c925833796ccac3c64117d6652d8ff1e"),
        ] + sharedTokenizer)
}
