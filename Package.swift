// swift-tools-version: 6.2
import PackageDescription

// XiaolaiDict — a menu-bar dictionary for macOS. Design: dev-docs/macos-intelligent-dictionary.md.
// `swift test` runs the tests.
let package = Package(
    name: "XiaolaiDict",
    platforms: [.macOS(.v26)],
    targets: [
        // Entry models, the lookup ledger, lemmas. Pure Swift: no AppKit and no private API —
        // the part that has to be exhaustively testable.
        .target(name: "XiaolaiDictCore"),

        // The private DictionaryServices API. Linked only by the XPC service and its tests, never
        // by the app: its failure mode is a segfault, and a crash must take down the service, not
        // the app the reader is using (design note §10).
        .target(name: "DictionaryBridge", dependencies: ["XiaolaiDictCore"]),

        .executableTarget(name: "XiaolaiDictService", dependencies: ["XiaolaiDictCore", "DictionaryBridge"]),

        .testTarget(name: "XiaolaiDictCoreTests", dependencies: ["XiaolaiDictCore"]),
        // Integration tests against the dictionaries actually installed on this Mac.
        .testTarget(name: "DictionaryBridgeTests", dependencies: ["DictionaryBridge"]),
    ]
)
