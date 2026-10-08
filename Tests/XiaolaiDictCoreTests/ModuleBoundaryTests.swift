import Foundation
import Testing
import XiaolaiDictTestSupport

/// **The boundary the module split bought, asserted rather than described.**
///
/// `AGENTS.md` has said "`XiaolaiDictCore` carries no AppKit and no private API" since the project
/// began, and until this file nothing checked it. `XiaolaiDictCore` declares no target dependencies
/// that would stop `import AppKit`, so it was true only because nobody had typed it — in a
/// repository where `NoMagicValuesTests` rejects every numeric literal in a directory and
/// `everySuiteNameComesFromTemporaryDefaults` bans a spelling. The largest invariant in the file was
/// the one enforced by nothing.
///
/// It also records what each target *is allowed* to bind. That half is not defensive tidying: it is
/// how `Carbon.HIToolbox`, `Darwin`, `Dispatch`, `os` and `Synchronization` came to be in the core
/// without appearing in the sentence in `AGENTS.md` that lists what the core binds. A framework
/// arriving in a target below the view layer is now a line in a diff.
struct ModuleBoundaryTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every library target below the view layer, and the system modules it may bind.
    ///
    /// **Exact sets, not floors.** A floor would let a framework in silently, which is the whole
    /// thing being prevented; an exact set makes adding one a decision. Each target's own siblings
    /// (this package's modules) are checked separately against `Package.swift` below, so they are not
    /// listed here.
    static let allowed: [String: Set<String>] = [
        // No domain vocabulary, and so almost no framework. If this set grows, the target has
        // stopped being what it is for.
        "XiaolaiDictBase": ["Dispatch", "Synchronization"],
        // CryptoKit is here because `DictionarySense.hash` keys a sense the publisher gave no id by
        // a SHA-256 of its own text, and `DictionaryBridge` builds those values — so it is on the
        // dictionary service's own execution path and cannot be moved out of it.
        // Synchronization is `FormAuthority`: the form table is read by every lemma and replaced when the
        // dictionary service finishes a build or the app finds a newer file, so it is one lock-guarded value.
        // A decision, not a drift — ADR-0051.
        "DictionaryModel": ["Foundation", "NaturalLanguage", "CryptoKit", "Synchronization"],
        // FoundationModels for `@Generable` and the refusal it reports; CryptoKit for the weights'
        // per-file hashes; NaturalLanguage for `TranslationCheck`. **No MLX** — that is the model
        // service executable's alone, and this target exists so the app can talk about a model it
        // never links.
        "ModelKit": ["Foundation", "FoundationModels", "CryptoKit", "NaturalLanguage", "Darwin"],
        // The reader's side. `Carbon.HIToolbox` is virtual key codes for `Shortcut`, never
        // registration — that is `Hotkey`, in the app. **No SQLite3 since the ledger left for `StudyKit`, and no
        // CoreGraphics since the capture policy left for `Capture`** (2026-10-08): nothing that remains opens a
        // database or measures a screen.
        "XiaolaiDictCore": [
            "Foundation", "NaturalLanguage", "CoreServices",
            "FoundationModels", "Carbon.HIToolbox", "os",
        ],
        // The study side: the ledger and its schema (SQLite3), reading history, notes and cards, the library's
        // queries, the export and the recovery. `os` is the ledger's log. No CoreGraphics, no NaturalLanguage:
        // a lemma it stores is computed by `DictionaryModel`, never here.
        "StudyKit": ["Foundation", "SQLite3", "os"],
        // The capture policy as values and arithmetic: CoreGraphics for `CGRect` and `CGPoint`, never a window
        // server; `os` is hover's log. Accessibility, ScreenCaptureKit and Vision are `MacCapture`'s, the platform
        // adapter below (corrected 2026-10-08, P5: this said "the app's").
        "Capture": ["Foundation", "CoreGraphics", "os"],
        // What the model service *does* with a request, written against any `LanguageModel` so its
        // tests need no GPU.
        "LocalModel": ["Foundation", "FoundationModels", "Synchronization"],
        // The private DictionaryServices API, reached by `dlopen` rather than by linking it.
        "DictionaryBridge": ["Foundation", "Synchronization"],
        // Apple's `.dictionary` container, and the facts that differ between the 86 of them. It
        // depends on no sibling target at all — not even `XiaolaiDictBase` — because it is a file
        // format plus a table of measured facts, testable and reusable without the app. `Compression`
        // decodes the body's zlib chunks, `CryptoKit` hashes a sense the publisher gave no id, and
        // `SQLite3` is the index it writes; `libsqlite3` ships with macOS, so none of this is a
        // dependency in the manifest sense.
        //
        // **Absent until 2026-09-27, and the two tests below were right to say so.** The target was
        // added to `Package.swift` without being registered here, so `everyLibraryTargetIsEitherChecked…`
        // failed and — more to the point — `nothingBelowTheViewLayerBindsAppKitOrSwiftUI` was not
        // checking it at all.
        //
        // **`SQLite3` moved out with the index, and that was forced rather than chosen.** The dictionary
        // service reads the phrase inventory, so it links this module — and `verify_service_boundaries`
        // forbids that service `libsqlite3`. With the store in here the service linked SQLite transitively
        // for code it never calls, and the release refused to ship. The format reader and the index it feeds
        // are separate concerns; the link graph is what made that concrete.
        "AppleDictionaryFormat": ["Foundation", "Compression", "CryptoKit"],
        // The index the format module feeds: the only thing here that touches SQLite.
        "DictionaryIndex": ["Foundation", "SQLite3"],
        // The adapter between the dictionary-format reader and the wire protocol: a sentence in, a span
        // out. `Synchronization` holds the inventory, which is read on one queue and asked from another.
        // No `os` — it reports through a closure, so the caller owns the logging and this target stays
        // testable without one.
        "PhraseLookup": ["Foundation", "Synchronization"],
        // The index builder, as a command. Listed here rather than excluded with the two XPC services,
        // because a command-line tool has no more business binding AppKit than a library does — and being
        // in this table is what applies that rule to it.
        "XiaolaiDictIndex": ["Foundation"],
        "XiaolaiDictAlign": ["Foundation"],
        // The review logic a phone, a watch or a TV could run: the scheduler, the session, the study
        // day. **Foundation and nothing else, and no sibling either** — `reviewKitDependsOnNothing`
        // holds the second half, because this table filters siblings out (ADR-0047).
        "ReviewKit": ["Foundation"],
        // How a word was captured and where it was read — `CaptureQuality` and `ReadingPlace`, the two values
        // the study ledger and the capture policy share. Foundation for `ReadingPlace`'s percent-decoding and
        // `range(of:)`: without it the module does not compile, measured — it had compiled in the core only
        // because its siblings imported Foundation.
        "CaptureModel": ["Foundation"],
    ]

    /// **The presentation layer: pure values a surface draws, and a class of its own** (2026-10-08,
    /// plan-macos-modularisation §3, P4a) — the Library's, Review's and the erase's presentations and actions, a
    /// lookup's keep and save status, the study and dictionary choices Settings is handed — **and the observable
    /// models that drive them** (P4b): the Library's, Review's and the erase's models, the lookup recorder, the
    /// study dictionary and options, and the ledger's actor.
    ///
    /// Neither of the other two classes. **Reader-facing text is allowed here**, which below the view layer it is
    /// not: `StringCatalogTests` reads these targets with the view layer's prose rule instead. **No UI framework and
    /// no view layer is**, which in the view layer would be: a value that imported `XiaolaiDictUI` would be the view
    /// layer's again, and nothing but this app's surface could draw it. Exact sets, as below the view layer.
    static let presentation: [String: Set<String>] = [
        // Foundation alone: `LocalizedStringResource` is Foundation's, and nothing here draws, logs or observes.
        "StudyPresentation": ["Foundation"],
        // Observation for `@Observable`, which is what a surface on any Apple platform watches; `os` is the
        // recorder's and the options' log. The scenes that draw these models are the app's, never this target's.
        "StudyModels": ["Foundation", "Observation", "os"],
    ]

    /// **The platform adapter: the part of a subject that touches the platform, and a class of its own** (2026-10-08,
    /// plan-macos-modularisation §3, P5) — the Apple capture readers: Accessibility and its lane, the screen capture
    /// and Vision's reading of it, the AppKit events hover watches, and the two permission probes they ask through.
    ///
    /// Neither of the other two classes. **AppKit is allowed here**, which below the view layer it is not: an adapter
    /// is where `NSEvent`, `NSWorkspace` and `NSScreen` are spoken. **No other UI framework, no display text and no
    /// conditional compilation**, and **none of the subjects it does not adapt** — the study side, the model, the sense
    /// ladder, the presentation layer and the view layer. An adapter that bound one would be the app again, and a
    /// counterpart on another platform would have nothing named to match. Exact sets, as below the view layer; the words
    /// a refusal is shown in are the view layer's, and `StringCatalogTests` refuses display text here as below it.
    static let platformAdapters: [String: Set<String>] = [
        // AppKit for hover's event monitors, the running apps and the screens; ApplicationServices for Accessibility;
        // ScreenCaptureKit and Vision for the capture path; CoreGraphics for the window list and Screen Recording's
        // request; CoreFoundation for the ranges Accessibility answers in; Synchronization for the lane, the guard and
        // the memo; `os` is the readers' log.
        "MacCapture": [
            "AppKit", "ApplicationServices", "CoreFoundation", "CoreGraphics", "Foundation",
            "ScreenCaptureKit", "Synchronization", "Vision", "os",
        ],
    ]

    /// The subjects a platform adapter never binds, besides the view layer: what it would have to stop adapting to
    /// bind — the study side, its review logic and its presentation, the model, and the sense ladder. **`ReviewKit`
    /// joined 2026-10-08**, after a review planted `MacCapture → ReviewKit` and nothing here refused it; plan §3's row
    /// for the class had left it out too. `permittedDependencies` holds the adapter's edges exactly besides.
    static let adapterNeverBinds: Set<String> = [
        "StudyKit", "ReviewKit", "StudyPresentation", "StudyModels", "ModelKit", "XiaolaiDictCore",
    ]

    /// The view layer, which may bind AppKit and SwiftUI, and is excluded from the rule below.
    static let viewLayer: Set<String> = ["XiaolaiDictUI", "XiaolaiDict"]

    /// What draws: the frameworks no target outside the view layer may bind, below it or in the presentation layer.
    static let viewFrameworks: Set<String> = ["AppKit", "SwiftUI", "UIKit", "QuartzCore", "WebKit"]

    // MARK: - No view layer below the view layer

    /// **The invariant `AGENTS.md` has always stated and nothing has ever checked.**
    ///
    /// Two reasons it matters beyond tidiness: a target that binds AppKit stops being exhaustively
    /// testable without a window server, and the segfault-prone DictionaryServices calls stay behind
    /// the XPC boundary only while the targets on this side of it have no reason to draw.
    @Test func nothingBelowTheViewLayerBindsAppKitOrSwiftUI() throws {
        let forbidden = Self.viewFrameworks
        var offenders: [String] = []
        for target in Self.allowed.keys.sorted() {
            for (file, imports) in try Self.imports(of: target) {
                for module in imports where forbidden.contains(module) {
                    offenders.append("\(target)/\(file) imports \(module)")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// **The presentation layer binds no UI framework, and not the view layer either** — §3's second class. The
    /// first half is the rule below the view layer; the second is what keeps these values drawable by a surface
    /// that is not this app's.
    @Test func thePresentationLayerBindsNoUIFrameworkAndNotTheViewLayer() throws {
        var problems: [String] = []
        for target in Self.presentation.keys.sorted() {
            let files = try Self.imports(of: target)
            // A walk that read nothing has nothing to refuse, and would pass for a target that is not there.
            if files.isEmpty { problems.append("nothing scanned under Sources/\(target)") }
            problems += Self.presentationProblems(of: target, files: files)
        }
        #expect(problems.isEmpty, "\(problems)")
        // The control: each refusal, on a list no scan made, and nothing for what a presentation target may bind.
        #expect(Self.presentationProblems(of: "StudyPresentation", files: [
            ("Clean.swift", ["Foundation", "StudyKit"]), ("Drawn.swift", ["SwiftUI"]),
            ("Shown.swift", ["XiaolaiDictUI"]), ("Both.swift", ["AppKit", "XiaolaiDict"]),
        ]) == [
            "StudyPresentation/Drawn.swift imports SwiftUI, a UI framework",
            "StudyPresentation/Shown.swift imports XiaolaiDictUI, the view layer",
            "StudyPresentation/Both.swift imports AppKit, a UI framework",
            "StudyPresentation/Both.swift imports XiaolaiDict, the view layer",
        ])
    }

    /// What a presentation target's imports break of its class's rule, in the words the check above uses.
    static func presentationProblems(of target: String, files: [(file: String, modules: [String])]) -> [String] {
        files.flatMap { file, modules in
            modules.compactMap { module -> String? in
                if viewFrameworks.contains(module) { return "\(target)/\(file) imports \(module), a UI framework" }
                if viewLayer.contains(module) { return "\(target)/\(file) imports \(module), the view layer" }
                return nil
            }
        }
    }

    /// **A platform adapter binds AppKit and no other UI framework, and none of the subjects it does not adapt** —
    /// §3's third class. The exact set below holds the frameworks; this names the file, and refuses a sibling the exact
    /// set filters out with every other.
    @Test func thePlatformAdapterBindsAppKitButNoOtherUIFrameworkAndNoSubjectItDoesNotAdapt() throws {
        var problems: [String] = []
        for target in Self.platformAdapters.keys.sorted() {
            let files = try Self.imports(of: target)
            // A walk that read nothing has nothing to refuse, and would pass for a target that is not there.
            if files.isEmpty { problems.append("nothing scanned under Sources/\(target)") }
            problems += Self.adapterProblems(of: target, files: files)
        }
        #expect(problems.isEmpty, "\(problems)")
        // The control: each refusal, on a list no scan made, and nothing for what an adapter may bind.
        #expect(Self.adapterProblems(of: "MacCapture", files: [
            ("Clean.swift", ["AppKit", "ApplicationServices", "Capture"]), ("Drawn.swift", ["SwiftUI"]),
            ("Studied.swift", ["StudyKit"]), ("Reviewed.swift", ["ReviewKit"]), ("Shown.swift", ["XiaolaiDictUI"]),
            ("Both.swift", ["QuartzCore", "XiaolaiDictCore"]),
        ]) == [
            "MacCapture/Drawn.swift imports SwiftUI, a UI framework other than AppKit",
            "MacCapture/Studied.swift imports StudyKit, a subject a platform adapter does not adapt",
            "MacCapture/Reviewed.swift imports ReviewKit, a subject a platform adapter does not adapt",
            "MacCapture/Shown.swift imports XiaolaiDictUI, the view layer",
            "MacCapture/Both.swift imports QuartzCore, a UI framework other than AppKit",
            "MacCapture/Both.swift imports XiaolaiDictCore, a subject a platform adapter does not adapt",
        ])
    }

    /// What a platform adapter's imports break of its class's rule, in the words the check above uses.
    static func adapterProblems(of target: String, files: [(file: String, modules: [String])]) -> [String] {
        files.flatMap { file, modules in
            modules.compactMap { module -> String? in
                if module != "AppKit", viewFrameworks.contains(module) {
                    return "\(target)/\(file) imports \(module), a UI framework other than AppKit"
                }
                if viewLayer.contains(module) { return "\(target)/\(file) imports \(module), the view layer" }
                if adapterNeverBinds.contains(module) {
                    return "\(target)/\(file) imports \(module), a subject a platform adapter does not adapt"
                }
                return nil
            }
        }
    }

    /// **And the list of targets to check is read off `Package.swift`, not kept by hand.** A target
    /// added later and forgotten here is a target the rule above does not cover, and it would go on
    /// passing — the same shape as a source scan that names one directory.
    @Test func everyLibraryTargetIsEitherCheckedOrTheViewLayer() throws {
        let declared = try Self.targets()
        let accountedFor = Set(Self.allowed.keys)
            .union(Self.presentation.keys)
            .union(Self.platformAdapters.keys)
            .union(Self.viewLayer)
            .union(["XiaolaiDictService", "XiaolaiDictModelService", "XiaolaiDictTestSupport"])
        #expect(Set(declared) == accountedFor, """
            declared in Package.swift: \(declared.sorted()); accounted for here: \
            \(accountedFor.sorted())
            """)
        // One class each: a target in two tables would be held to whichever rule happened to be read first.
        #expect(Set(Self.allowed.keys).isDisjoint(with: Self.presentation.keys))
        #expect(Set(Self.allowed.keys).isDisjoint(with: Self.platformAdapters.keys))
        #expect(Set(Self.presentation.keys).isDisjoint(with: Self.platformAdapters.keys))
    }

    // MARK: - What each target binds

    /// Every target held to an exact framework set: below the view layer, the presentation layer and the platform
    /// adapters.
    static var exactSets: [String: Set<String>] {
        allowed.merging(presentation) { below, _ in below }.merging(platformAdapters) { held, _ in held }
    }

    @Test func eachTargetBindsOnlyWhatItIsAllowedTo() throws {
        var surprises: [String] = []
        for (target, permitted) in Self.exactSets.sorted(by: { $0.key < $1.key }) {
            let siblings = Set(Self.exactSets.keys).union(Self.viewLayer)
            var bound: Set<String> = []
            for (_, imports) in try Self.imports(of: target) {
                bound.formUnion(imports.filter { !siblings.contains($0) })
            }
            let extra = bound.subtracting(permitted)
            let gone = permitted.subtracting(bound)
            if !extra.isEmpty { surprises.append("\(target) newly binds \(extra.sorted())") }
            // Reported too: a permitted framework nothing imports any more is a line that has
            // stopped meaning anything, and an allow-list nobody prunes is one nobody reads.
            if !gone.isEmpty { surprises.append("\(target) no longer binds \(gone.sorted()) — drop it from the list") }
        }
        #expect(surprises.isEmpty, "\(surprises)")
    }

    // MARK: - Imports and declared dependencies agree

    /// **An import with no declared edge, and a declared edge nothing imports.** Both directions,
    /// because each hides a different mistake: the first compiles only by accident, against a module
    /// still on the search path — which is exactly how every moved type read as "ambiguous for type
    /// lookup" during the split, three files having kept `import XiaolaiDictCore` after their target
    /// stopped depending on it. The second is a dependency nobody needs, which is how a target comes
    /// to link a subject it does not use.
    ///
    /// **Every target, test targets and the fixture target included** (2026-10-08, before the core was
    /// split). Test targets were skipped on the theory that one depends on modules it never imports; read,
    /// none did, and the skip let a spike of the split plant an undeclared `import StudyKit` in a test that
    /// every check passed — it compiled only because the module was on the search path. Extending the scan
    /// found three such edges, each fixed in the manifest: `XiaolaiDictTests` imported `XiaolaiDictCore`
    /// undeclared, and `DictionaryBridgeTests` and `LocalModelTests` declared `XiaolaiDictBase` and imported
    /// it nowhere.
    @Test func declaredDependenciesAndImportsAgree() throws {
        let ours = Set(try Self.targets())
        var problems: [String] = []
        for (target, declared) in try Self.dependencyMap().sorted(by: { $0.key < $1.key }) {
            let files = try Self.imports(under: Self.sources(of: target))
            // A walk that read nothing agrees with every declaration that happens to be empty.
            if files.isEmpty { problems.append("nothing scanned under \(Self.sources(of: target).path)") }
            let imported = files.reduce(into: Set<String>()) { $0.formUnion($1.modules.filter(ours.contains)) }
            problems += Self.dependencyProblems(of: target, imported: imported, declared: declared)
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    /// **The control: an undeclared import planted in a test file is refused** — in a copy of a test
    /// target's directory, never in `Tests`, for the reason `aPlantedConditionalIsFlagged` gives — and so is
    /// a test target's declared edge nothing imports.
    @Test func aTestTargetsUndeclaredImportIsRefused() throws {
        let target = "ReviewKitTests"
        let declared = try #require(Self.dependencyMap()[target])
        let ours = Set(try Self.targets())
        let scratch = TemporaryDirectory(named: "xiaolaidict-planted-test-import")
        let copy = scratch.appending(target)
        try FileManager.default.copyItem(at: Self.sources(of: target), to: copy)
        func problems() throws -> [String] {
            let imported = try Self.imports(under: copy)
                .reduce(into: Set<String>()) { $0.formUnion($1.modules.filter(ours.contains)) }
            return Self.dependencyProblems(of: target, imported: imported, declared: declared)
        }
        #expect(try problems().isEmpty, "the clean copy was flagged")
        try "@testable import XiaolaiDictCore\n"
            .write(to: copy.appending(path: "Planted.swift"), atomically: true, encoding: .utf8)
        #expect(try problems() == ["ReviewKitTests imports XiaolaiDictCore without Package.swift naming it"])
        #expect(Self.dependencyProblems(of: target, imported: [], declared: declared)
                == ["ReviewKitTests depends on ReviewKit and imports it nowhere"])
    }

    /// The two ways a target's imports and its declared edges disagree, in the words every check here uses.
    static func dependencyProblems(of target: String, imported: Set<String>, declared: Set<String>) -> [String] {
        imported.subtracting(declared).sorted().map { "\(target) imports \($0) without Package.swift naming it" }
            + declared.subtracting(imported).sorted().map { "\(target) depends on \($0) and imports it nowhere" }
    }

    // MARK: - Which of this package's targets each target may depend on

    /// **Every target `Package.swift` declares but the tests, and the siblings it may depend on — exact sets, each row
    /// with its reason**, as `allowed` is for what a target binds of the SDK.
    ///
    /// The tables above filter this package's own modules out, and `declaredDependenciesAndImportsAgree` holds a
    /// target's imports equal to its declared edges — so **an import and its declaration added together passed every
    /// check in this file**. A review in refute mode planted `StudyKit → Capture` (the study side bound to the capture
    /// policy the split separated) and `MacCapture → ReviewKit` (review logic in the capture adapter), each as an import
    /// and a declared edge, and all 3,034 tests passed (2026-10-08). The graph the split was for is written down here
    /// instead: the subjects' rows are plan-macos-modularisation §3's target graph after P5, and every other row is
    /// the edge set the target had on `main` before the split, which the plan kept. A new edge is a decision recorded
    /// in a row, never a line that compiles.
    static let permittedDependencies: [String: Set<String>] = [
        // No domain vocabulary, so nothing of this package to speak (Package.swift's own comment). Every target that
        // depends on it is below.
        "XiaolaiDictBase": [],
        // §3 `DM --> Base`: the dictionary's vocabulary, and its identities and deadlines from Base.
        "DictionaryModel": ["XiaolaiDictBase"],
        // A file format plus a table of measured facts, testable and reusable without the app — depends on nothing,
        // not even Base (`main`, unchanged by the split).
        "AppleDictionaryFormat": [],
        // The index the format module feeds, apart from it so the dictionary service never links SQLite (`main`).
        "DictionaryIndex": ["AppleDictionaryFormat"],
        // Talks about a model the app never links; it needs no sibling to (`main`).
        "ModelKit": [],
        // The review logic a phone, a watch or a TV could run: depends on nothing (ADR-0047;
        // `reviewKitDependsOnNothing` also reads its declaration line).
        "ReviewKit": [],
        // §3: the two values the study ledger and the capture policy share, owned by neither — so it depends on neither.
        "CaptureModel": [],
        // §3 `SK --> Base & DM & RK & CM`. **No `Capture`, no core, no model**: a client that reviews links the study
        // side without the capture policy, which is what the split was for.
        "StudyKit": ["XiaolaiDictBase", "DictionaryModel", "ReviewKit", "CaptureModel"],
        // §3 `CP --> Base & DM & CM`. **No `StudyKit`**: the capture policy records nothing.
        "Capture": ["XiaolaiDictBase", "DictionaryModel", "CaptureModel"],
        // §3 `CORE --> Base & DM & MK & CM`: the sense ladder and the sentence pane ask the model; the ledger and the
        // capture policy are no longer the core's.
        "XiaolaiDictCore": ["XiaolaiDictBase", "DictionaryModel", "ModelKit", "CaptureModel"],
        // §3 `SP --> DM & SK & RK` (corrected in the plan during P4b): values drawn from the study side's records.
        "StudyPresentation": ["DictionaryModel", "ReviewKit", "StudyKit"],
        // §3 `SM --> SP & SK & Base & DM & RK & CM & CORE`: the study models drive the ledger and resolve the sense the
        // reader tapped through the core (`PanelSelection`). **No capture adapter and no view layer.**
        "StudyModels": [
            "XiaolaiDictBase", "DictionaryModel", "ReviewKit", "CaptureModel", "StudyKit", "StudyPresentation",
            "XiaolaiDictCore",
        ],
        // §3 `MC --> Base & DM & CP & CM`: the adapter drives `Capture`'s policy and nothing else of the reader's side —
        // **no study side, review logic, model or core**; `adapterNeverBinds` refuses the same by import.
        "MacCapture": ["XiaolaiDictBase", "DictionaryModel", "CaptureModel", "Capture"],
        // The private DictionaryServices API, linked only by the dictionary service (`main`).
        "DictionaryBridge": ["XiaolaiDictBase", "DictionaryModel"],
        // A sentence in, a span out, from the format reader to the wire protocol (`main`).
        "PhraseLookup": ["DictionaryModel", "AppleDictionaryFormat"],
        // The dictionary service: the bridge and the phrase lookup, and **none of the reader's side**
        // (`neverInAService` says the same by name; `main`).
        "XiaolaiDictService": ["XiaolaiDictBase", "DictionaryModel", "DictionaryBridge", "PhraseLookup"],
        // What the model service does with a request, against any `LanguageModel` (`main`).
        "LocalModel": ["ModelKit"],
        // The model service: its MLX products are another package's and not in this table (`main`).
        "XiaolaiDictModelService": ["XiaolaiDictBase", "ModelKit", "LocalModel"],
        // §3 `UI --> SP & MC & SK & CP & CORE & CM & DM`, plus the three it had on `main`, which the graph does not
        // redraw: Base, ModelKit (the model's choices in Settings) and ReviewKit (Review's surface). **No
        // `StudyModels`**: the models are the app's to compose and hand in.
        "XiaolaiDictUI": [
            "XiaolaiDictBase", "DictionaryModel", "ModelKit", "ReviewKit", "CaptureModel", "StudyKit",
            "StudyPresentation", "Capture", "MacCapture", "XiaolaiDictCore",
        ],
        // §3 `APP --> UI & SM & MC & SK & CP & CORE`, plus Base, DictionaryModel, ModelKit and ReviewKit, which it had on
        // `main`, and two §3 does not draw: `CaptureModel` (the app records where and how a word was read, since P1) and
        // `StudyPresentation` (it composes the values its scenes hand the view layer, since P4a). **Never
        // `DictionaryBridge`**: the private API's failure mode is a segfault, and it stays behind the XPC boundary.
        "XiaolaiDict": [
            "XiaolaiDictBase", "DictionaryModel", "ModelKit", "ReviewKit", "CaptureModel", "StudyKit",
            "StudyPresentation", "StudyModels", "Capture", "MacCapture", "XiaolaiDictCore", "XiaolaiDictUI",
        ],
        // The index builder and the aligner, as commands: the format module and the index, nothing else (`main`).
        "XiaolaiDictIndex": ["AppleDictionaryFormat", "DictionaryIndex"],
        "XiaolaiDictAlign": ["AppleDictionaryFormat", "DictionaryIndex"],
        // What the test targets share: depends on nothing, so a test that links it links nothing else by it (`main`).
        "XiaolaiDictTestSupport": [],
    ]

    /// **`Package.swift`'s graph is exactly `permittedDependencies`, in both directions** — an edge no row permits, an
    /// edge a row permits that the manifest dropped, a target with no row and a row with no target are each refused.
    @Test func everyTargetDependsOnExactlyWhatItsRowPermits() throws {
        let problems = Self.graphProblems(declared: try Self.declaredGraph(of: Self.manifest()))
        #expect(problems.isEmpty, "\(problems)")
    }

    /// **The controls: the two edges the review planted, each with its import's declaration, in a copy of the manifest**
    /// — each refused by name and nothing else in the copy refused — and the other three disagreements, on a map no
    /// manifest made. Never planted into `Package.swift`, which a parallel test is reading.
    @Test func anEdgeTheGraphDoesNotDrawIsRefused() throws {
        let manifest = try Self.manifest()
        #expect(Self.graphProblems(declared: try Self.declaredGraph(of: manifest)).isEmpty, "the real manifest was flagged")
        for (target, edge) in [("StudyKit", "Capture"), ("MacCapture", "ReviewKit")] {
            let planted = try Self.planting(edge, into: target, in: manifest)
            #expect(try Self.dependencyMap(of: planted)[target]?.contains(edge) == true, "premise: \(target) → \(edge) was read")
            #expect(Self.graphProblems(declared: try Self.declaredGraph(of: planted))
                    == ["\(target) depends on \(edge), which its row in permittedDependencies does not permit"])
        }
        var declared = try Self.declaredGraph(of: manifest)
        declared["StudyKit"]?.remove("ReviewKit")
        declared["Unsafe2"] = []
        declared["ReviewKit"] = nil
        #expect(Self.graphProblems(declared: declared) == [
            "Unsafe2 is declared in Package.swift and has no row in permittedDependencies",
            "ReviewKit has a row in permittedDependencies and no declaration in Package.swift",
            "StudyKit no longer depends on ReviewKit — drop it from its row",
        ])
    }

    /// Where `declared` and `permittedDependencies` disagree, in the words the two checks above use.
    static func graphProblems(declared: [String: Set<String>]) -> [String] {
        let permitted = permittedDependencies
        var problems = Set(declared.keys).subtracting(permitted.keys).sorted()
            .map { "\($0) is declared in Package.swift and has no row in permittedDependencies" }
        problems += Set(permitted.keys).subtracting(declared.keys).sorted()
            .map { "\($0) has a row in permittedDependencies and no declaration in Package.swift" }
        for (target, edges) in declared.sorted(by: { $0.key < $1.key }) {
            guard let row = permitted[target] else { continue }
            problems += edges.subtracting(row).sorted()
                .map { "\(target) depends on \($0), which its row in permittedDependencies does not permit" }
            problems += row.subtracting(edges).sorted().map { "\(target) no longer depends on \($0) — drop it from its row" }
        }
        return problems
    }

    /// Every target `manifest` declares but the tests, and its in-package dependencies.
    static func declaredGraph(of manifest: String) throws -> [String: Set<String>] {
        let targets = Set(try Self.targets(in: manifest))
        return try Self.dependencyMap(of: manifest).filter { targets.contains($0.key) }
    }

    /// `manifest` with `edge` added to the front of `target`'s dependency list — the declaration a planted import needs.
    static func planting(_ edge: String, into target: String, in manifest: String) throws -> String {
        var lines = manifest.components(separatedBy: "\n")
        let index = try #require(lines.firstIndex { $0.contains("name: \"\(target)\"") && $0.contains("dependencies: [") },
                                 "premise: \(target) declares its dependencies on one line")
        lines[index] = lines[index].replacingOccurrences(of: "dependencies: [", with: "dependencies: [\"\(edge)\", ")
        return lines.joined(separator: "\n")
    }

    private static func manifest() throws -> String {
        try String(contentsOf: repository.appending(path: "Package.swift"), encoding: .utf8)
    }

    // MARK: - ReviewKit: the first checks, before the compiler's (ADR-0047)

    /// **Every spelling Swift accepts for binding a module, read as the module it binds.**
    ///
    /// The scan matched `import`, `@preconcurrency import` and `@_implementationOnly import` and
    /// nothing else, so an access-levelled import, `@testable`, `@_exported` and `@_spi(…)` were
    /// invisible to every rule above — and `import struct X.Y` was read as a module called `struct`.
    /// Harmless while nothing used them; load-bearing once a target's whole boundary rests on this
    /// scan, since a stale module satisfies the compiler.
    @Test func theImportScanSeesEverySpelling() {
        let cases: [(line: String, modules: [String])] = [
            ("import Foundation", ["Foundation"]),
            ("import Carbon.HIToolbox", ["Carbon.HIToolbox"]),
            ("@preconcurrency import AppKit", ["AppKit"]),
            ("@_implementationOnly import AppKit", ["AppKit"]),
            ("@testable import XiaolaiDictCore", ["XiaolaiDictCore"]),
            ("@_exported import XiaolaiDictCore", ["XiaolaiDictCore"]),
            ("@_spi(Internals) import XiaolaiDictCore", ["XiaolaiDictCore"]),
            ("internal import XiaolaiDictCore", ["XiaolaiDictCore"]),
            ("public import XiaolaiDictCore", ["XiaolaiDictCore"]),
            ("package import XiaolaiDictCore", ["XiaolaiDictCore"]),
            ("fileprivate import XiaolaiDictCore", ["XiaolaiDictCore"]),
            ("private import XiaolaiDictCore", ["XiaolaiDictCore"]),
            ("import struct XiaolaiDictCore.Ledger", ["XiaolaiDictCore"]),
            ("import class XiaolaiDictCore.LedgerStore", ["XiaolaiDictCore"]),
            ("import enum XiaolaiDictCore.LedgerError", ["XiaolaiDictCore"]),
            ("import protocol XiaolaiDictCore.Probe", ["XiaolaiDictCore"]),
            ("import typealias XiaolaiDictCore.Alias", ["XiaolaiDictCore"]),
            ("import func XiaolaiDictCore.probe", ["XiaolaiDictCore"]),
            ("import var XiaolaiDictCore.probe", ["XiaolaiDictCore"]),
            ("import let XiaolaiDictCore.probe", ["XiaolaiDictCore"]),
            ("    @preconcurrency @_spi(A) public import XiaolaiDictCore", ["XiaolaiDictCore"]),
            ("@_spi(A) @_spi(B) internal import struct XiaolaiDictCore.Ledger", ["XiaolaiDictCore"]),
            ("import Foundation; import AppKit", ["Foundation", "AppKit"]),
            // Backticks around a component name the same module (WI-8).
            ("import `SQLite3`", ["SQLite3"]),
            ("import `Carbon`.`HIToolbox`", ["Carbon.HIToolbox"]),
            ("import struct `XiaolaiDictCore`.Ledger", ["XiaolaiDictCore"]),
            // And what is not an import must stay that way.
            ("let important = 1", []),
            ("importer.run()", []),
            ("let line = \"import AppKit\"", []),
            ("func imports() {}", []),
        ]
        for (line, modules) in cases {
            #expect(Self.importedModules(in: line) == modules, "\(line)")
        }
    }

    /// **Comments are whitespace to Swift, and a line-anchored scan is not.** `/**/ import SwiftUI`
    /// compiles, and SwiftUI exists on every platform the portability check typechecks for — so for
    /// ReviewKit this scan is the only thing between "Foundation only" and a view framework. The same
    /// goes for an import split across lines. Found by trying to get past the four checks (WI-1).
    @Test func theImportScanReadsPastCommentsAndLineBreaks() {
        let cases: [(code: String, modules: [String])] = [
            ("/**/ import SwiftUI", ["SwiftUI"]),
            ("import/**/SwiftUI", ["SwiftUI"]),
            ("/* a\n   b */ import SwiftUI", ["SwiftUI"]),
            ("/* outer /* nested */ still a comment */ import SwiftUI", ["SwiftUI"]),
            ("import\n    SwiftUI", ["SwiftUI"]),
            ("@testable\nimport XiaolaiDictCore", ["XiaolaiDictCore"]),
            ("import Foundation /* ; import AppKit */", ["Foundation"]),
            ("import Foundation // ; import AppKit", ["Foundation"]),
            // A string is not an import, whatever it holds.
            ("let s = \"\"\"\nimport AppKit\n\"\"\"", []),
            ("let s = \"; import AppKit\"", []),
            ("let s = #\"a\\\"#; let t = \"; import AppKit\"", []),
            ("/* import AppKit */", []),
        ]
        for (code, modules) in cases {
            #expect(Self.importedModules(inCode: code) == modules, "\(code)")
        }
    }

    /// **A dependency written as `.target(name:)` is not a second declaration.** The manifest reader
    /// splits on every `.target(`, so `dependencies: [.target(name: "XiaolaiDictBase")]` read as an
    /// empty list followed by a target called `XiaolaiDictBase` — and `reviewKitDependsOnNothing` saw
    /// `[]`. Refused loudly instead, and checked on a string so the real manifest is never edited.
    @Test func aTargetReferenceInADependencyListIsRefused() throws {
        let manifest = """
            .target(name: "ReviewKit", dependencies: [.target(name: "XiaolaiDictBase")]),
            .target(name: "XiaolaiDictBase"),
            """
        #expect(throws: (any Error).self) { try Self.dependencyMap(of: manifest) }
        let plain = """
            .target(name: "ReviewKit", dependencies: ["XiaolaiDictBase"]),
            .target(name: "XiaolaiDictBase"),
            """
        #expect(try Self.dependencyMap(of: plain)["ReviewKit"] == ["XiaolaiDictBase"])
    }

    /// **The edge, not just the import.** `eachTargetBindsOnlyWhatItIsAllowedTo` filters siblings out,
    /// so a dependency on `XiaolaiDictBase` plus an import of it would pass that test and
    /// `declaredDependenciesAndImportsAgree` both. The declaration is one exact line, so a `path:`,
    /// `sources:`, `swiftSettings:` or `dependencies:` added to it is refused here too.
    @Test func reviewKitDependsOnNothing() throws {
        #expect(try Self.dependencyMap()["ReviewKit"] == [])
        let manifest = try String(contentsOf: Self.repository.appending(path: "Package.swift"), encoding: .utf8)
        let declarations = manifest.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(#"name: "ReviewKit""#) }
        #expect(declarations == [#".target(name: "ReviewKit"),"#], "\(declarations)")
    }

    /// **And its tests link it alone**, which is what makes them evidence that the logic runs without
    /// the Mac's modules. `declaredDependenciesAndImportsAgree` reads test targets too (since 2026-10-08),
    /// but it passes an edge that is declared *and* imported, so without this a fixture target or the core
    /// could join the list and the claim would go on reading as true.
    @Test func reviewKitTestsLinkReviewKitAlone() throws {
        #expect(try Self.dependencyMap()["ReviewKitTests"] == ["ReviewKit"])
        let bound = try Self.imports(under: Self.repository.appending(path: "Tests/ReviewKitTests"))
            .reduce(into: Set<String>()) { $0.formUnion($1.modules) }
        // The same row the compiler's verdict reads, so the two cannot drift apart.
        #expect(bound == (try #require(Self.testTargetsMayBind["ReviewKitTests"])).union(["ReviewKit"]),
                "\(bound.sorted())")
    }

    /// **No conditional compilation in ReviewKit, of any kind.** A `#if` is a second build whose
    /// conditions the portability check cannot match: `#if canImport(XiaolaiDictCore)` compiled
    /// against a stale Core module in an incremental build and silently dropped out of a clean one,
    /// measured. Forbidding the directive closes the class — `SWIFT_PACKAGE`, `DEBUG`, `canImport`,
    /// `XIAOLAIDICT_CAPTURE_INSTRUMENTS` — instead of enumerating flags. A legitimate future need is
    /// a reasoned edit to this test.
    @Test func reviewKitHasNoConditionalCompilation() throws {
        let root = Self.repository.appending(path: "Sources/ReviewKit")
        #expect(try SourceScan.code(under: root).count > 0, "nothing scanned under \(root.path)")
        #expect(try Self.conditionalCompilation(under: root).isEmpty)
    }

    /// The control, in a copy: a planted `#if` is never written into `Sources`, where a parallel test
    /// would read it and a crash would leave it for `swift build` to compile.
    @Test func aPlantedConditionalIsFlagged() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-planted-conditional")
        let copy = scratch.appending("ReviewKit")
        try FileManager.default.copyItem(at: Self.repository.appending(path: "Sources/ReviewKit"), to: copy)
        #expect(try Self.conditionalCompilation(under: copy).isEmpty, "the clean copy was flagged")
        for directive in ["#if canImport(XiaolaiDictCore)", "    #elseif SWIFT_PACKAGE", "#else",
                          "let before = 1; #if canImport(AppKit)"] {
            try "import Foundation\n\(directive)\nlet planted = 1\n"
                .write(to: copy.appending(path: "Planted.swift"), atomically: true, encoding: .utf8)
            #expect(try Self.conditionalCompilation(under: copy) == ["Planted.swift:2"], "\(directive)")
        }
    }

    // MARK: - The services serve their own subject (ADR-0010)

    /// The two XPC services, and what they may never bind: the review logic and the notification
    /// center are the reader's side. `verify_service_boundaries` checks the linked binaries for the
    /// same, which also sees what arrives transitively; this sees a source import the day it is typed.
    static let services = ["XiaolaiDictService", "XiaolaiDictModelService"]
    static let neverInAService: Set<String> = [
        "ReviewKit", "UserNotifications",
        // **The reader's side as the core is split into it** (2026-10-08): the study ledger, the capture policy
        // and the two values they share, then the study models, their presentation and the Apple capture
        // readers. Named before any of them exists, so no file moves while a service could bind one unseen —
        // a spike of the split planted `StudyKit` in the dictionary service and every check here passed.
        // `verify_service_boundaries` forbids the same names in both binaries.
        "StudyKit", "Capture", "CaptureModel", "StudyPresentation", "StudyModels", "MacCapture",
    ]

    /// **Neither service imports anything in `neverInAService`, nor depends on it.** The reminder's
    /// delivery is the app's (WI-7), and `UNUserNotificationCenter.current()` aborts a process with no app
    /// bundle — which a service started on demand would be, as far as that call is concerned; the study and
    /// capture modules are the reader's side, as `ReviewKit` is.
    @Test func theServicesBindNeitherTheReviewLogicNorNotifications() throws {
        let dependencies = try Self.dependencyMap()
        for service in Self.services {
            let files = try Self.imports(of: service)
            #expect(!files.isEmpty, "nothing scanned under Sources/\(service)")
            for (file, modules) in files {
                let forbidden = Set(modules).intersection(Self.neverInAService)
                #expect(forbidden.isEmpty, "\(service)/\(file) imports \(forbidden.sorted())")
            }
            let declared = try #require(dependencies[service], "\(service) has no declaration this test could read")
            #expect(declared.intersection(Self.neverInAService).isEmpty, "\(service) depends on \(declared.sorted())")
        }
        // The control: the spellings a service would bind them by are read as those modules.
        #expect(Set(Self.importedModules(inCode: """
            @preconcurrency import UserNotifications
            import ReviewKit
            import StudyKit
            @testable import Capture
            import struct CaptureModel.ReadingPlace
            internal import StudyPresentation
            import StudyModels
            import MacCapture
            """)) == Self.neverInAService)
    }

    /// **The compiler's verdict refuses each of them in each service**, on lists no compiler made: a planted
    /// import of any module in `neverInAService`, beside everything the service declares, is named as a binding
    /// the service never may have.
    @Test func eachServiceRefusesEveryModuleItMayNeverBind() throws {
        for service in Self.services {
            let declared = try #require(Self.dependencyMap()[service], "\(service) has no declaration")
            #expect(try Self.verdict(on: service, compiled: declared.union(["Foundation"])).isEmpty, "\(service)")
            for module in Self.neverInAService.sorted() {
                #expect(try Self.verdict(on: service, compiled: declared.union(["Foundation", module]))
                        .contains("\(service) binds \(module), which a service never may"), "\(service), \(module)")
            }
        }
    }

    /// **Every build that tests also typechecks ReviewKit for iOS, watchOS, tvOS and macOS.**
    /// `portability` is a prerequisite of `test-swift`, and `all`, `run`, `test` and `release` all
    /// reach `test-swift`, so one edit covers every path and a new path that tests inherits it.
    @Test func portabilityRunsOnEveryTestedBuild() throws {
        let makefile = try String(contentsOf: Self.repository.appending(path: "Makefile"), encoding: .utf8)
        #expect(Self.prerequisites(of: "test-swift", in: makefile).contains("portability"))
        for rule in ["all", "run", "test", "release"] {
            #expect(Self.prerequisites(of: rule, in: makefile).contains("test-swift"), "\(rule)")
        }
        let recipe = Self.recipe(of: "portability", in: makefile)
        #expect(recipe.contains("Sources/ReviewKit"), "\(recipe)")
        #expect(recipe.contains("-DSWIFT_PACKAGE"), "\(recipe)")
        // **The compiler's import check allows what this table allows, and nothing else** (WI-8): one
        // list, spelled twice, held equal here.
        let permitted = try #require(Self.allowed["ReviewKit"]).sorted().joined(separator: ",")
        #expect(recipe.contains("--imports \(permitted) Sources/ReviewKit"), "\(recipe)")

        // The reader can fail: a rule that lists something else, and a recipe that is elsewhere.
        let other = "test-swift: metal-guard\n\tswift test\nportability:\n\t@true\n"
        #expect(!Self.prerequisites(of: "test-swift", in: other).contains("portability"))
        #expect(!Self.recipe(of: "portability", in: other).contains("Sources/ReviewKit"))
    }

    // MARK: - The compiler's verdict, for every target (ADR-0047, addendum 2026-10-05)

    /// **What every target binds, as the compiler lists it, judged against the same tables.**
    ///
    /// The scans above read text, and text has spellings they cannot read: an `import` between two
    /// `/"/` regex literals is blanked as the inside of a string (WI-8). `make portability` closed that
    /// for ReviewKit by asking the compiler; every other target's exact set still rested on the scan.
    /// So the verdict, for every target `Package.swift` declares and for `ReviewKitTests`, is
    /// `Tools/portability.sh --list-imports`: `swiftc -emit-imported-modules`, in every configuration a
    /// real build compiles under and with each module of this package importable and not — so a
    /// `#if DEBUG` or a `#if canImport(XiaolaiDictCore)` is asked both ways. The scans stay as the first
    /// check: they name the file, and they keep `Carbon.HIToolbox` apart from `Carbon`, which the
    /// compiler lists as one module. The list of subjects comes from the manifest, and
    /// `everyLibraryTargetIsEitherCheckedOrTheViewLayer` is what refuses a manifest read that came back
    /// short.
    @Test(.timeLimit(.minutes(1)), arguments: try subjects())
    func theCompilerHoldsEveryTargetToItsBoundary(target: String) throws {
        let compiled = try Self.compiledImports(of: Self.sources(of: target))
        let problems = try Self.verdict(on: target, compiled: compiled)
        #expect(problems.isEmpty, "\(problems)")
    }

    /// One planted file, in a copy of `DictionaryIndex` — Foundation and SQLite3, and the format module.
    struct Plant: Sendable, CustomTestStringConvertible {
        let name: String
        let source: String?
        /// What the verdict must say, or nil for a copy that must pass.
        let refusal: String?
        /// Whether the text scan reads no import in it — the hole this verdict exists to close.
        let pastTheScan: Bool
        var testDescription: String { name }

        /// The verdict on one module `DictionaryIndex`'s table does not allow.
        static func unallowed(_ module: String) -> String {
            "DictionaryIndex binds \(module), which is not in its allowed set"
        }

        /// The verdict on a condition no build configuration decides and no entry allows.
        static func undecided(_ condition: String, in place: String = "DictionaryIndex/Planted.swift") -> String {
            "\(place): \(condition) — no build configuration decides it, and no entry in conditionsAllowed allows it"
        }

        /// `statement` between two regex literals, which the scan reads as the inside of one string.
        static func hidden(_ statement: String) -> String {
            "func plantedBefore() -> Bool { \"x\".contains(/\"/) }\n\(statement)\n"
                + "func plantedAfter() -> Bool { \"x\".contains(/\"/) }\n"
        }
    }

    static let plants: [Plant] = [
        Plant(name: "nothing planted", source: nil, refusal: nil, pastTheScan: false),
        // WI-8's three spellings, and the plain import they are spellings of.
        Plant(name: "an import between two regex literals", source: Plant.hidden("import Dispatch"),
              refusal: Plant.unallowed("Dispatch"), pastTheScan: true),
        Plant(name: "a backticked import", source: "import `Compression`\n",
              refusal: Plant.unallowed("Compression"), pastTheScan: false),
        Plant(name: "a directive after a semicolon",
              source: "import Foundation; #if canImport(Dispatch)\nimport Dispatch\n#endif\n",
              refusal: Plant.unallowed("Dispatch"), pastTheScan: false),
        Plant(name: "a plain import", source: "import AppKit\n",
              refusal: Plant.unallowed("AppKit"), pastTheScan: false),
        // Hidden from the scan *and* in a clause only some builds compile: one configuration is not enough.
        Plant(name: "hidden in a clause only a release compiles",
              source: "#if !DEBUG\n" + Plant.hidden("import Accelerate") + "#endif\n",
              refusal: Plant.unallowed("Accelerate"), pastTheScan: true),
        Plant(name: "hidden in a clause only a development bundle compiles",
              source: "#if XIAOLAIDICT_CAPTURE_INSTRUMENTS\n" + Plant.hidden("import Accelerate") + "#endif\n",
              refusal: Plant.unallowed("Accelerate"), pastTheScan: true),
        // True in an incremental build, where the module is already in `.build`; false in a clean one.
        Plant(name: "hidden behind a sibling's canImport",
              source: "#if canImport(XiaolaiDictCore)\n" + Plant.hidden("import Accelerate") + "#endif\n",
              refusal: Plant.unallowed("Accelerate"), pastTheScan: true),
        Plant(name: "a sibling hidden between regex literals", source: Plant.hidden("import XiaolaiDictBase"),
              refusal: "DictionaryIndex imports XiaolaiDictBase without Package.swift naming it", pastTheScan: true),
    ]

    /// **The controls: each binding planted in a copy is refused, and the clean copy passes.** Never
    /// planted into `Sources`, where a parallel test would read it and a crash would leave it for
    /// `swift build` to compile.
    @Test(.timeLimit(.minutes(1)), arguments: plants)
    func aBindingPlantedInACopyIsRefusedByTheCompilersVerdict(plant: Plant) throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-planted-binding")
        let copy = scratch.appending("DictionaryIndex")
        try FileManager.default.copyItem(at: Self.sources(of: "DictionaryIndex"), to: copy)
        if let source = plant.source {
            try source.write(to: copy.appending(path: "Planted.swift"), atomically: true, encoding: .utf8)
            #expect(Self.importedModules(inCode: source).isEmpty == plant.pastTheScan,
                    "the text scan read \(Self.importedModules(inCode: source))")
        }
        let problems = try Self.verdict(on: "DictionaryIndex", compiled: Self.compiledImports(of: copy))
        // Exactly the one problem the plant is: nothing else in the copy may read as one.
        #expect(problems == (plant.refusal.map { [$0] } ?? []), "\(problems)")
    }

    /// **The verdict can fail every way it claims to**, on lists no compiler made: an empty one, one
    /// that lost a permitted module, a declared edge nothing imports, a service binding what it never
    /// may, and a test target binding more than its own subject.
    @Test func theVerdictCanFailEveryWay() throws {
        #expect(try Self.verdict(on: "DictionaryIndex", compiled: []).contains(
            "DictionaryIndex: the compiler listed no import at all, and a list that found nothing cannot be "
                + "trusted to have found the rest"))
        #expect(try Self.verdict(on: "DictionaryIndex", compiled: ["Foundation", "AppleDictionaryFormat"])
                == ["DictionaryIndex no longer binds SQLite3 — drop it from the list"])
        #expect(try Self.verdict(on: "DictionaryIndex", compiled: ["Foundation", "SQLite3"])
                == ["DictionaryIndex depends on AppleDictionaryFormat and imports it nowhere"])
        #expect(try Self.verdict(on: "DictionaryIndex", compiled: ["Foundation", "SQLite3", "AppleDictionaryFormat"])
                .isEmpty)
        // `Carbon.HIToolbox` is permitted as the module the compiler reports it as.
        #expect(try Self.verdict(on: "XiaolaiDictCore", compiled: [
            "Foundation", "NaturalLanguage", "CoreServices", "FoundationModels",
            "Carbon", "os", "XiaolaiDictBase", "DictionaryModel", "ModelKit", "CaptureModel",
        ]).isEmpty)
        let service = try #require(Self.dependencyMap()["XiaolaiDictService"])
        #expect(try Self.verdict(on: "XiaolaiDictService", compiled: service.union(["Foundation", "UserNotifications"]))
                == ["XiaolaiDictService binds UserNotifications, which a service never may"])
        #expect(try Self.verdict(on: "ReviewKitTests", compiled: ["Foundation", "Testing", "ReviewKit", "Combine"])
                == ["ReviewKitTests binds Combine, which is not in its allowed set"])
        // A presentation target binding the view layer is refused as that, not only as an undeclared import —
        // which a declared edge would silence — and its exact set holds it as the tables below the view layer do.
        let presenting = try #require(Self.dependencyMap()["StudyPresentation"], "StudyPresentation has no declaration")
        let declaredView = try Self.verdict(on: "StudyPresentation",
                                            compiled: presenting.union(["Foundation", "XiaolaiDictUI"]))
        #expect(declaredView.contains("StudyPresentation binds XiaolaiDictUI, which a presentation target never may"),
                "\(declaredView)")
        #expect(try Self.verdict(on: "StudyPresentation", compiled: presenting.union(["Foundation", "SwiftUI"]))
                == ["StudyPresentation binds SwiftUI, which is not in its allowed set"])
        // A platform adapter binding a subject it does not adapt is refused as that, declared or not; a UI framework
        // other than AppKit is outside its exact set; and its whole set, with what it declares, passes.
        let adapting = try #require(Self.dependencyMap()["MacCapture"], "MacCapture has no declaration")
        let adapterSet = try #require(Self.platformAdapters["MacCapture"])
        #expect(try Self.verdict(on: "MacCapture", compiled: adapting.union(adapterSet)).isEmpty)
        let studied = try Self.verdict(on: "MacCapture", compiled: adapting.union(adapterSet).union(["StudyKit"]))
        #expect(studied.contains("MacCapture binds StudyKit, which a platform adapter never may"), "\(studied)")
        let reviewed = try Self.verdict(on: "MacCapture", compiled: adapting.union(adapterSet).union(["ReviewKit"]))
        #expect(reviewed.contains("MacCapture binds ReviewKit, which a platform adapter never may"), "\(reviewed)")
        let shown = try Self.verdict(on: "MacCapture", compiled: adapting.union(adapterSet).union(["XiaolaiDictUI"]))
        #expect(shown.contains("MacCapture binds XiaolaiDictUI, which a platform adapter never may"), "\(shown)")
        #expect(try Self.verdict(on: "MacCapture", compiled: adapting.union(adapterSet).union(["SwiftUI"]))
                == ["MacCapture binds SwiftUI, which is not in its allowed set"])
        #expect(try Self.verdict(on: "Undeclared", compiled: ["Foundation"])
                == ["Undeclared has no declaration this test could read"])
    }

    // MARK: - Every condition is one the build configurations decide (the final closing pass, finding 3)

    /// The defines the import list's three configurations are asked under: `theFlagsAreTheConfigurationsDefines`
    /// holds this to the `configurations` line of `Tools/portability.sh`, so the two cannot drift apart.
    static let buildFlags: Set<String> = ["SWIFT_PACKAGE", "DEBUG", "XIAOLAIDICT_CAPTURE_INSTRUMENTS"]

    /// **A condition no configuration decides, allowed by name and target, with its reason** — the table this
    /// verdict reads, and the only way such a condition passes. An entry nothing holds any more is refused too.
    static let conditionsAllowed: [String: [String: String]] = [
        "XiaolaiDict": [
            // `TranslationReport` asks the framework only where the SDK has it. An SDK framework, not a module
            // of this package or another: importable in every build of every configuration, on every Mac that
            // builds — so `--list-imports` answers it as every build does, and lists `Translation`.
            "canImport(Translation)": "an SDK framework, decided by the SDK and never by what a build has built",
        ],
    ]

    /// **What a target's conditions are allowed to be, judged as the parser read them, never evaluated.**
    ///
    /// The compiler's list is asked in the three configurations and with every sibling importable and not —
    /// which decides a define and an all-or-nothing `canImport` of a sibling, and nothing else. Another
    /// package's `canImport(MLX)`, or `canImport(A) && !canImport(B)` of two siblings, is true in some
    /// incremental build and in no pass the list makes, so the import behind it was never listed: the verdict
    /// depended on what happened to be importable. So a condition must be built from the configurations' own
    /// defines — or be in `conditionsAllowed` for this target, with its reason.
    @Test(.timeLimit(.minutes(1)), arguments: try subjects())
    func everyConditionIsOneTheBuildConfigurationsDecide(target: String) throws {
        let problems = Self.conditionVerdict(on: target, listed: try Self.conditions(of: Self.sources(of: target)))
        #expect(problems.isEmpty, "\(problems)")
    }

    /// **The hole, planted in a copy of `DictionaryIndex`**, each import hidden from the text scan between
    /// regex literals: the compiler's verdict passes it, as the reviewer found, and the condition is refused.
    static let conditionPlants: [Plant] = [
        Plant(name: "behind another package's canImport",
              source: "#if canImport(MLX)\n" + Plant.hidden("import AppKit") + "#endif\n",
              refusal: Plant.undecided("#if canImport(MLX)"), pastTheScan: true),
        Plant(name: "behind some siblings' canImport and not others'",
              source: "#if canImport(AppleDictionaryFormat) && !canImport(XiaolaiDictCore)\n"
                + Plant.hidden("import AppKit") + "#endif\n",
              refusal: Plant.undecided("#if canImport(AppleDictionaryFormat) && !canImport(XiaolaiDictCore)"),
              pastTheScan: true),
        // And the same two after a `;`, the spelling a line-start reader of text misses.
        Plant(name: "after a semicolon, behind another package's canImport",
              source: "let opening = 1; #if canImport(MLX)\n" + Plant.hidden("import AppKit") + "#endif\n",
              refusal: Plant.undecided("#if canImport(MLX)"), pastTheScan: true),
    ]

    @Test(.timeLimit(.minutes(1)), arguments: conditionPlants)
    func aConditionOnWhatABuildHasBuiltIsRefused(plant: Plant) throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-planted-condition")
        let copy = scratch.appending("DictionaryIndex")
        try FileManager.default.copyItem(at: Self.sources(of: "DictionaryIndex"), to: copy)
        let source = try #require(plant.source)
        try source.write(to: copy.appending(path: "Planted.swift"), atomically: true, encoding: .utf8)
        #expect(Self.importedModules(inCode: source).isEmpty == plant.pastTheScan,
                "the text scan read \(Self.importedModules(inCode: source))")
        // The premise: what the compiler lists cannot see it, in any pass it makes.
        #expect(try Self.verdict(on: "DictionaryIndex", compiled: Self.compiledImports(of: copy)).isEmpty,
                "premise: the compiler's verdict saw the hidden import after all")
        let problems = Self.conditionVerdict(on: "DictionaryIndex", listed: try Self.conditions(of: copy))
        #expect(problems == (plant.refusal.map { [$0] } ?? []), "\(problems)")
    }

    /// **The verdict can fail every way it claims to**, on lists no parser made.
    @Test func theConditionVerdictCanFailEveryWay() {
        func listed(_ text: String, _ directive: String = "#if") -> [ListedCondition] {
            [ListedCondition(file: "Planted.swift", directive: directive, text: text)]
        }
        for decided in ["DEBUG", "!XIAOLAIDICT_CAPTURE_INSTRUMENTS", "SWIFT_PACKAGE && !(DEBUG || XIAOLAIDICT_CAPTURE_INSTRUMENTS)"] {
            #expect(Self.conditionVerdict(on: "DictionaryIndex", listed: listed(decided)).isEmpty, "\(decided)")
        }
        for undecided in ["canImport(XiaolaiDictCore)", "os(macOS)", "FEATURE_NOBODY_PASSES", "DEBUG || canImport(MLX)",
                          "compiler(>=6.0)", "true"] {
            #expect(Self.conditionVerdict(on: "DictionaryIndex", listed: listed(undecided))
                    == [Plant.undecided("#if \(undecided)")], "\(undecided)")
        }
        #expect(Self.conditionVerdict(on: "DictionaryIndex", listed: listed("canImport(MLX)", "#elseif"))
                == [Plant.undecided("#elseif canImport(MLX)")])
        #expect(Self.conditionVerdict(on: "DictionaryIndex", listed: listed(""))
                == [Plant.undecided("#if (a condition the parser does not bound)")])
        // An allowance is its own target's, and one nothing uses any more is a line to drop.
        #expect(Self.conditionVerdict(on: "XiaolaiDict", listed: listed("canImport(Translation)")).isEmpty)
        #expect(Self.conditionVerdict(on: "DictionaryIndex", listed: listed("canImport(Translation)"))
                == [Plant.undecided("#if canImport(Translation)")])
        #expect(Self.conditionVerdict(on: "XiaolaiDict", listed: [])
                == ["XiaolaiDict allows canImport(Translation), which no condition holds any more — drop it from the table"])
        // A platform adapter refuses even a condition the configurations decide — the instruments' define first.
        for decided in ["XIAOLAIDICT_CAPTURE_INSTRUMENTS", "DEBUG", "canImport(AppKit)"] {
            #expect(Self.conditionVerdict(on: "MacCapture", listed: listed(decided))
                    == ["MacCapture/Planted.swift: #if \(decided) — a platform adapter compiles one way, and no entry "
                        + "in conditionsAllowed allows it"], "\(decided)")
        }
        #expect(Self.conditionVerdict(on: "MacCapture", listed: []).isEmpty)
    }

    /// **The flags are the configurations' defines, read off the script**, and the reader can fail.
    @Test func theFlagsAreTheConfigurationsDefines() throws {
        let script = try String(contentsOf: Self.repository.appending(path: "Tools/portability.sh"), encoding: .utf8)
        #expect(try Self.configurationDefines(in: script) == Self.buildFlags)
        let fourth = script.replacingOccurrences(of: #""-DSWIFT_PACKAGE")"#, with: #""-DSWIFT_PACKAGE" "-DFOURTH")"#)
        #expect(fourth != script, "premise: the configurations line is where the reader looks")
        #expect(try Self.configurationDefines(in: fourth) == Self.buildFlags.union(["FOURTH"]))
        #expect(throws: (any Error).self) { try Self.configurationDefines(in: "#!/bin/bash\n") }
    }

    /// **A list of conditions that could not be made is never an empty one**, as for the compiler's list.
    @Test(.timeLimit(.minutes(1))) func aListOfConditionsThatCouldNotBeMadeThrows() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-unlistable-conditions")
        let empty = scratch.appending("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: ScriptRefused.self) { try Self.conditions(of: empty) }
        let broken = scratch.appending("Broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "#if DEBUG\nlet = \n#endif\n".write(to: broken.appending(path: "Broken.swift"), atomically: true, encoding: .utf8)
        #expect(throws: ScriptRefused.self) { try Self.conditions(of: broken) }
    }

    /// One `#if` or `#elseif` and its condition, as the parser read it. An empty condition is one it could
    /// not bound.
    struct ListedCondition: Sendable, Equatable {
        let file: String
        let directive: String
        let text: String
    }

    /// Every rule above, asked of one target's conditions: decided by the configurations, or allowed by name.
    ///
    /// **A platform adapter has no condition at all**, even one the configurations decide, unless it is allowed by name
    /// with its reason (plan-macos-modularisation §3, P5): it compiles one way, and that one way is what a counterpart
    /// on another platform matches. A development instrument that reads the screen stays in the app, behind its define.
    static func conditionVerdict(on target: String, listed: [ListedCondition]) -> [String] {
        let allowed = conditionsAllowed[target] ?? [:]
        let adapter = platformAdapters[target] != nil
        var problems: [String] = [], used: Set<String> = []
        for condition in listed {
            if !adapter, decidedByTheConfigurations(condition.text) { continue }
            if allowed[condition.text] != nil {
                used.insert(condition.text)
                continue
            }
            let text = condition.text.isEmpty ? "(a condition the parser does not bound)" : condition.text
            if adapter {
                problems.append("\(target)/\(condition.file): \(condition.directive) \(text) — a platform adapter "
                                + "compiles one way, and no entry in conditionsAllowed allows it")
            } else {
                problems.append(Plant.undecided("\(condition.directive) \(text)", in: "\(target)/\(condition.file)"))
            }
        }
        for unused in Set(allowed.keys).subtracting(used).sorted() {
            problems.append("\(target) allows \(unused), which no condition holds any more — drop it from the table")
        }
        return problems
    }

    /// Whether `condition` is built from `buildFlags` alone, with `!`, `&&`, `||` and parentheses: then the
    /// three configurations decide it, and the import list has asked it every way a build can.
    static func decidedByTheConfigurations(_ condition: String) -> Bool {
        let names = condition.matches(of: /[A-Za-z_][A-Za-z0-9_]*/).map { String($0.output) }
        let rest = condition.replacing(/[A-Za-z_][A-Za-z0-9_]*/, with: "")
        return !names.isEmpty && Set(names).isSubset(of: buildFlags) && rest.allSatisfy { "!&|() ".contains($0) }
    }

    /// The `-D` defines on the `configurations=(…)` line of a copy of `Tools/portability.sh`.
    static func configurationDefines(in script: String) throws -> Set<String> {
        guard let line = script.split(separator: "\n").first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("configurations=(")
        }) else { throw ScriptRefused(arguments: ["configurations"], status: 0, said: "no configurations line") }
        return Set(line.matches(of: /-D([A-Za-z_][A-Za-z0-9_]*)/).map { String($0.output.1) })
    }

    /// What the parser reads `directory`'s conditions as: `Tools/portability.sh --list-conditions`. A refusal
    /// throws, carrying what the script said.
    static func conditions(of directory: URL) throws -> [ListedCondition] {
        try portability(["--list-conditions", directory.path]).split(separator: "\n").map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else {
                throw ScriptRefused(arguments: ["--list-conditions", directory.path], status: 0,
                                    said: "a line that is not file, directive and condition: \(line)")
            }
            return ListedCondition(file: fields[0], directive: fields[1], text: fields[2])
        }
    }

    // MARK: - The manifest, as SwiftPM reads it (the final closing pass, finding 4)

    /// **Every target name, whatever it is spelled with.** A target called `Unsafe2` was no target to the
    /// reader — its name pattern had no digit — so it got no verdict, and the coverage check compared the
    /// manifest with a reading of itself and could not notice.
    @Test func theManifestReaderReadsATargetNameWithADigit() throws {
        let real = try String(contentsOf: Self.repository.appending(path: "Package.swift"), encoding: .utf8)
        let anchor = #".target(name: "ReviewKit"),"#
        #expect(real.contains(anchor), "premise: the manifest declares ReviewKit on one line")
        let planted = real.replacingOccurrences(
            of: anchor, with: anchor + "\n        .target(name: \"Unsafe2\", dependencies: [\"ReviewKit\"]),")
        let read = try Self.targets(in: planted)
        #expect(read.contains("Unsafe2"), "\(read)")
        #expect(try Self.dependencyMap(of: planted)["Unsafe2"] == ["ReviewKit"])
    }

    /// **The reader agrees with SwiftPM**, which evaluates the manifest: every target and every in-package
    /// dependency. What the reader cannot spell, whatever its next blind spot is, is a disagreement here —
    /// the coverage no longer rests on the reader's own reading. `dump-package` with a scratch path of its
    /// own: about 0.5 s, byte-identical run to run, and nothing of `swift test`'s `.build` to wait on.
    @Test(.timeLimit(.minutes(1))) func theManifestReaderAgreesWithSwiftPM() throws {
        let manifest = try String(contentsOf: Self.repository.appending(path: "Package.swift"), encoding: .utf8)
        let disagreements = try Self.disagreements(reading: manifest, swiftPM: Self.swiftPMTargets(of: Self.repository))
        #expect(disagreements.isEmpty, "\(disagreements)")
    }

    /// **The control: a copy of the manifest with a target the reader of the original never saw** — SwiftPM
    /// lists it, and the comparison names it.
    @Test(.timeLimit(.minutes(1))) func aTargetTheReaderMissedIsADisagreement() throws {
        let manifest = try String(contentsOf: Self.repository.appending(path: "Package.swift"), encoding: .utf8)
        let anchor = #".target(name: "ReviewKit"),"#
        let planted = manifest.replacingOccurrences(
            of: anchor, with: anchor + "\n        .target(name: \"Unsafe2\", dependencies: [\"ReviewKit\"]),")
        let scratch = TemporaryDirectory(named: "xiaolaidict-planted-manifest")
        try planted.write(to: scratch.appending("Package.swift"), atomically: true, encoding: .utf8)
        let dumped = try Self.swiftPMTargets(of: scratch.url)
        #expect(dumped["Unsafe2"] == ["ReviewKit"], "premise: SwiftPM read the planted target")
        #expect(try Self.disagreements(reading: manifest, swiftPM: dumped)
                == ["Unsafe2 is a target to SwiftPM and not to the reader"])
        #expect(try Self.disagreements(reading: planted, swiftPM: dumped).isEmpty)
    }

    /// Where the reader and SwiftPM differ: a target one has and the other does not, or different in-package
    /// dependencies. The reader's targets are the non-test ones; its dependency map has the tests too.
    static func disagreements(reading manifest: String, swiftPM: [String: Set<String>]) throws -> [String] {
        let read = try dependencyMap(of: manifest)
        var problems: [String] = []
        for target in Set(swiftPM.keys).subtracting(read.keys).sorted() {
            problems.append("\(target) is a target to SwiftPM and not to the reader")
        }
        for target in Set(read.keys).subtracting(swiftPM.keys).sorted() {
            problems.append("\(target) is a target to the reader and not to SwiftPM")
        }
        for (target, dependencies) in read.sorted(by: { $0.key < $1.key }) {
            guard let theirs = swiftPM[target], theirs != dependencies else { continue }
            problems.append("\(target) depends on \(dependencies.sorted()) to the reader and \(theirs.sorted()) to SwiftPM")
        }
        return problems
    }

    /// Every target of the package at `root` and its in-package dependencies, as `swift package dump-package`
    /// evaluates the manifest — a product of another package is not one.
    static func swiftPMTargets(of root: URL) throws -> [String: Set<String>] {
        let targets = try dumpedTargets(of: root)
        let names = Set(targets.keys)
        return targets.mapValues { target in
            let dependencies = (target["dependencies"] as? [[String: Any]] ?? []).compactMap { dependency in
                ((dependency["byName"] ?? dependency["target"]) as? [Any])?.first as? String
            }
            return Set(dependencies).intersection(names)
        }
    }

    /// Every target of the package at `root`, by name, as `swift package dump-package` writes it — with a scratch
    /// path of its own, so nothing of `swift test`'s `.build` is waited on.
    static func dumpedTargets(of root: URL) throws -> [String: [String: Any]] {
        let scratch = TemporaryDirectory(named: "xiaolaidict-dump-package")
        let arguments = ["swift", "package", "--package-path", root.path, "--scratch-path",
                         scratch.appending("build").path, "dump-package"]
        let (status, output, said) = try run("/usr/bin/xcrun", arguments, scratch: scratch)
        guard status == 0 else { throw ScriptRefused(arguments: arguments, status: status, said: said) }
        guard let dump = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let targets = dump["targets"] as? [[String: Any]] else {
            throw ScriptRefused(arguments: arguments, status: status, said: "no targets in the dump")
        }
        var byName: [String: [String: Any]] = [:]
        for target in targets {
            guard let name = target["name"] as? String else {
                throw ScriptRefused(arguments: arguments, status: status, said: "a target with no name")
            }
            byName[name] = target
        }
        return byName
    }

    // MARK: - What every target is compiled with (ADR-0052, the MemberImportVisibility addendum)

    /// The Swift settings every target of this package carries, each spelled as `dump-package` writes it: the
    /// setting's kind, then its argument.
    static let everyTargetIsCompiledWith: Set<String> = [
        "treatAllWarnings error", "enableUpcomingFeature MemberImportVisibility",
    ]

    /// **Every target builds with `MemberImportVisibility` and with warnings as errors** — asked of SwiftPM's own
    /// evaluation of the manifest rather than of its text, so a target appended after the loop that sets both, or a
    /// loop that stopped setting one, is named. Without the feature a member is visible through *any* file's import:
    /// a file that reaches a module only through its members compiles with no diagnostic at all, which neither the
    /// compiler nor the warning gate can see. 26 such file and module pairs in 24 files had collected before it was
    /// on (2026-10-08); with it on, a removed import is an error in debug, development and release builds alike.
    @Test(.timeLimit(.minutes(1))) func everyTargetIsCompiledWithMemberImportVisibilityAndWarningsAsErrors() throws {
        let unset = try Self.settingsMissing(from: Self.dumpedTargets(of: Self.repository))
        #expect(unset.isEmpty, "\(unset)")
    }

    /// **The control: a target declared after the loop, and a loop without the feature** — the first named alone,
    /// the second for every target, each in a copy of the manifest SwiftPM evaluated.
    @Test(.timeLimit(.minutes(1))) func aTargetCompiledWithoutTheFeatureIsNamed() throws {
        let manifest = try String(contentsOf: Self.repository.appending(path: "Package.swift"), encoding: .utf8)
        let feature = #", .enableUpcomingFeature("MemberImportVisibility")"#
        #expect(manifest.components(separatedBy: feature).count == 2, "premise: the loop sets the feature in one place")
        let late = TemporaryDirectory(named: "xiaolaidict-planted-late-target")
        try (manifest + "\npackage.targets.append(.target(name: \"Unsafe3\"))\n")
            .write(to: late.appending("Package.swift"), atomically: true, encoding: .utf8)
        #expect(try Self.settingsMissing(from: Self.dumpedTargets(of: late.url)) == [
            "Unsafe3 is compiled without enableUpcomingFeature MemberImportVisibility",
            "Unsafe3 is compiled without treatAllWarnings error",
        ])
        let dropped = TemporaryDirectory(named: "xiaolaidict-planted-no-feature")
        try manifest.replacingOccurrences(of: feature, with: "")
            .write(to: dropped.appending("Package.swift"), atomically: true, encoding: .utf8)
        let targets = try Self.dumpedTargets(of: dropped.url)
        #expect(targets.count > 20, "premise: SwiftPM read the planted manifest's targets")
        #expect(Self.settingsMissing(from: targets)
                == targets.keys.sorted().map { "\($0) is compiled without enableUpcomingFeature MemberImportVisibility" })
    }

    /// Each target that lacks a setting of `everyTargetIsCompiledWith`, as a sentence, in target then setting order.
    /// A setting whose shape this cannot read is not one it found, so it reads as missing rather than as present.
    static func settingsMissing(from targets: [String: [String: Any]]) -> [String] {
        targets.keys.sorted().flatMap { name -> [String] in
            let settings = (targets[name]?["settings"] as? [[String: Any]] ?? []).compactMap { setting -> String? in
                guard setting["tool"] as? String == "swift", let kind = setting["kind"] as? [String: Any],
                      kind.count == 1, let entry = kind.first,
                      let argument = (entry.value as? [String: Any])?["_0"] as? String
                else { return nil }
                return "\(entry.key) \(argument)"
            }
            return everyTargetIsCompiledWith.subtracting(settings).sorted().map { "\(name) is compiled without \($0)" }
        }
    }

    /// **A list that could not be made is never an empty one.** The script refuses a directory with no
    /// Swift in it and a file the compiler cannot read, and the refusal reaches the test as a throw that
    /// carries what the script said.
    @Test(.timeLimit(.minutes(1))) func aListTheCompilerCouldNotMakeThrows() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-unlistable")
        let empty = scratch.appending("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: CompilerList.self) { try Self.compiledImports(of: empty) }
        let broken = scratch.appending("Broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "import\n".write(to: broken.appending(path: "Broken.swift"), atomically: true, encoding: .utf8)
        #expect(throws: CompilerList.self) { try Self.compiledImports(of: broken) }
    }

    /// Every target `Package.swift` declares but the fixture target, and `ReviewKitTests`.
    static func subjects() throws -> [String] {
        try targets().filter { $0 != "XiaolaiDictTestSupport" } + ["ReviewKitTests"]
    }

    /// A test target's directory is under `Tests`, every other under `Sources` — but the fixture target,
    /// the one declaration in `Package.swift` with a `path:` of its own.
    static func sources(of target: String) -> URL {
        if target == "XiaolaiDictTestSupport" { return repository.appending(path: "Tests/Support") }
        return repository.appending(path: target.hasSuffix("Tests") ? "Tests" : "Sources").appending(path: target)
    }

    /// What a test target may bind besides its declared dependencies. Its own row, because
    /// `declaredDependenciesAndImportsAgree` skips test targets — and `ReviewKitTests` linking ReviewKit
    /// alone is the evidence that the logic runs without the Mac's modules.
    static let testTargetsMayBind: [String: Set<String>] = ["ReviewKitTests": ["Foundation", "Testing"]]

    /// `import Carbon.HIToolbox` is listed by the compiler as `Carbon`: the module, not the submodule.
    static func topLevel(_ module: String) -> String { String(module.prefix { $0 != "." }) }

    /// Every rule above, asked of one target's compiled list: its table, exactly (top-level names);
    /// its declared dependencies, exactly; and for a service, nothing it may never bind.
    static func verdict(on target: String, compiled: Set<String>) throws -> [String] {
        let ours = Set(try targets())
        var problems: [String] = []
        if compiled.isEmpty {
            problems.append("\(target): the compiler listed no import at all, and a list that found nothing "
                            + "cannot be trusted to have found the rest")
        }
        if let table = exactSets[target] ?? testTargetsMayBind[target] {
            let permitted = Set(table.map(topLevel))
            let bound = compiled.subtracting(ours)
            for module in bound.subtracting(permitted).sorted() {
                problems.append("\(target) binds \(module), which is not in its allowed set")
            }
            for module in permitted.subtracting(bound).sorted() {
                problems.append("\(target) no longer binds \(module) — drop it from the list")
            }
        }
        if let declared = try dependencyMap()[target] {
            problems += dependencyProblems(of: target, imported: compiled.intersection(ours), declared: declared)
        } else {
            problems.append("\(target) has no declaration this test could read")
        }
        if services.contains(target) {
            for module in compiled.intersection(neverInAService).sorted() {
                problems.append("\(target) binds \(module), which a service never may")
            }
        }
        // The view layer is this package's own, so the exact set above filters it out with every sibling: a
        // presentation target that declared it as well as importing it would pass every other line here.
        if presentation[target] != nil {
            for module in compiled.intersection(viewLayer).sorted() {
                problems.append("\(target) binds \(module), which a presentation target never may")
            }
        }
        // The same hole for a platform adapter, which has more siblings it never binds: the subjects it does not adapt.
        if platformAdapters[target] != nil {
            for module in compiled.intersection(viewLayer.union(adapterNeverBinds)).sorted() {
                problems.append("\(target) binds \(module), which a platform adapter never may")
            }
        }
        return problems
    }

    /// What the compiler lists `directory` importing, in every build that compiles it, with every module
    /// of this package importable and not: `Tools/portability.sh --list-imports`. **A refusal throws,
    /// carrying what the script said** — a list that could not be made is never an empty one. Its module
    /// cache goes in this call's own scratch directory, removed with it.
    static func compiledImports(of directory: URL) throws -> Set<String> {
        let scratch = TemporaryDirectory(named: "xiaolaidict-compiled-imports")
        let (status, output, said) = try run(
            repository.appending(path: "Tools/portability.sh").path,
            ["--list-imports", directory.path, "--siblings", try targets().joined(separator: ",")], scratch: scratch)
        guard status == 0 else { throw CompilerList.refused(directory: directory.path, status: status, said: said) }
        return Set(output.split(separator: "\n").map(String.init))
    }

    /// What `Tools/portability.sh` printed for `arguments`, or a throw carrying what it said.
    static func portability(_ arguments: [String]) throws -> String {
        let scratch = TemporaryDirectory(named: "xiaolaidict-portability-run")
        let (status, output, said) = try run(repository.appending(path: "Tools/portability.sh").path, arguments,
                                             scratch: scratch)
        guard status == 0 else { throw ScriptRefused(arguments: arguments, status: status, said: said) }
        return output
    }

    /// Runs `executable` with `scratch` as its `TMPDIR`: its exit status, what it printed, and what it said on
    /// standard error. **Standard output is read before waiting**: a pipe the child fills while nobody reads it
    /// never lets the child exit. Standard error goes to a file in `scratch`, which is removed with it.
    static func run(_ executable: String, _ arguments: [String],
                    scratch: TemporaryDirectory) throws -> (status: Int32, output: String, said: String) {
        let said = scratch.appending("stderr.txt")
        try Data().write(to: said)
        let errors = try FileHandle(forWritingTo: said)
        defer { try? errors.close() }
        let listed = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["TMPDIR": scratch.url.path]) { $1 }
        process.standardOutput = listed
        process.standardError = errors
        try process.run()
        let output = listed.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self),
                (try? String(contentsOf: said, encoding: .utf8)) ?? "")
    }

    /// A run of `Tools/portability.sh` or `swift package` that refused, and what it said.
    struct ScriptRefused: Error, CustomStringConvertible {
        let arguments: [String]
        let status: Int32
        let said: String

        var description: String { "\(arguments.joined(separator: " ")) exited \(status):\n\(said)" }
    }

    enum CompilerList: Error, CustomStringConvertible {
        case refused(directory: String, status: Int32, said: String)

        var description: String {
            switch self {
            case .refused(let directory, let status, let said):
                "Tools/portability.sh --list-imports \(directory) exited \(status):\n\(said)"
            }
        }
    }

    // MARK: - Reading the tree and the manifest

    /// Every `.swift` under `Sources/<target>`, with its import lines. Comments stripped by
    /// `SourceScan` for the reason it strips them: a doc comment naming `AppKit` is not an import.
    private static func imports(of target: String) throws -> [(file: String, modules: [String])] {
        try imports(under: repository.appending(path: "Sources").appending(path: target))
    }

    private static func imports(under root: URL) throws -> [(file: String, modules: [String])] {
        try SourceScan.code(under: root).map { file, code in
            (file.lastPathComponent, importedModules(inCode: code))
        }
    }

    /// The modules a line imports, in the order written. See `importedModules(inCode:)`.
    static func importedModules(in line: String) -> [String] { importedModules(inCode: line) }

    /// The modules a file imports, in the order written. Any run of attributes (`@testable`,
    /// `@_spi(…)`, …), then an optional access level, then `import`, then an optional kind — and a
    /// kind import names a declaration, so `import struct X.Y` binds `X`. A plain dotted import keeps
    /// its path, which is how `Carbon.HIToolbox` is listed above.
    ///
    /// **Read as Swift reads it, not line by line.** Comments and string contents are blanked first,
    /// since a comment is whitespace to the compiler and a string is not code; `;` ends a statement as a
    /// line break does; and whitespace inside a declaration may cross lines.
    static func importedModules(inCode code: String) -> [String] {
        let text = codeOnly(code).replacingOccurrences(of: ";", with: "\n")
        // A path component may be written in backticks — ``import `SQLite3` `` binds SQLite3 — and was
        // read as no import at all (WI-8). The compiler is the authority for every target
        // (`theCompilerHoldsEveryTargetToItsBoundary`); this is the first check, and the one that names the file.
        let statement = /^[ \t]*(?:@\w+(?:\([^)]*\))?\s*)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(struct|class|enum|protocol|typealias|func|var|let)\s+)?(`?[A-Za-z_][A-Za-z0-9_]*`?(?:\.`?[A-Za-z_][A-Za-z0-9_]*`?)*)/
            .anchorsMatchLineEndings()
        return text.matches(of: statement).map { match in
            let path = String(match.output.2).replacingOccurrences(of: "`", with: "")
            guard match.output.1 != nil, let last = path.lastIndex(of: ".") else { return path }
            return String(path[path.startIndex..<last])
        }
    }

    /// `code` with every comment replaced by a space and every string literal's contents removed, so
    /// neither can look like an import or hide one. Block comments nest, as Swift's do; a raw string
    /// ends only at a quote followed by as many `#` as opened it, and has no backslash escapes.
    static func codeOnly(_ code: String) -> String {
        let characters = Array(code)
        func starts(_ token: String, at index: Int) -> Bool {
            let token = Array(token)
            return index + token.count <= characters.count
                && Array(characters[index..<(index + token.count)]) == token
        }
        var out = "", index = 0
        while index < characters.count {
            if starts("//", at: index) {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if starts("/*", at: index) {
                var depth = 0
                repeat {
                    if starts("/*", at: index) { depth += 1; index += 2 }
                    else if starts("*/", at: index) { depth -= 1; index += 2 }
                    else { index += 1 }
                } while depth > 0 && index < characters.count
                out += " "
            } else {
                var hashes = 0
                while index + hashes < characters.count, characters[index + hashes] == "#" { hashes += 1 }
                guard index + hashes < characters.count, characters[index + hashes] == "\"" else {
                    // `#if`, `#available`, or any character that opens nothing.
                    let run = max(hashes, 1)
                    out += String(characters[index..<(index + run)])
                    index += run
                    continue
                }
                let quote = starts("\"\"\"", at: index + hashes) ? "\"\"\"" : "\""
                let close = quote + String(repeating: "#", count: hashes)
                index += hashes + quote.count
                while index < characters.count, !starts(close, at: index) {
                    index += characters[index] == "\\" && hashes == 0 ? 2 : 1
                }
                index += close.count
                out += "\"\""
            }
        }
        return out
    }

    /// `file:line` for every line under `root` that opens or continues a conditional block — at the
    /// start of the line or of any statement on it: ``import Foundation; #if canImport(AppKit)`` parses,
    /// and a line-start scan read it as no directive (WI-8). The parser is the authority for ReviewKit
    /// (`Tools/portability.sh`); this is the fast first check.
    private static func conditionalCompilation(under root: URL) throws -> [String] {
        try SourceScan.code(under: root).flatMap { file, code in
            code.components(separatedBy: "\n").enumerated().compactMap { index, line -> String? in
                let statements = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard statements.contains(where: { text in
                    ["#if", "#elseif", "#else"].contains(where: { text.hasPrefix($0) })
                }) else { return nil }
                return "\(file.lastPathComponent):\(index + 1)"
            }
        }.sorted()
    }

    /// The words after `<rule>:` on the line that declares it, or nothing if no line does.
    private static func prerequisites(of rule: String, in makefile: String) -> [String] {
        guard let line = makefile.split(separator: "\n").first(where: { $0.hasPrefix("\(rule):") }) else { return [] }
        return line.dropFirst(rule.count + 1).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The tab-indented lines under `<rule>:`, joined.
    private static func recipe(of rule: String, in makefile: String) -> String {
        let lines = makefile.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(rule):") }) else { return "" }
        return lines[lines.index(after: start)...].prefix { $0.hasPrefix("\t") }.joined(separator: "\n")
    }

    /// The target names `Package.swift` declares.
    private static func targets() throws -> [String] {
        try targets(in: String(contentsOf: repository.appending(path: "Package.swift"), encoding: .utf8))
    }

    /// The fixture target's reader (`Manifest`), which every test that reads targets shares; the two tests above it
    /// are what hold it to SwiftPM, for all of them.
    private static func targets(in manifest: String) throws -> [String] { try Manifest.targets(in: manifest) }

    /// The in-package dependencies `Package.swift` gives each target, the tests included.
    private static func dependencyMap() throws -> [String: Set<String>] {
        try dependencyMap(of: String(contentsOf: repository.appending(path: "Package.swift"), encoding: .utf8))
    }

    private static func dependencyMap(of manifest: String) throws -> [String: Set<String>] {
        try Manifest.dependencyMap(of: manifest)
    }
}
