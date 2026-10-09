import CryptoKit
import Foundation
@testable import ModelKit
import Testing
@testable import XiaolaiDict
import XiaolaiDictTestSupport
@testable import XiaolaiDictUI

/// The local model's row, as the app drives it: read from the store, a download the reader asked for,
/// and a Not now that is remembered and never takes the download away.
@MainActor
struct LocalModelControllerTests {
    /// **A probe that answers without a network.** The real one takes five seconds and reaches
    /// two hosts; a controller built without this in a test stalls and then measures the tester's
    /// internet connection. Every construction below passes one.
    struct FixedProbe: ModelHostProbe {
        var winner: ModelHost = .modelScope
        func measure(_ file: ModelFile, among candidates: [ModelHost]) async -> [ModelHostSpeed] {
            candidates.filter { file.isServed(by: $0) }
                .map { ModelHostSpeed(host: $0, bytes: $0 == winner ? 100 : 1) }
        }
    }

    /// Serves one small file per path from memory, or fails every request.
    struct Transport: ModelFileTransport {
        let fails: Bool
        /// Every host this transport was asked, so a test can say which the reader's choice
        /// actually reached — the only way to check that nothing touches Hugging Face.
        var asked: Recorder<[ModelHost]>?
        struct Offline: Error {}

        func fetch(
            _ file: ModelFile, from offset: Int64, on host: ModelHost, appendingTo destination: URL,
            progress: @escaping @Sendable (Int64) -> Void
        ) async throws {
            asked?.withLock { $0.append(host) }
            if fails { throw URLError(.notConnectedToInternet) }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.seekToEnd()
            try handle.write(contentsOf: Self.body(file.path).dropFirst(Int(offset)))
            try handle.close()
            progress(file.size - offset)
        }

        static func body(_ path: String) -> Data { Data("bytes of \(path)".utf8) }
    }

    /// Each size a two-file model of a few bytes, under its real repository and commit.
    nonisolated private static func manifest(_ size: LocalModelSize) -> ModelManifest {
        let real = size.manifest
        return ModelManifest(
            size: size, repository: real.repository, revision: real.revision,
            files: ["config.json", ModelManifest.licenceFileName].map { path in
                let body = Transport.body(path)
                return ModelFile(
                    repository: real.repository, revision: real.revision, path: path, size: Int64(body.count),
                    sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
                    // **Shaped like the real catalogue**: everything but the licence has a
                    // second host. Without that, `isServed` refuses every alternate and a test
                    // about which host is asked can only ever see the canonical one.
                    alternates: path == ModelManifest.licenceFileName
                        ? [:] : [.huggingFace: (repository: real.repository, revision: "hf-commit")])
            })
    }

    private static let gigabyte: UInt64 = 1_073_741_824

    /// The scratch directories this test made, held for as long as the test instance lives so they
    /// are removed when it ends. A local `let` would be released while the store is still in use.
    private let scratches = Recorder<[TemporaryDirectory]>([])


    private func controller(
        memory: UInt64 = 48 * gigabyte, fails: Bool = false, defaults: UserDefaults = TemporaryDefaults.suite()
    ) -> (LocalModelController, ModelStore) {
        let scratch = TemporaryDirectory(named: "xiaolaidict-controller")
        scratches.withLock { $0.append(scratch) }
        let store = ModelStore(root: scratch.url)
        return (LocalModelController(
            defaults: defaults, store: store, physicalMemory: memory,
            // Plenty free, so a test about choosing is not a test about this machine's load.
            availableMemory: { memory / 2 },
            transport: Transport(fails: fails), probe: FixedProbe(), manifest: Self.manifest), store)
    }

    private func settle(_ controller: LocalModelController) async {
        for _ in 0..<500 where controller.state.isDownloading { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aFreshMacIsNotDownloadedAndATinyOneIsNotOffered() {
        #expect(controller().0.state == .notDownloaded)
        #expect(controller(memory: 4 * Self.gigabyte).0.state == .tooLittleMemory)
    }

    /// Asked for, it downloads, and the row reads ready from the store — with the licence that came
    /// with the weights for About to name.
    @Test func aDownloadTheReaderAskedForEndsReady() async throws {
        let (controller, _) = controller()
        controller.startDownload(.standard)
        await settle(controller)
        #expect(controller.state == .ready(.standard))
        let licence = try #require(controller.licenceURL)
        #expect(licence.lastPathComponent == ModelManifest.licenceFileName)
        #expect(FileManager.default.fileExists(atPath: licence.path))
    }

    /// A download that fails says why, in words, and keeps nothing loadable.
    @Test func aFailedDownloadStopsAndSaysWhy() async {
        let (controller, store) = controller(fails: true)
        controller.startDownload(.standard)
        await settle(controller)
        guard case .stopped(let reason, let size, _) = controller.state else {
            Issue.record("a failed download ended as \(controller.state)")
            return
        }
        #expect(reason.contains("internet"))
        #expect(size == .standard, "the size that stopped was forgotten, so Resume would start another")
        #expect(store.installed(Self.manifest(.standard)) == nil)
    }

    /// The service holding the old model is ended **before** "ready" is said, so nothing asked after
    /// ready reaches the model that was there before.
    @Test func theServiceIsEndedBeforeReadyIsSaid() async {
        let (controller, _) = controller()
        let seen = Recorder<[LocalModelState]>([])
        controller.onModelChanging = {
            seen.withLock { $0.append(controller.state) }
            return Task {}
        }
        controller.startDownload(.standard)
        await settle(controller)
        #expect(controller.state == .ready(.standard))
        let during = seen.withLock { $0 }
        #expect(during.count == 1)
        #expect(during.first?.isDownloading == true, "ready was said before the old service was ended")
    }

    /// A stopped download keeps saying why when the board re-reads the store.
    @Test func aRefreshKeepsTheReasonADownloadStopped() async {
        let (controller, _) = controller(fails: true)
        controller.startDownload(.standard)
        await settle(controller)
        controller.refresh()
        await controller.pruning?.value
        guard case .stopped = controller.state else {
            Issue.record("a refresh erased why the download stopped: \(controller.state)")
            return
        }
    }

    /// A model removed from Finder while the app ran is noticed on refresh.
    @Test func aModelRemovedBehindTheAppsBackIsNoticed() async throws {
        let (controller, store) = controller()
        controller.startDownload(.standard)
        await settle(controller)
        try store.remove(Self.manifest(.standard))
        controller.refresh()
        await controller.pruning?.value
        #expect(controller.state == .notDownloaded)
    }

    /// A disk problem is not reported as a network one.
    @Test func whyADownloadStoppedNamesTheRightKindOfProblem() {
        #expect(LocalModelController.reason(CocoaError(.fileWriteNoPermission)).contains("disk"))
        #expect(LocalModelController.reason(URLError(.timedOut)).contains("connection"))
        #expect(LocalModelController.reason(CancellationError()).contains("stopped"))
        struct Unknown: Error {}
        #expect(LocalModelController.reason(Unknown()).contains("could not be completed"))
    }

    /// **Not now is remembered, and it never takes the download away.** It survives the app quitting,
    /// the download stays one click away, and asking for it clears the Not now.
    @Test func notNowIsRememberedAndTheDownloadStaysOffered() async {
        let defaults = TemporaryDefaults.suite()
        let (first, _) = controller(defaults: defaults)
        first.decline()
        let (relaunched, _) = controller(defaults: defaults)
        #expect(relaunched.declined)
        #expect(relaunched.choice.canDownload, "Not now took the download away")

        relaunched.startDownload(.standard)
        #expect(!relaunched.declined)
        #expect(!LocalModelDeclineStore(defaults: defaults).hasDeclined())
        await settle(relaunched)
    }

    /// **An upgrade is not the state of having no model.** While 9B downloads, the 4B already
    /// installed goes on answering — and a board that called that row "needed" would be asking the
    /// reader for something they already have.
    @Test func anUpgradeSaysWhichModelIsStillAnswering() async {
        let (controller, _) = controller()
        controller.startDownload(.standard)
        await settle(controller)
        controller.startDownload(.large)
        guard case .downloading(_, let size, let replacing) = controller.state else {
            Issue.record("the upgrade did not start: \(controller.state)")
            return
        }
        #expect(size == .large)
        #expect(replacing == .standard)
        #expect(controller.state.answering == .standard)
        await settle(controller)
        #expect(controller.state.answering == .large)
    }

    /// 9B only where the Mac holds it — and **the smaller model stays**, so the reader can switch
    /// back without three gigabytes and an hour, and so a Mac too busy for 9B still has something
    /// that answers. Measured on a 32 GB Mac: 9B wants 6,633 MB and 4,729 MB was free, and the 4B
    /// that would have answered had been deleted to make room for it — ADR-0041.
    @Test func theLargerModelIsOfferedWhereItFitsAndTheSmallerIsKept() async {
        let (roomy, store) = controller(memory: 48 * Self.gigabyte)
        roomy.startDownload(.standard)
        await settle(roomy)
        #expect(roomy.choice.larger == .large)
        roomy.startDownload(.large)
        await settle(roomy)
        #expect(roomy.state == .ready(.large))
        #expect(store.installed(Self.manifest(.standard)) != nil,
                "the model the reader was using was deleted to make room")
        #expect(store.installed(Self.manifest(.large)) != nil)
        #expect(roomy.choice.larger == nil)

        let (sixteen, _) = controller(memory: 16 * Self.gigabyte)
        sixteen.startDownload(.standard)
        await settle(sixteen)
        #expect(sixteen.choice.larger == nil, "9B offered on a Mac that cannot hold it")
        sixteen.startDownload(.large)
        #expect(sixteen.state == .ready(.standard), "a size the Mac is not offered was downloaded")
    }

    /// **A model already on disk is found, and this is the positive control for the test below it.**
    /// That one installs a model this Mac cannot load and asserts `.notDownloaded` — an answer a
    /// broken `install` or a `refresh` that never read the store would give just as readily. Without
    /// this pair, "the model was rejected" and "no model was ever seen" are the same green.
    ///
    /// **It used to be `theUpgradeOfferedIsTheNextSizeThisMacCanHold`**, installing 2B on a 16 GB
    /// Mac to prove the upgrade offered was 4B and not 9B. With 2B gone there are two sizes, so
    /// `min` over what is bigger and `max` over it cannot disagree, and no test can tell them
    /// apart — see `LocalModelChoice.larger`, which keeps the `min` and says so.
    @Test func aModelAlreadyOnDiskIsFoundAndItsUpgradeOffered() async throws {
        let (controller, store) = controller(memory: 32 * Self.gigabyte)
        try Self.install(.standard, into: store)
        controller.refresh()
        await controller.pruning?.value
        #expect(controller.state == .ready(.standard))
        #expect(controller.choice.larger == .large)
    }

    /// **A model on disk this Mac cannot load is not a model it has.** One copied from a larger Mac,
    /// or left by one that had more memory, reads as ready and then fails at the service for want of
    /// memory — a failure rendering exactly as confidently as a success.
    @Test func aModelThisMacCannotLoadDoesNotReadAsReady() async throws {
        let (controller, store) = controller(memory: 16 * Self.gigabyte)
        try Self.install(.large, into: store)
        controller.refresh()
        await controller.pruning?.value
        #expect(controller.state == .notDownloaded)
        #expect(controller.licenceURL == nil)
    }

    /// **A stopped upgrade stops naming a model that has gone.** The message says why the download
    /// stopped and what is still answering; the reader can delete that model while the message
    /// stands, and a board that goes on naming it reports a working app with nothing installed.
    @Test func aStoppedUpgradeStopsNamingAModelThatWasDeleted() async throws {
        let (installer, store) = controller()
        installer.startDownload(.standard)
        await settle(installer)
        // A second controller over the same store, whose network fails: its upgrade stops, and the
        // row keeps the reason while 4B goes on answering.
        let upgrade = LocalModelController(
            defaults: TemporaryDefaults.suite(), store: store, physicalMemory: 48 * Self.gigabyte,
            transport: Transport(fails: true, asked: nil), probe: FixedProbe(),
            manifest: Self.manifest)
        upgrade.startDownload(.large)
        await settle(upgrade)
        guard case .stopped(let reason, let size, let replacing) = upgrade.state else {
            Issue.record("the failed upgrade did not stop: \(upgrade.state)")
            return
        }
        #expect(size == .large)
        #expect(replacing == .standard)
        try store.remove(Self.manifest(.standard))
        upgrade.refresh()
        #expect(upgrade.state == .stopped(reason: reason, size: size, replacing: nil))
    }

    /// **A pin bump installs beside the old weights, not over them.** The directory is named for the
    /// revision, so nothing the app knows names the old one again — and three gigabytes stay on disk
    /// for a model that will never be loaded.
    @Test func aModelLeftByAnOlderPinIsRemoved() async throws {
        let (controller, store) = controller()
        let old = Self.manifest(.standard)
        let stale = ModelManifest(
            size: .standard, repository: old.repository, revision: "0000000000000000000000000000000000000000",
            files: old.files.map {
                ModelFile(repository: $0.repository, revision: "0000000000000000000000000000000000000000",
                          path: $0.path, size: $0.size, sha256: $0.sha256)
            })
        try Self.write(stale, into: store)
        #expect(store.installed(stale) != nil)
        controller.startDownload(.standard)
        await settle(controller)
        #expect(controller.state == .ready(.standard))
        #expect(store.installed(stale) == nil, "the older pin's weights were kept beside the new ones")
    }

    /// **The reader's choice is what gets asked**, and a probe is the only thing that may decide
    /// otherwise. A fresh preferences domain resolves to `fastest`, which measures; naming
    /// ModelScope means nothing reaches Hugging Face, not even to look.
    @Test(arguments: [
        (ModelSource?.none, "an empty preferences domain"),
        (.fastest, "fastest, with a probe that answers ModelScope"),
        (.modelScope, "ModelScope, named"),
    ])
    func achoiceOfModelScopeNeverReachesHuggingFace(choice: ModelSource?, why: String) async throws {
        let defaults = TemporaryDefaults.suite()
        if let choice { ModelSourceStore(defaults: defaults).save(choice) }
        let scratch = TemporaryDirectory(named: "xiaolaidict-source")
        let store = ModelStore(root: scratch.url)
        let asked = Recorder<[ModelHost]>([])
        let controller = LocalModelController(
            defaults: defaults, store: store, physicalMemory: 64 * 1_073_741_824,
            transport: Transport(fails: false, asked: asked),
            // Answers the canonical host, as a probe from inside China would.
            probe: FixedProbe(),
            manifest: Self.manifest)

        controller.startDownload(.standard)
        await settle(controller)
        #expect(Set(asked.withLock { $0 }) == [.modelScope], "\(why): asked a host nobody chose")
        _ = scratch
    }

    /// And naming Hugging Face does reach it — or the setting is decoration.
    @Test func achoiceOfHuggingFaceReachesIt() async throws {
        let defaults = TemporaryDefaults.suite()
        ModelSourceStore(defaults: defaults).save(.huggingFace)
        let scratch = TemporaryDirectory(named: "xiaolaidict-source-hf")
        let store = ModelStore(root: scratch.url)
        let asked = Recorder<[ModelHost]>([])
        let controller = LocalModelController(
            defaults: defaults, store: store, physicalMemory: 64 * 1_073_741_824,
            transport: Transport(fails: false, asked: asked),
            probe: FixedProbe(), manifest: Self.manifest)

        controller.startDownload(.standard)
        await settle(controller)
        #expect(asked.withLock { $0 }.contains(.huggingFace), "the choice reached nothing")
        _ = scratch
    }

    /// **The picker is wired, not decoration.** A control that sets a value nothing reads is the
    /// defect this project keeps finding: the choice must survive to the next download, and it
    /// must survive a relaunch.
    @Test func choosingAsourceIsSavedAndIsWhatTheNextDownloadUses() async throws {
        let defaults = TemporaryDefaults.suite()
        let scratch = TemporaryDirectory(named: "xiaolaidict-choose")
        let store = ModelStore(root: scratch.url)
        let asked = Recorder<[ModelHost]>([])
        let controller = LocalModelController(
            defaults: defaults, store: store, physicalMemory: 64 * 1_073_741_824,
            transport: Transport(fails: false, asked: asked),
            probe: FixedProbe(), manifest: Self.manifest)
        #expect(controller.choice.source == .fastest, "the default is not what is offered")

        controller.choice.chooseSource(.huggingFace)
        #expect(controller.choice.source == .huggingFace, "the picker would not show its own change")
        // Saved, so it is still the choice after a relaunch.
        #expect(ModelSourceStore(defaults: defaults).load() == .huggingFace)

        controller.startDownload(.standard)
        await settle(controller)
        #expect(asked.withLock { $0 }.contains(.huggingFace), "the choice reached no download")
        _ = scratch
    }

    /// **A restarted file must be visible, and a stale reading must not be.** A host that
    /// ignores the range truncates what was on disk; dropping every reading below the one on
    /// screen kept the bar at 80% through a re-download of gigabytes. Ordering by *when* a
    /// reading was taken separates that from a callback that merely arrived late — and this is
    /// the rule itself, which is the only place both halves can be asked at once.
    @Test func arestartIsShownAndAlateReadingIsNot() {
        let order = ProgressOrder()
        let first = order.next(), second = order.next(), third = order.next()

        #expect(order.isNewest(second), "a reading in order was refused")
        #expect(!order.isNewest(first), "a reading taken earlier landed later and was accepted")
        #expect(order.isNewest(third))
        #expect(!order.isNewest(third), "the same reading was accepted twice")
    }

    /// The point of the ticket: **nothing here looks at byte counts**, so a count that falls —
    /// which is what a truncation is — is published like any other.
    @Test func orderingSaysNothingAboutHowLargeAreadingIs() {
        let order = ProgressOrder()
        for _ in 0..<5 { #expect(order.isNewest(order.next())) }
    }

    /// **A reader with two models can switch between them, and switching keeps both.** This is
    /// the whole point: before, the larger download deleted the smaller, so "switching" meant
    /// three gigabytes and an hour — ADR-0041.
    @Test func areaderCanSwitchBetweenTheModelsTheyHave() async {
        let (controller, store) = controller(memory: 48 * Self.gigabyte)
        controller.startDownload(.standard)
        await settle(controller)
        controller.startDownload(.large)
        await settle(controller)
        #expect(controller.installedSizes == [.standard, .large], "both models should be on disk")

        controller.choose(.standard)
        #expect(controller.wanted == .standard)
        #expect(controller.answeringChoice.answering == .standard, "the choice did not reach the answer")
        controller.choose(.large)
        #expect(controller.answeringChoice.answering == .large)
        // Neither switch cost a download.
        #expect(store.installed(Self.manifest(.standard)) != nil)
        #expect(store.installed(Self.manifest(.large)) != nil)
    }

    /// **The switch the board draws is the controller's, not a copy of it.** A control that
    /// lists models nothing can choose, or whose buttons reach nothing, is the defect this
    /// project keeps finding — so the board's own handles are exercised here.
    @Test func theboardsSwitchReachesTheController() async {
        let (controller, store) = controller(memory: 48 * Self.gigabyte)
        controller.startDownload(.standard)
        await settle(controller)
        controller.startDownload(.large)
        await settle(controller)

        #expect(controller.choice.onDisk.map(\.size) == [.standard, .large])
        #expect(controller.choice.onDisk.allSatisfy { $0.bytes > 0 }, "a row with no size to weigh")
        controller.choice.choose(.standard)
        #expect(controller.choice.chosen == .standard, "the board's own switch reached nothing")
        #expect(controller.choice.answering.answering == .standard)

        controller.choice.removeModel(.standard)
        for _ in 0..<200 where store.installed(Self.manifest(.standard)) != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.installed(Self.manifest(.standard)) == nil, "the board's Remove reached nothing")
    }

    /// **The case the whole change exists for**, end to end: the reader chose 9B, the Mac is too
    /// busy to load it, and the 4B they still have answers — named as standing in, so the card
    /// cannot read as the answer they asked for. Before, the 4B had been deleted and there was
    /// nothing at all.
    @Test func abusyMacAnswersWithTheSmallerModelAndSaysSo() async {
        let scratch = TemporaryDirectory(named: "xiaolaidict-standin")
        scratches.withLock { $0.append(scratch) }
        let store = ModelStore(root: scratch.url)
        // 32 GB, and the 4,729 MB that was actually free when this was measured.
        let free: UInt64 = 4_729 * 1_048_576
        let controller = LocalModelController(
            defaults: TemporaryDefaults.suite(), store: store,
            physicalMemory: 32 * Self.gigabyte, availableMemory: { free },
            transport: Transport(fails: false, asked: nil), probe: FixedProbe(),
            manifest: Self.manifest)
        controller.startDownload(.standard)
        await settle(controller)
        controller.startDownload(.large)
        await settle(controller)
        controller.choose(.large)

        let choice = controller.answeringChoice
        #expect(choice == .standingIn(.standard, forWanted: .large))
        #expect(choice.answering == .standard, "a busy Mac had nothing to answer with")
        #expect(choice.isStandingIn, "a 4B answer would have read as the 9B the reader chose")
        #expect(controller.wanted == .large, "the choice was thrown away because it did not fit today")
    }

    /// **Removing is the reader's, and it forgets the choice with it.** A chosen model that is
    /// no longer there would otherwise leave every answer standing in for a model nobody has.
    @Test func removingThechosenModelForgetsTheChoice() async {
        let (controller, store) = controller(memory: 48 * Self.gigabyte)
        controller.startDownload(.standard)
        await settle(controller)
        controller.startDownload(.large)
        await settle(controller)
        controller.choose(.large)

        await controller.remove(.large)
        for _ in 0..<200 where store.installed(Self.manifest(.large)) != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.installed(Self.manifest(.large)) == nil, "the model was not removed")
        #expect(controller.wanted == nil, "a choice was kept for a model that is gone")
        #expect(store.installed(Self.manifest(.standard)) != nil, "removing one took the other")
    }

    /// **A failing URL must not reach the log.** The weights come through a CDN redirect whose
    /// query carries a signature, and `String(describing:)` on a `URLError` puts the whole
    /// failing URL in — measured — into a line marked `.public`. What is wanted for diagnosis is
    /// which error it was, not where it was.
    @Test func adownloadFailureIsLoggedWithoutItsUrl() throws {
        let signed = "https://cdn.example.invalid/model.safetensors?sig=SENTINELTOKEN&exp=1"
        // `NSURLErrorFailingURLErrorKey`, not the string key it deprecated: the key is what Foundation
        // itself attaches, and a test pinning a leak has to carry the shape the leak arrives in.
        let error = URLError(.timedOut,
                             userInfo: [NSURLErrorFailingURLErrorKey: try #require(URL(string: signed))])
        // The premise: this is a real leak, not a hypothetical one.
        #expect(String(describing: error).contains("SENTINELTOKEN"),
                "the premise has changed — String(describing:) no longer carries the URL")

        let logged = LocalModelController.logDescription(error)
        #expect(!logged.contains("SENTINELTOKEN"), "the signature reached the log")
        #expect(!logged.contains("cdn.example.invalid"), "the URL reached the log")
        #expect(!logged.isEmpty && logged.contains("-1001"), "nothing was left to diagnose with")
    }

    /// **Both directions, mechanically: nothing on the download path prints a raw error.**
    /// The rule was written for the controller's log, and the day after, the same leak was found
    /// in the model instrument's JSON — one defect in two places. A scan is what stops a third.
    @Test func nothingOnTheDownloadPathPrintsArawError() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Every file that can hold a download failure: the controller, the instrument that
        // reports on it, and the store the failures come from.
        let onThePath = [
            "Sources/XiaolaiDict/LocalModelController.swift",
            "Sources/XiaolaiDict/ModelReport.swift",
            "Sources/XiaolaiDict/LocalModelCoordinator.swift",
        ]
        for path in onThePath {
            let url = repository.appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "\(path) has moved and this scan stopped covering it")
            let source = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                // The two spellings that put a whole error into text.
                let raw = line.contains("String(describing: error)") || line.contains("\\(error)")
                #expect(!raw, "\(path):\(number + 1) prints a raw error, which carries a URL: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// The store's own refusals stay legible — they carry a file name, never a URL.
    @Test(arguments: ModelDownloadError.everyKind)
    func astoreRefusalIsStillLegibleInTheLog(error: ModelDownloadError) {
        let logged = LocalModelController.logDescription(error)
        #expect(!logged.isEmpty)
        #expect(!logged.contains("https://"), "a refusal put a URL in the log: \(logged)")
    }

    /// **Every way the store can refuse says its own thing.** Left to the generic ending, a download
    /// refused because this Mac would not say how much disk is free reads exactly like one that lost
    /// its connection — "the download could not be completed", which names nothing the reader can act
    /// on. Measured against a foreign error, which is the only thing the generic sentence is for.
    @Test(arguments: ModelDownloadError.everyKind)
    func everyDownloadFailureSaysItsOwnThing(error: ModelDownloadError) {
        struct Foreign: Error {}
        let generic = LocalModelController.reason(Foreign())
        let said = LocalModelController.reason(error)
        #expect(!said.isEmpty)
        #expect(said != generic, "\(error) fell through to the generic message")
    }

    /// Installs a size as the downloader would leave it.
    private static func install(_ size: LocalModelSize, into store: ModelStore) throws {
        try write(manifest(size), into: store)
    }

    private static func write(_ manifest: ModelManifest, into store: ModelStore) throws {
        let directory = store.directory(for: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in manifest.files {
            try Transport.body(file.path).write(to: directory.appending(path: file.path))
        }
        try ModelStore.markerText(for: manifest).write(
            to: directory.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
    }

    /// **One model on this Mac is still the reader's to remove**, though it is no switch: the picker needs two, Remove
    /// needs one. Before, both were behind two, so a single model's gigabytes could not be given back from the app.
    @Test func aSingleModelCanBeRemovedThoughThereIsNothingToSwitchTo() async {
        let (controller, _) = controller(memory: 48 * Self.gigabyte)
        controller.startDownload(.standard)
        await settle(controller)
        #expect(controller.choice.onDisk.map(\.size) == [.standard])
        #expect(controller.choice.offersRemoval, "a lone model could not be removed")
        #expect(!controller.choice.offersSwitch)
        controller.startDownload(.large)
        await settle(controller)
        #expect(controller.choice.offersRemoval && controller.choice.offersSwitch)
    }

    /// **The switch can show the choice "none in particular"** — the largest that fits — which is what a reader who
    /// never chose has: a radio group whose selection is in none of its options shows nothing chosen at all.
    @Test func theSwitchListsAnAutomaticChoiceSoNoChoiceIsShown() async {
        let (controller, _) = controller(memory: 48 * Self.gigabyte)
        controller.startDownload(.standard)
        await settle(controller)
        controller.startDownload(.large)
        await settle(controller)
        let choice = controller.choice
        #expect(choice.chosen == nil)
        #expect(choice.switchOptions == [nil, .standard, .large])
        #expect(choice.switchOptions.contains(choice.chosen), "the reader's choice is not among the options")
    }

    /// **Choosing another model ends the service holding the one before** — a service keeps the model it loaded, so
    /// without this the model chosen answered only once the service idled out ten minutes later.
    @Test func choosingAnotherModelEndsTheServiceHoldingTheOldOne() async {
        let (controller, _) = controller(memory: 48 * Self.gigabyte)
        controller.startDownload(.standard)
        await settle(controller)
        controller.startDownload(.large)
        await settle(controller)
        let changes = Recorder(0)
        controller.onModelChanging = {
            changes.withLock { $0 += 1 }
            return Task {}
        }
        controller.choose(.standard)
        #expect(changes.withLock { $0 } == 1, "the choice left the old model's service answering")
        controller.choose(.standard)
        #expect(changes.withLock { $0 } == 1, "choosing what was already chosen ended the service again")
    }

    /// **A model is removed once the service that may hold it has gone, and the row reads the store after the files
    /// are**: before, the deletion ran detached while the row was re-read at once — still listing the model — and the
    /// service went on answering from the model being removed.
    @Test func aModelIsRemovedAfterItsServiceAndTheRowSeesItGone() async {
        let (controller, store) = controller(memory: 48 * Self.gigabyte)
        controller.startDownload(.standard)
        await settle(controller)
        controller.startDownload(.large)
        await settle(controller)
        // The first ending is the one before the removal; the row's re-read after it ends the service once more,
        // for one a question may have started on the model in between.
        let onDiskWhenEnded = Recorder<Bool?>(nil)
        controller.onModelChanging = {
            onDiskWhenEnded.withLock { if $0 == nil { $0 = store.installed(Self.manifest(.large)) != nil } }
            return Task {}
        }
        await controller.remove(.large)
        #expect(onDiskWhenEnded.withLock { $0 } == true, "the service was not ended before the model was removed")
        #expect(controller.choice.onDisk.map(\.size) == [.standard], "the row was read before the model was gone")
        #expect(controller.removalFailed == nil)
    }

    /// **A removal that failed is said, never swallowed** — and the model is still listed, because it is still there.
    @Test func aModelThatCouldNotBeRemovedIsSaid() async throws {
        let (controller, store) = controller(memory: 48 * Self.gigabyte)
        controller.startDownload(.standard)
        await settle(controller)
        // Its files cannot be taken out of it, so the removal fails at the first and leaves the model whole.
        let directory = try #require(store.installed(Self.manifest(.standard)))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        await controller.remove(.standard)
        #expect(controller.removalFailed == .standard, "a removal that failed was not said")
        #expect(controller.choice.removalFailed == .standard, "the row was not told")
        #expect(controller.choice.onDisk.map(\.size) == [.standard])
    }

    /// **A file that restarts is shown restarting**, through the controller's own publishing: a host that ignores the
    /// range truncates what arrived, and the bar has to go back with it. Before, the throttle took only readings that
    /// had grown, and the bar sat at its old figure through the whole re-download.
    @Test func aRestartedFileIsShownGoingBack() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-controller")
        scratches.withLock { $0.append(scratch) }
        let restarted = TestHold()
        let free = 24 * Self.gigabyte
        let controller = LocalModelController(
            defaults: TemporaryDefaults.suite(), store: ModelStore(root: scratch.url),
            physicalMemory: 48 * Self.gigabyte, availableMemory: { free },
            transport: RestartingTransport(hold: restarted), probe: FixedProbe(), manifest: Self.manifest)
        controller.startDownload(.standard)
        func received() -> Int64? {
            if case .downloading(let progress, _, _) = controller.state { return progress.received }
            return nil
        }
        for _ in 0..<500 where received() != RestartingTransport.before { try await Task.sleep(for: .milliseconds(5)) }
        #expect(received() == RestartingTransport.before, "the premise: the first reading was shown")
        restarted.release()
        for _ in 0..<500 where received() != RestartingTransport.after { try await Task.sleep(for: .milliseconds(5)) }
        #expect(received() == RestartingTransport.after, "the restart was not shown")
        restarted.finish()
        controller.cancelDownload()
    }

    /// Reports one file's bytes arriving, then — once the test says — a restart to fewer, then waits until it is let go.
    struct RestartingTransport: ModelFileTransport {
        static let before: Int64 = 12
        static let after: Int64 = 3
        let hold: TestHold

        func fetch(
            _ file: ModelFile, from offset: Int64, on host: ModelHost, appendingTo destination: URL,
            progress: @escaping @Sendable (Int64) -> Void
        ) async throws {
            progress(Self.before)
            await hold.waitForRelease()
            progress(Self.after)
            await hold.waitForFinish()
            throw CancellationError()
        }
    }
}

/// Two points a transport waits at, each opened once by the test.
final class TestHold: Sendable {
    private let state = Recorder<(released: Bool, finished: Bool)>((false, false))

    func release() { state.withLock { $0.released = true } }
    func finish() { state.withLock { $0.finished = true } }

    func waitForRelease() async {
        for _ in 0..<2_000 where !state.withLock({ $0.released }) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func waitForFinish() async {
        for _ in 0..<2_000 where !state.withLock({ $0.finished }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
