// swift-tools-version: 6.2
import PackageDescription

// XiaolaiDict — a menu-bar dictionary for macOS. Design: dev-docs/macos-intelligent-dictionary.md.
// `swift test` runs the tests; `make` assembles, signs and embeds everything into XiaolaiDict.app.
let package = Package(
    name: "XiaolaiDict",
    platforms: [.macOS(.v26)],
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
        // The view layer as its own library, not because the app needs the boundary but because
        // Xcode cannot preview an executable target: "Previewing in executable targets now
        // requires a new build layout… or break out your preview code into a separate framework."
        // Nothing here knows about windows, XPC or the ledger.
        .target(name: "XiaolaiDictUI", dependencies: ["XiaolaiDictCore"]),
        .executableTarget(name: "XiaolaiDict", dependencies: ["XiaolaiDictCore", "XiaolaiDictUI"]),

        .testTarget(name: "XiaolaiDictCoreTests", dependencies: ["XiaolaiDictCore"]),
        .testTarget(name: "XiaolaiDictTests", dependencies: ["XiaolaiDict", "XiaolaiDictUI"]),
        // Integration tests against the dictionaries actually installed on this Mac.
        .testTarget(name: "DictionaryBridgeTests", dependencies: ["DictionaryBridge"]),
    ]
)
