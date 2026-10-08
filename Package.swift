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
        // **No domain vocabulary at all**, which is the whole of its remit: an identity, a deadline,
        // a watchdog, a non-empty collection, and the first of two answers (`FirstAnswer`, which the
        // capture readers and the lookup runner both wait on, since 2026-10-08). The app and both
        // services link it, so anything that would need explaining in terms of dictionaries, models or
        // readers belongs somewhere else. Foundation, Dispatch and Synchronization, and nothing further.
        .target(name: "XiaolaiDictBase"),

        // The dictionary itself: entries, senses, entry documents, lemmas, and the dictionary
        // service's wire protocol. Foundation and NaturalLanguage — plus CryptoKit, because a sense
        // a publisher gave no id is keyed by a hash of its own text (`DictionarySense.hash`), which
        // is on the XPC service's execution path and so cannot be moved out of it.
        .target(name: "DictionaryModel", dependencies: ["XiaolaiDictBase"]),

        // Apple's `.dictionary` container, and the facts that differ between the 86 of them.
        // **Depends on nothing** — not even XiaolaiDictBase — because it is a file format plus a
        // table of measured facts: testable without the app, and reusable without it. Foundation
        // and CryptoKit only. Reads `Body.data` and `KeyText.data` directly, because Dictionary
        // Services exposes no way to enumerate a dictionary's keys.
        // The three Markdown files are the module's own record — the feature ledger, the audit and
        // how every figure was measured. Excluded because SwiftPM would otherwise warn them as
        // unhandled resources; a fourth document has to be added here too, and will warn until it is.
        .target(name: "AppleDictionaryFormat", exclude: ["FEATURE-LEDGER.md", "AUDIT.md", "RESEARCH.md", "DICTIONARIES.md", "PLAN.md"]),

        // **The index, apart from the format it is built from — because of what links what.** The dictionary
        // service reads the phrase inventory, which needs the container reader; it has no use for the index,
        // and `verify_service_boundaries` forbids it `libsqlite3`. With the store inside
        // `AppleDictionaryFormat` the service linked SQLite transitively for code it never calls, and the
        // release refused to ship — correctly. Only `IndexStore` and `IndexRebuilder` ever touched SQLite,
        // and nothing in the format module referenced them outside a comment.
        .target(name: "DictionaryIndex", dependencies: ["AppleDictionaryFormat"]),

        // Everything about the local model that is not running it: the model service's wire
        // protocol, the prompts and the answer schema, the catalogue, what this Mac can hold, and
        // the store the weights are downloaded into. Linked by the model service and by the app;
        // **never by the dictionary service**, which is the point of it being here and not in the
        // core. No MLX — that is the executable's alone.
        .target(name: "ModelKit"),

        // The review logic a phone, a watch or a TV could run as it is: the scheduler, a sitting, the
        // study day, the queue's counts. **Foundation only, depends on nothing, no conditional
        // compilation**, and typechecked for iOS, watchOS, tvOS and macOS by `make portability`. The
        // ledger, every SQL predicate and anything holding an answer's text are `StudyKit`'s.
        // **One line, and nothing on it but the name**: `ModuleBoundaryTests.reviewKitDependsOnNothing`
        // reads this declaration exactly, because a stale module satisfies the compiler and the scan
        // is what holds the boundary (ADR-0047).
        .target(name: "ReviewKit"),

        // How a word was captured and where it was read: the two values the study ledger and the capture
        // policy both speak and neither owns (`CaptureQuality`, `ReadingPlace`). **Depends on nothing**, and
        // binds Foundation alone — `ReadingPlace` percent-decodes a file name.
        .target(name: "CaptureModel"),

        // The study side: the lookup ledger and its schema, reading history, study notes and cards, the
        // library's queries, the export, the recovery and the replay of a card's history. Foundation, SQLite3
        // and os; the review logic it stores is `ReviewKit`'s, the values it records are `DictionaryModel`'s
        // and `CaptureModel`'s. No sense ladder, no capture policy and no model: a client that reviews can
        // link this without either.
        .target(name: "StudyKit", dependencies: ["XiaolaiDictBase", "DictionaryModel", "ReviewKit", "CaptureModel"]),

        // The capture policy, as values and arithmetic: hover and its gesture, the screen's geometry, the
        // drawer's frame, the recognised text and the sentence cut from it, which places are excluded.
        // No Accessibility, no AppKit and no private API — the part of capture that has to be exhaustively
        // testable without a window server, and the part a capture adapter on another platform would match.
        // Foundation, CoreGraphics (its value types, never a window server) and os.
        .target(name: "Capture", dependencies: ["XiaolaiDictBase", "DictionaryModel", "CaptureModel"]),

        // What is left of the reader's side once the study ledger and the capture policy have their own
        // targets (2026-10-08): the sense ladder, its selectors and the labelled cases it is measured against,
        // the sentence pane and its translation, the sense mark and which sense the reader tapped in each entry
        // (`PanelSelection`, beside the mark it holds), the lookup's outcome and timeline, the public
        // dictionary's fallback, the setup board's presentation and the lookup shortcut — 14 files. Kept by its
        // name rather than renamed for what is left (ADR-0052). No AppKit, no private API and no display text.
        // Not portable, and not meant to be: it binds NaturalLanguage, CoreServices, FoundationModels and
        // Carbon's key codes.
        .target(name: "XiaolaiDictCore", dependencies: ["XiaolaiDictBase", "DictionaryModel", "ModelKit", "CaptureModel"]),

        // What the study surfaces draw, as values, apart from the SwiftUI files that used to declare them
        // (2026-10-08): the Library's, Review's and the erase's presentations and actions, a lookup's keep and
        // save status, the study and dictionary choices Settings is handed. **A presentation target**: reader-facing
        // text is allowed here and read by the view layer's prose rule, and no UI framework and no view layer is —
        // a symbol a surface draws with stays with `ActionSymbol`, in the view layer. Foundation alone.
        .target(name: "StudyPresentation", dependencies: ["DictionaryModel", "ReviewKit", "StudyKit"]),

        // The study surfaces' models, apart from the app that composes them (2026-10-08): the Library's, Review's
        // and the erase's models, the lookup recorder and the ledger's actor, the study dictionary and the reader's
        // study options. **A presentation target**, as `StudyPresentation` is: reader-facing text is allowed, and no
        // UI framework and no view layer is — the scenes that draw these models, and what Review's Done closes and
        // Explore opens, are the app's and are handed in. Foundation, Observation and os.
        .target(name: "StudyModels", dependencies: ["XiaolaiDictBase", "DictionaryModel", "ReviewKit", "CaptureModel", "StudyKit", "StudyPresentation", "XiaolaiDictCore"]),

        // The Apple capture readers, apart from the app that composes them (2026-10-08): Accessibility and its one lane,
        // the selection reader, the word under the pointer in three dialects, the screen capture and Vision's reading of
        // it, hover's watcher and reader, and the two permissions they ask through. **A platform adapter**: AppKit is
        // allowed here, no other UI framework is, and neither is display text, conditional compilation or any subject
        // it does not adapt — the refusals are typed and worded by the view layer, and the instruments that read the
        // screen on demand stay in the app behind their define. Its counterpart on another platform matches
        // `Capture`'s policy, which this drives.
        .target(name: "MacCapture", dependencies: ["XiaolaiDictBase", "DictionaryModel", "CaptureModel", "Capture"]),

        // The private DictionaryServices API. Linked only by the XPC service and its tests, never
        // by the app: its failure mode is a segfault, and a crash must take down the service, not
        // the app the reader is using (design note §10).
        .target(name: "DictionaryBridge", dependencies: ["XiaolaiDictBase", "DictionaryModel"]),

        .target(name: "PhraseLookup", dependencies: ["DictionaryModel", "AppleDictionaryFormat"]),

        .executableTarget(
            name: "XiaolaiDictService",
            dependencies: ["XiaolaiDictBase", "DictionaryModel", "DictionaryBridge", "PhraseLookup"]),

        // What the model service does with a request — the prompts, the session, what a refusal
        // becomes — written against any `LanguageModel`, so its tests run on an injected executor
        // and need no GPU. No MLX here: that is the executable's alone.
        .target(name: "LocalModel", dependencies: ["ModelKit"]),
        // The language model as a service the reader already has (ADR-0053): an OpenAI-compatible endpoint now, the
        // reader's own `claude` and `codex` next, the API key in the Keychain. **The app's alone, never a service's**:
        // the Keychain item is the app's, and a CLI child must live and die with the app. Below the view layer, so no
        // display text — a provider fails in types, and the view layer words them. Foundation, Security and os; the
        // prompts, the wire types and what may leave the Mac come from ModelKit, the app's identifier from Base.
        .target(name: "LLMProviders", dependencies: ["XiaolaiDictBase", "ModelKit"]),
        // The local model, behind its own XPC boundary. A GPU fault or an out-of-memory kill takes
        // this process and not the app, and unloading is ending it — which is exact, where MLX's
        // own release is not. Never linked by the app: the app talks to it in typed messages, the
        // way it talks to the dictionary service.
        .executableTarget(
            name: "XiaolaiDictModelService",
            dependencies: [
                "XiaolaiDictBase", "ModelKit", "LocalModel",
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
        .target(name: "XiaolaiDictUI", dependencies: ["XiaolaiDictBase", "DictionaryModel", "ModelKit", "ReviewKit", "CaptureModel", "StudyKit", "StudyPresentation", "Capture", "MacCapture", "XiaolaiDictCore"]),
        .executableTarget(name: "XiaolaiDict", dependencies: ["XiaolaiDictBase", "DictionaryModel", "ModelKit", "ReviewKit", "CaptureModel", "StudyKit", "StudyPresentation", "StudyModels", "Capture", "MacCapture", "XiaolaiDictCore", "XiaolaiDictUI", "LLMProviders"]),

        // The index builder, as a command. The module it drives has no other entry point: everything in
        // `AppleDictionaryFormat` was reachable only from its own tests until this existed, which is a
        // capability nobody can run. Links the module and Foundation, and nothing else — it prints to
        // stdout and draws nothing.
        .executableTarget(name: "XiaolaiDictIndex", dependencies: ["AppleDictionaryFormat", "DictionaryIndex"]),

        // The aligner, as a command, for the reason the index builder is one: the alignment is derived from
        // licensed dictionaries and is built on the reader's own Mac, so somebody has to be able to run it
        // and read how much of it the matcher was willing to claim.
        .executableTarget(name: "XiaolaiDictAlign", dependencies: ["AppleDictionaryFormat", "DictionaryIndex"]),

        // What the test targets share, and nothing ships: a defaults suite a test can make and
        // forget, because it is removed — file and all — when the test process ends.
        .target(name: "XiaolaiDictTestSupport", path: "Tests/Support"),
        // Gated on XIAOLAIDICT_BUNDLES: the measurements run against real installed
        // dictionaries, whose text is licensed and never vendored into the repository.
        .testTarget(name: "AppleDictionaryFormatTests",
                    dependencies: ["AppleDictionaryFormat", "DictionaryIndex", "XiaolaiDictTestSupport"]),
        .testTarget(
            name: "PhraseLookupTests",
            dependencies: ["DictionaryModel", "AppleDictionaryFormat", "PhraseLookup", "XiaolaiDictTestSupport"]),
        .testTarget(name: "XiaolaiDictCoreTests", dependencies: ["XiaolaiDictBase", "DictionaryModel", "ModelKit", "CaptureModel", "XiaolaiDictCore", "XiaolaiDictTestSupport"]),
        // The study side's own tests, moved out of `XiaolaiDictCoreTests` with the code they test: the ledger and
        // its schema, the library's queries, notes, cards, the export, the recovery and the replay.
        .testTarget(name: "StudyKitTests",
                    dependencies: ["DictionaryModel", "ReviewKit", "CaptureModel", "StudyKit", "XiaolaiDictTestSupport"]),
        // The capture policy's own tests, moved out of `XiaolaiDictCoreTests` with the code they test: hover and
        // its gesture, the screen's geometry, the drawer's frame, the recognised text and its sentence.
        .testTarget(name: "CaptureTests",
                    dependencies: ["DictionaryModel", "CaptureModel", "Capture", "XiaolaiDictTestSupport"]),
        // The study models' own tests, moved out of `XiaolaiDictTests` with the code they test: the ledger's actor, the
        // lookup recorder, the primary dictionary and its resolver, the sense-tap queue, the study dictionary. A test
        // that also drives the app, a view or the window tests' shared fixture stays there, as an integration test.
        .testTarget(name: "StudyModelsTests",
                    dependencies: ["DictionaryModel", "CaptureModel", "StudyKit", "StudyPresentation", "XiaolaiDictCore", "StudyModels", "XiaolaiDictTestSupport"]),
        // The capture readers' own tests, moved out of `XiaolaiDictTests` with the code they test: Accessibility's owner,
        // the selection reader against a scripted tree, the term, window and sentence it reads, the recogniser's band and
        // tiles, and the watcher's pure helpers. A test that also drives the app, or shares hover's fakes with one that
        // does, stays there, as an integration test.
        .testTarget(name: "MacCaptureTests", dependencies: ["DictionaryModel", "CaptureModel", "Capture", "MacCapture"]),
        .testTarget(name: "XiaolaiDictTests", dependencies: ["XiaolaiDictBase", "DictionaryModel", "ModelKit", "ReviewKit", "CaptureModel", "StudyKit", "StudyPresentation", "StudyModels", "Capture", "MacCapture", "XiaolaiDictCore", "XiaolaiDict", "XiaolaiDictUI", "XiaolaiDictTestSupport"]),
        // Integration tests against the dictionaries actually installed on this Mac.
        // `AppleDictionaryFormat` here is the one place the two sense paths can be compared: the private
        // API on one side, the container reader on the other. No *product* target links both.
        .testTarget(
            name: "DictionaryBridgeTests",
            dependencies: ["DictionaryModel", "ModelKit", "CaptureModel", "XiaolaiDictCore",
                           "DictionaryBridge", "AppleDictionaryFormat", "PhraseLookup"]),
        .testTarget(name: "LocalModelTests", dependencies: ["ModelKit", "LocalModel", "XiaolaiDictTestSupport"]),
        // The providers against a URLProtocol stub and a loopback HTTP server of their own, in this process: no test
        // here reaches a network endpoint, and only one touches the real Keychain, under a service name of its own.
        // The CLI providers against fake CLIs — small scripts written into a `TemporaryDirectory` — never the reader's.
        .testTarget(name: "LLMProvidersTests", dependencies: ["ModelKit", "LLMProviders", "XiaolaiDictTestSupport"]),
        // ReviewKit alone, and no fixture target: what passes here passes without the Mac's modules.
        .testTarget(name: "ReviewKitTests", dependencies: ["ReviewKit"]),
    ]
)

// **A warning is an error in every target of this package, and only this package.** Set here, after
// the list, so a target added later is covered without anyone remembering to. Not
// `-Xswiftc -warnings-as-errors`: that reaches the MLX dependencies too, whose warnings are not ours.
//
// **And a file imports every module whose members it uses** (`MemberImportVisibility`, 2026-10-08). Without it
// a member is visible through any other file's import, so a missing import compiled with no diagnostic at all —
// 26 of them had collected — and removing an import in use compiled too. With it, both are a compile error naming
// the module. `ModuleBoundaryTests` holds every target to both settings — ADR-0052.
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error), .enableUpcomingFeature("MemberImportVisibility")]
}
