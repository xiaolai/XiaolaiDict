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

        .testTarget(name: "XiaolaiDictCoreTests", dependencies: ["XiaolaiDictCore"]),
    ]
)
