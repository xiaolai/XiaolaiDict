// swift-tools-version: 6.2
import PackageDescription

// XiaolaiDict — a menu-bar dictionary for macOS. Design: dev-docs/macos-intelligent-dictionary.md.
// `swift test` runs the tests; `make` assembles, signs and embeds everything into XiaolaiDict.app.
let package = Package(
    name: "XiaolaiDict",
    platforms: [.macOS("27.0")],
    dependencies: [
        // `MLXFoundationModels` — `MLXLanguageModel` behind `LanguageModelSession` — is on `main`
        // only; no tagged release carries it yet. Pinned by commit, and to the commit the Qwen
        // measurements were taken with, never to a branch.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "c6446cf7bfb7cea76408013b614d4b2c530eaa03"),
        // The model service evaluates an MLX op itself, so it names MLX rather than reaching it
        // through mlx-swift-lm. Exact, at the version that revision resolved and was measured with.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        // mlx-swift-lm ships no tokenizer: its loader macro expands into code that imports this.
        // Exact, because it is the version the measurements ran against.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        // Entry models, the lookup ledger, lemmas. No AppKit and no private API — the part that
        // has to be exhaustively testable. Not portable, and not meant to be: it binds
        // CoreGraphics, NaturalLanguage, CryptoKit, CoreServices and FoundationModels.
        .target(name: "XiaolaiDictCore"),

        // The private DictionaryServices API. Linked only by the XPC service and its tests, never
        // by the app: its failure mode is a segfault, and a crash must take down the service, not
        // the app the reader is using (design note §10).
        .target(name: "DictionaryBridge", dependencies: ["XiaolaiDictCore"]),

        .executableTarget(name: "XiaolaiDictService", dependencies: ["XiaolaiDictCore", "DictionaryBridge"]),

        // What the model service does with a request — the prompts, the session, what a refusal
        // becomes — written against any `LanguageModel`, so its tests run on an injected executor
        // and need no GPU. No MLX here: that is the executable's alone.
        .target(name: "LocalModel", dependencies: ["XiaolaiDictCore"]),
        // The local model, behind its own XPC boundary. A GPU fault or an out-of-memory kill takes
        // this process and not the app, and unloading is ending it — which is exact, where MLX's
        // own release is not. Never linked by the app: the app talks to it in typed messages, the
        // way it talks to the dictionary service.
        .executableTarget(
            name: "XiaolaiDictModelService",
            dependencies: [
                "XiaolaiDictCore", "LocalModel",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]),
        // The view layer as its own library, not because the app needs the boundary but because
        // Xcode cannot preview an executable target: "Previewing in executable targets now
        // requires a new build layout… or break out your preview code into a separate framework."
        // Nothing here knows about windows, XPC or the ledger.
        .target(name: "XiaolaiDictUI", dependencies: ["XiaolaiDictCore"]),
        .executableTarget(name: "XiaolaiDict", dependencies: ["XiaolaiDictCore", "XiaolaiDictUI"]),

        // What the test targets share, and nothing ships: a defaults suite a test can make and
        // forget, because it is removed — file and all — when the test process ends.
        .target(name: "XiaolaiDictTestSupport", path: "Tests/Support"),
        .testTarget(name: "XiaolaiDictCoreTests", dependencies: ["XiaolaiDictCore", "XiaolaiDictTestSupport"]),
        .testTarget(name: "XiaolaiDictTests", dependencies: ["XiaolaiDict", "XiaolaiDictUI", "XiaolaiDictTestSupport"]),
        // Integration tests against the dictionaries actually installed on this Mac.
        .testTarget(name: "DictionaryBridgeTests", dependencies: ["DictionaryBridge"]),
        .testTarget(name: "LocalModelTests", dependencies: ["LocalModel", "XiaolaiDictCore", "XiaolaiDictTestSupport"]),
    ]
)
