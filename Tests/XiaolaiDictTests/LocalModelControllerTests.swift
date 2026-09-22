import CryptoKit
import Foundation
import Testing
@testable import XiaolaiDict
@testable import XiaolaiDictCore
import XiaolaiDictTestSupport
@testable import XiaolaiDictUI

/// The local model's row, as the app drives it: read from the store, a download the reader asked for,
/// and a Not now that is remembered and never takes the download away.
@MainActor
struct LocalModelControllerTests {
    /// Serves one small file per path from memory, or fails every request.
    struct Transport: ModelFileTransport {
        let fails: Bool
        struct Offline: Error {}

        func fetch(
            _ file: ModelFile, from offset: Int64, appendingTo destination: URL,
            progress: @escaping @Sendable (Int64) -> Void
        ) async throws {
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
                    sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
            })
    }

    private static let gigabyte: UInt64 = 1_073_741_824

    private func controller(
        memory: UInt64 = 48 * gigabyte, fails: Bool = false, defaults: UserDefaults = TemporaryDefaults.suite()
    ) -> (LocalModelController, ModelStore) {
        let store = ModelStore(root: FileManager.default.temporaryDirectory
            .appending(path: "xiaolaidict-controller-\(UUID().uuidString)", directoryHint: .isDirectory))
        return (LocalModelController(
            defaults: defaults, store: store, physicalMemory: memory,
            transport: Transport(fails: fails), manifest: Self.manifest), store)
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
        controller.onInstalled = { seen.withLock { $0.append(controller.state) } }
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

    /// 9B only where the Mac holds it, and a switch leaves one model on disk, not two.
    @Test func theLargerModelIsOfferedWhereItFitsAndReplacesTheSmaller() async {
        let (roomy, store) = controller(memory: 48 * Self.gigabyte)
        roomy.startDownload(.standard)
        await settle(roomy)
        #expect(roomy.choice.larger == .large)
        roomy.startDownload(.large)
        await settle(roomy)
        #expect(roomy.state == .ready(.large))
        #expect(store.installed(Self.manifest(.standard)) == nil, "the smaller model was kept beside the larger")
        #expect(roomy.choice.larger == nil)

        let (sixteen, _) = controller(memory: 16 * Self.gigabyte)
        sixteen.startDownload(.standard)
        await settle(sixteen)
        #expect(sixteen.choice.larger == nil, "9B offered on a Mac that cannot hold it")
        sixteen.startDownload(.large)
        #expect(sixteen.state == .ready(.standard), "a size the Mac is not offered was downloaded")
    }

    /// **The next size up, not the largest.** A reader with 2B on a 16 GB Mac can move to 4B — the
    /// recommended size, which fits there — and a row written in terms of 9B alone offered them
    /// nothing at all, because 9B does not fit and was the only upgrade it knew about.
    @Test func theUpgradeOfferedIsTheNextSizeThisMacCanHold() throws {
        let (controller, store) = controller(memory: 16 * Self.gigabyte)
        try Self.install(.small, into: store)
        controller.refresh()
        #expect(controller.state == .ready(.small))
        #expect(controller.choice.larger == .standard)
    }

    /// **A model on disk this Mac cannot load is not a model it has.** One copied from a larger Mac,
    /// or left by one that had more memory, reads as ready and then fails at the service for want of
    /// memory — a failure rendering exactly as confidently as a success.
    @Test func aModelThisMacCannotLoadDoesNotReadAsReady() throws {
        let (controller, store) = controller(memory: 16 * Self.gigabyte)
        try Self.install(.large, into: store)
        controller.refresh()
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
            transport: Transport(fails: true), manifest: Self.manifest)
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

    /// **Every way the store can refuse says its own thing.** Left to the generic ending, a download
    /// refused because this Mac would not say how much disk is free reads exactly like one that lost
    /// its connection — "the download could not be completed", which names nothing the reader can act
    /// on. Measured against a foreign error, which is the only thing the generic sentence is for.
    @Test(arguments: [
        ModelDownloadError.insufficientDisk(needed: 3_000_000_000, available: 1),
        .diskCapacityUnknown(path: "/"),
        .hashMismatch(path: "model.safetensors"),
        .sizeMismatch(path: "model.safetensors", expected: 2, received: 1),
        .couldNotDiscard(path: "model.safetensors.partial", reason: "in use"),
        .incomplete(identifier: "test/model@abc"),
        .http(status: 503, path: "model.safetensors"),
        .alreadyInstalling(identifier: "test/model@abc"),
    ])
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
}
