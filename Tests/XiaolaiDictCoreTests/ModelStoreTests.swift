import CryptoKit
import Foundation
import XiaolaiDictTestSupport
import Testing
@testable import XiaolaiDictCore

/// The model's download: resumable, checked against the listed hash, moved into place whole, and
/// refused up front where the disk cannot hold it. **A partial model is never loadable** — that is
/// the rule every test here serves.
struct ModelStoreTests {
    /// Serves files from memory, and can be told to drop the connection part-way through one.
    final class MemoryTransport: ModelFileTransport, @unchecked Sendable {
        let bodies: [String: Data]
        /// Bytes of `path` to send before failing, once.
        let interruptions = Recorder<[String: Int]>([:])
        /// Paths the host restarts from zero, as one ignoring a range request does.
        let restarts = Recorder<Set<String>>([])
        /// Every request, as (path, offset) — what a resume actually asked for.
        let requests = Recorder<[(String, Int64)]>([])

        init(_ bodies: [String: Data]) { self.bodies = bodies }

        struct Dropped: Error {}

        func fetch(
            _ file: ModelFile, from offset: Int64, appendingTo destination: URL,
            progress: @escaping @Sendable (Int64) -> Void
        ) async throws {
            requests.withLock { $0.append((file.path, offset)) }
            let body = bodies[file.path] ?? Data()
            // A host that ignores the range sends the whole file, and what was on disk is discarded.
            var from = offset
            if restarts.withLock({ $0.remove(file.path) }) != nil {
                from = 0
                try Data().write(to: destination)
            }
            var slice = body.dropFirst(Int(from))
            let cut = interruptions.withLock { $0.removeValue(forKey: file.path) }
            if let cut { slice = slice.prefix(cut) }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.seekToEnd()
            try handle.write(contentsOf: slice)
            try handle.close()
            progress(from + Int64(slice.count))
            if cut != nil { throw Dropped() }
        }
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A two-file model whose listing matches `bodies` unless told otherwise.
    private static func manifest(_ bodies: [String: Data], listedAs listed: [String: Data]? = nil) -> ModelManifest {
        let files = bodies.keys.sorted().map { path in
            let body = (listed ?? bodies)[path]!
            return ModelFile(repository: "test/model", revision: "abc", path: path,
                             size: Int64(body.count), sha256: sha(body))
        }
        return ModelManifest(size: .standard, repository: "test/model", revision: "abc", files: files)
    }

    private static let bodies: [String: Data] = [
        "config.json": Data(#"{"model_type":"qwen3_5"}"#.utf8),
        "model.safetensors": Data((0..<100_000).map { UInt8($0 % 251) }),
    ]

    private func store() throws -> ModelStore {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "xiaolaidict-models-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ModelStore(root: root)
    }

    @Test func aCompleteDownloadIsInstalledAndLoadable() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let directory = try await ModelDownloader(
            store: store, transport: MemoryTransport(Self.bodies), freeDisk: { _ in .max }
        ).install(manifest)
        #expect(store.installed(manifest) == directory)
        for (path, body) in Self.bodies {
            #expect(try Data(contentsOf: directory.appending(path: path)) == body)
        }
    }

    /// The drop comes 40,000 bytes into the weights. The retry asks for **byte 40,000 onwards**, and
    /// the file that results is the whole file — not a restart, and not a doubled front.
    @Test func anInterruptedDownloadResumesFromWhereItStopped() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let transport = MemoryTransport(Self.bodies)
        transport.interruptions.withLock { $0["model.safetensors"] = 40_000 }
        let downloader = ModelDownloader(store: store, transport: transport, freeDisk: { _ in .max })

        await #expect(throws: MemoryTransport.Dropped.self) { try await downloader.install(manifest) }
        #expect(store.installed(manifest) == nil, "half a model was loadable")

        let directory = try await downloader.install(manifest)
        let asked = transport.requests.withLock { $0.filter { $0.0 == "model.safetensors" }.map(\.1) }
        #expect(asked == [0, 40_000])
        #expect(try Data(contentsOf: directory.appending(path: "model.safetensors")) == Self.bodies["model.safetensors"])
        // The config finished on the first attempt and is not fetched again.
        #expect(transport.requests.withLock { $0.filter { $0.0 == "config.json" }.count } == 1)
    }

    /// Bytes that are not the pinned file are refused, deleted — so a retry starts clean rather than
    /// resuming onto them — and nothing is installed.
    @Test func aFileWithTheWrongHashIsRefused() async throws {
        let store = try store()
        var tampered = Self.bodies
        tampered["model.safetensors"]![500] ^= 0xFF
        let manifest = Self.manifest(Self.bodies)
        let downloader = ModelDownloader(store: store, transport: MemoryTransport(tampered), freeDisk: { _ in .max })

        await #expect(throws: ModelDownloadError.hashMismatch(path: "model.safetensors")) {
            try await downloader.install(manifest)
        }
        #expect(store.installed(manifest) == nil)
        let partial = store.stagingDirectory(for: manifest).appending(path: "model.safetensors.partial")
        #expect(!FileManager.default.fileExists(atPath: partial.path), "the bad bytes were kept to resume onto")
    }

    /// Every file of a model sitting in staging — the whole of it, even — is still not loadable.
    /// Only the move into place makes it so.
    @Test func aStagingDirectoryIsNeverLoaded() throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let staging = store.stagingDirectory(for: manifest)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (path, body) in Self.bodies { try body.write(to: staging.appending(path: path)) }
        try ModelStore.markerText(for: manifest).write(
            to: staging.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
        #expect(store.installed(manifest) == nil)
        #expect(store.installedSizes().isEmpty)
    }

    /// The model's own directory without the marker, or with a file cut short, is not installed.
    @Test func aDirectoryWithoutItsMarkerOrWithAShortFileIsNotInstalled() throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let directory = store.directory(for: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, body) in Self.bodies { try body.write(to: directory.appending(path: path)) }
        #expect(store.installed(manifest) == nil, "unmarked")

        try ModelStore.markerText(for: manifest).write(
            to: directory.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
        #expect(store.installed(manifest) == directory)
        try Data(Self.bodies["model.safetensors"]!.prefix(10)).write(to: directory.appending(path: "model.safetensors"))
        #expect(store.installed(manifest) == nil, "a truncated file was loadable")
    }

    /// Checked before a byte is fetched: a download that would not fit never starts.
    @Test func tooLittleDiskIsRefusedBeforeAnythingIsFetched() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let transport = MemoryTransport(Self.bodies)
        let downloader = ModelDownloader(store: store, transport: transport, freeDisk: { _ in 1_000 })
        await #expect(throws: ModelDownloadError.self) { try await downloader.install(manifest) }
        #expect(transport.requests.withLock { $0.isEmpty })
    }

    /// What already arrived is not counted against the disk: the check is for what is still to come.
    @Test func whatAlreadyArrivedIsNotCountedAgainstTheDisk() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let transport = MemoryTransport(Self.bodies)
        transport.interruptions.withLock { $0["model.safetensors"] = 90_000 }
        let roomy = ModelDownloader(store: store, transport: transport, freeDisk: { _ in .max })
        await #expect(throws: MemoryTransport.Dropped.self) { try await roomy.install(manifest) }

        // 10,000 bytes still to come, plus the margin: exactly enough.
        let exact = 10_000 + ModelDownloader.diskMargin
        let tight = ModelDownloader(store: store, transport: transport, freeDisk: { _ in exact })
        try await tight.install(manifest)
        #expect(store.installed(manifest) != nil)
    }

    @Test func anInstalledModelIsNotFetchedAgain() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let transport = MemoryTransport(Self.bodies)
        let downloader = ModelDownloader(store: store, transport: transport, freeDisk: { _ in .max })
        try await downloader.install(manifest)
        let first = transport.requests.withLock { $0.count }
        try await downloader.install(manifest)
        #expect(transport.requests.withLock { $0.count } == first)
    }

    /// Progress ends at the whole model, and never runs backwards.
    @Test func progressRisesToTheWholeModel() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let seen = Recorder<[Int64]>([])
        try await ModelDownloader(store: store, transport: MemoryTransport(Self.bodies), freeDisk: { _ in .max })
            .install(manifest) { progress in seen.withLock { $0.append(progress.received) } }
        let received = seen.withLock { $0 }
        #expect(received.last == manifest.totalBytes)
        #expect(received == received.sorted())
    }

    /// **A staged file is trusted for its bytes, not its name.** A stale or corrupted file of the
    /// right size would otherwise be kept — the final check reads sizes — and shipped as the model.
    @Test func aStagedFileThatIsNotThePinnedOneIsFetchedAgain() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let staging = store.stagingDirectory(for: manifest)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var wrong = Self.bodies["model.safetensors"]!
        wrong[0] ^= 0xFF  // the same length, different bytes
        try wrong.write(to: staging.appending(path: "model.safetensors"))

        let transport = MemoryTransport(Self.bodies)
        let directory = try await ModelDownloader(store: store, transport: transport, freeDisk: { _ in .max })
            .install(manifest)
        #expect(transport.requests.withLock { $0.contains { $0.0 == "model.safetensors" } }, "the wrong bytes were kept")
        #expect(try Data(contentsOf: directory.appending(path: "model.safetensors")) == Self.bodies["model.safetensors"])
    }

    /// A partial longer than the file cannot be a front to resume from — and counting it as a whole
    /// file is what once let it skip the disk check entirely.
    @Test func anOversizedPartialIsDiscardedBeforeAnythingIsCounted() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let staging = store.stagingDirectory(for: manifest)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 200_000).write(to: staging.appending(path: "model.safetensors.partial"))

        let transport = MemoryTransport(Self.bodies)
        // Room for the whole file and the margin, but not for a second copy of it.
        let exact = Int64(Self.bodies.values.reduce(0) { $0 + $1.count }) + ModelDownloader.diskMargin
        let directory = try await ModelDownloader(store: store, transport: transport, freeDisk: { _ in exact })
            .install(manifest)
        #expect(transport.requests.withLock { $0.filter { $0.0 == "model.safetensors" }.map(\.1) } == [0])
        #expect(try Data(contentsOf: directory.appending(path: "model.safetensors")) == Self.bodies["model.safetensors"])
    }

    /// A volume that will not say what it has is not a volume with room: refused, not attempted.
    @Test func aDiskThatWillNotSayIsRefused() async throws {
        let store = try store()
        let transport = MemoryTransport(Self.bodies)
        await #expect(throws: ModelDownloadError.self) {
            try await ModelDownloader(store: store, transport: transport, freeDisk: { _ in nil })
                .install(Self.manifest(Self.bodies))
        }
        #expect(transport.requests.withLock { $0.isEmpty })
    }

    /// **One install of a model at a time.** The app's board and the report share a store, and two
    /// installs of one manifest write the same staging files and can remove each other's directory.
    @Test func aSecondInstallOfTheSameModelIsRefusedWhileTheFirstHoldsIt() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        try FileManager.default.createDirectory(
            at: store.stagingDirectory(for: manifest), withIntermediateDirectories: true)
        let held = try #require(InstallLock(store.lockFile(for: manifest)))
        defer { held.release() }

        await #expect(throws: ModelDownloadError.alreadyInstalling(identifier: manifest.identifier)) {
            try await ModelDownloader(store: store, transport: MemoryTransport(Self.bodies), freeDisk: { _ in .max })
                .install(manifest)
        }
    }

    /// Progress is what is on disk. A host that ignores the range and restarts a file must not read
    /// as bytes gained — the download would report itself finished while short.
    @Test func aRestartedFileDoesNotCountItsDiscardedFront() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        let transport = MemoryTransport(Self.bodies)
        transport.interruptions.withLock { $0["model.safetensors"] = 40_000 }
        let downloader = ModelDownloader(store: store, transport: transport, freeDisk: { _ in .max })
        await #expect(throws: MemoryTransport.Dropped.self) { try await downloader.install(manifest) }

        let seen = Recorder<[Int64]>([])
        transport.restarts.withLock { $0.insert("model.safetensors") }
        try await downloader.install(manifest) { progress in seen.withLock { $0.append(progress.received) } }
        let received = seen.withLock { $0 }
        #expect(received == received.sorted(), "progress ran backwards over a restarted file")
        #expect(received.last == manifest.totalBytes)
        #expect(received.allSatisfy { $0 <= manifest.totalBytes }, "progress counted a discarded front")
    }

    /// The pins themselves: every file by commit, from ModelScope, with a SHA-256 and a size — and
    /// every size carries its licence, which the mirror does not.
    @Test(arguments: ModelManifest.all)
    func everyShippedManifestIsPinned(manifest: ModelManifest) {
        #expect(manifest.revision.count == 40 && manifest.revision.allSatisfy(\.isHexDigit))
        for file in manifest.files {
            #expect(file.sha256.count == 64 && file.sha256.allSatisfy(\.isHexDigit), "\(file.path)")
            #expect(file.size > 0)
            #expect(file.url.host() == "modelscope.cn")
            #expect(file.url.path().contains("/resolve/\(file.revision)/"), "not pinned by commit: \(file.path)")
        }
        #expect(manifest.licence != nil)
        #expect(manifest.files.contains { $0.path.hasSuffix(".safetensors") })
        #expect(manifest.files.contains { $0.path == "tokenizer.json" })
    }

    /// **What an older pin left behind is removed, and a download in flight is not.** A model's
    /// directory carries its revision, so a new pin installs beside the old weights rather than over
    /// them — and no manifest the app still knows names the old directory, so nothing would ever
    /// remove it. A staged download's own marker is written inside `.staging` just before the move,
    /// which is why the prune must not reach in there.
    @Test func strayModelsAreRemovedAndAStagedDownloadIsLeftAlone() throws {
        let store = try store()
        let keeper = Self.manifest(Self.bodies)
        let stale = ModelManifest(
            size: .standard, repository: keeper.repository, revision: "older",
            files: keeper.files.map {
                ModelFile(repository: $0.repository, revision: "older", path: $0.path,
                          size: $0.size, sha256: $0.sha256)
            })
        for manifest in [keeper, stale] {
            let directory = store.directory(for: manifest)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (path, body) in Self.bodies { try body.write(to: directory.appending(path: path)) }
            try ModelStore.markerText(for: manifest).write(
                to: directory.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
        }
        let staging = store.stagingDirectory(for: keeper)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try ModelStore.markerText(for: keeper).write(
            to: staging.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)

        // **Not while something is installing.** The downloader runs in the app and in
        // `--model-report`; a model the other process finished a moment ago looks exactly like a
        // stray to a prune that read the store before it landed.
        let held = try #require(InstallLock(store.lockFile(for: keeper)))
        // A prune that did not run says so: an empty answer would read as "the store is as this pin
        // wants it", which is exactly what nobody checked.
        #expect(store.removeStrays(keeping: keeper) == ["the store was busy, so nothing was pruned"])
        #expect(store.installed(stale) != nil, "a model was deleted while a download was in flight")
        held.release()

        #expect(store.removeStrays(keeping: keeper).isEmpty)
        #expect(store.installed(keeper) != nil)
        #expect(store.installed(stale) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: stale).path))
        #expect(FileManager.default.fileExists(atPath: staging.path), "a download in flight was deleted")
    }

    /// **And what an interrupted download of a superseded pin left behind.** Nothing names that
    /// revision again, so its part-file stays for good — the same gigabytes as a stray model, in the
    /// one directory the prune deliberately does not walk. Removed only while its own install lock
    /// can be taken, which is what says nobody is downloading it now.
    @Test func aStagedDownloadOfAnOlderPinIsReclaimedUnlessItIsRunning() throws {
        let store = try store()
        let keeper = Self.manifest(Self.bodies)
        let stale = ModelManifest(
            size: .standard, repository: keeper.repository, revision: "older",
            files: keeper.files.map {
                ModelFile(repository: $0.repository, revision: "older", path: $0.path,
                          size: $0.size, sha256: $0.sha256)
            })
        // The keeper is installed, as a prune requires; both have something staged.
        let directory = store.directory(for: keeper)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, body) in Self.bodies { try body.write(to: directory.appending(path: path)) }
        try ModelStore.markerText(for: keeper).write(
            to: directory.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
        for manifest in [keeper, stale] {
            let staged = store.stagingDirectory(for: manifest)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try Data(count: 1_024).write(to: staged.appending(path: "model.safetensors.partial"))
        }

        // While the old pin is being downloaded, its part-file is not touched.
        let held = try #require(InstallLock(store.lockFile(for: stale)))
        #expect(store.removeStrays(keeping: keeper) == ["the store was busy, so nothing was pruned"])
        #expect(FileManager.default.fileExists(atPath: store.stagingDirectory(for: stale).path),
                "a staged download that was running was deleted")
        held.release()

        #expect(store.removeStrays(keeping: keeper).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.stagingDirectory(for: stale).path),
                "the older pin's part-file was left on disk for good")
        #expect(FileManager.default.fileExists(atPath: store.stagingDirectory(for: keeper).path),
                "this pin's own staged download was deleted")
    }

    /// **Two installs cannot both spend the same free space.** Each asked the disk question under
    /// its own per-model lock, so the app downloading 4B and `--model-report` downloading 9B both
    /// saw the same gigabytes free, both counted the same margin, and between them could fill the
    /// volume. What another install still has to fetch is counted against this one.
    @Test func whatAnotherInstallStillNeedsCountsAgainstThisOne() throws {
        let store = try store()
        let other = LocalModelSize.large.manifest
        let staged = store.stagingDirectory(for: other)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let outstandingWithNothingOnDisk = store.outstandingElsewhere(excluding: store.root)
        #expect(outstandingWithNothingOnDisk == other.totalBytes,
                "an install with nothing fetched yet was counted as needing nothing")

        // What it has already fetched is on disk and is not counted twice.
        let first = other.files[0]
        try Data(count: Int(first.size)).write(to: staged.appending(path: first.path))
        #expect(store.outstandingElsewhere(excluding: store.root) == other.totalBytes - first.size)

        // And an install does not count itself.
        #expect(store.outstandingElsewhere(excluding: staged) == 0)
    }

    /// **A prune and a commit cannot interleave.** The prune decides across every model at once —
    /// enumerate, then delete — and an install that commits in between has its new model read as a
    /// stray by a decision taken before it existed. Both take one store-wide lock.
    @Test func aPruneHoldsTheStoreWhileItRunsAndAnInstallWaitsForIt() async throws {
        let store = try store()
        let manifest = Self.manifest(Self.bodies)
        try FileManager.default.createDirectory(
            at: store.root.appending(path: ".staging", directoryHint: .isDirectory),
            withIntermediateDirectories: true)

        // Held by somebody else: the prune does nothing rather than deciding over a store that is
        // being written to, and is retried on the next refresh.
        let held = try #require(InstallLock(store.storeLockFile()))
        let directory = store.directory(for: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, body) in Self.bodies { try body.write(to: directory.appending(path: path)) }
        try ModelStore.markerText(for: manifest).write(
            to: directory.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
        let stale = store.root.appending(path: "old/model@0", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try "not this pin".write(
            to: stale.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)

        #expect(store.removeStrays(keeping: manifest) == ["the store was busy, so nothing was pruned"])
        #expect(FileManager.default.fileExists(atPath: stale.path),
                "the prune decided over a store somebody else was writing to")

        // **And an install waits for it** — which is the half of this test's own name that it used
        // not to exercise at all: it never started an installer, so it would have passed against a
        // commit that ignored the lock outright. A second model is staged whole and installed while
        // the lock is held; nothing may appear at its destination until the lock is given back.
        let second = ModelManifest(
            size: .small, repository: manifest.repository, revision: "second",
            files: manifest.files.map {
                ModelFile(repository: $0.repository, revision: "second", path: $0.path,
                          size: $0.size, sha256: $0.sha256)
            })
        let staged = store.stagingDirectory(for: second)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        for (path, body) in Self.bodies { try body.write(to: staged.appending(path: path)) }
        let install = Task {
            try await ModelDownloader(store: store, transport: MemoryTransport(Self.bodies)).install(second) { _ in }
        }
        // **Waited for, not slept past.** A fixed sleep proves nothing about where the installer
        // got to: it could still be starting. The installer holds its own per-model lock for the
        // whole install, so waiting until that lock cannot be taken is what says it is inside —
        // and only then does "nothing has been committed" mean anything.
        // The marker is written inside staging *immediately before* the commit, so its arrival is
        // the installer telling us it has reached the one step this test is about. Probing its lock
        // instead would take the lock the installer needs and fail the install outright.
        let marker = staged.appending(path: ModelStore.completionMarker)
        var reachedTheCommit = false
        for _ in 0..<500 where !reachedTheCommit {
            if FileManager.default.fileExists(atPath: marker.path) { reachedTheCommit = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reachedTheCommit, "the installer never reached the commit, so the assertion below proves nothing")
        #expect(store.installed(second) == nil, "a model was committed while the store was locked")
        held.release()
        _ = try await install.value
        #expect(store.installed(second) != nil, "the install never completed after the lock was given back")
        // It gave the lock back too, so the prune below can take it.
        try store.remove(second)

        #expect(store.removeStrays(keeping: manifest).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        // And it gives the lock back: a second prune runs.
        #expect(store.removeStrays(keeping: manifest).isEmpty)
        #expect(store.installed(manifest) != nil)
    }

    /// **A store that cannot be read is not a store with nothing in it.** Both answers here decide
    /// whether to delete gigabytes, so "could not tell" has to mean "do not": an unreadable staging
    /// directory reads as an install in flight, and an unreadable root is reported as a failure
    /// rather than as a prune that found nothing to do.
    @Test func whatCannotBeReadIsNeverTakenForAnEmptyStore() throws {
        let store = try store()
        let keeper = Self.manifest(Self.bodies)
        let directory = store.directory(for: keeper)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, body) in Self.bodies { try body.write(to: directory.appending(path: path)) }
        try ModelStore.markerText(for: keeper).write(
            to: directory.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)

        // A staging directory nobody can look inside.
        let staging = store.root.appending(path: ".staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: staging.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path) }
        #expect(store.isInstalling, "an unreadable staging directory was read as nothing installing")
        #expect(store.removeStrays(keeping: keeper) == ["the store was busy, so nothing was pruned"])
        #expect(store.installed(keeper) != nil)
    }

    /// **A body that runs past its pin is refused as it arrives, not after it has all landed.** The
    /// disk was checked for the pinned size and nothing more, so a server sending an endless file
    /// would fill the reader's disk before the size check meant to catch it ever ran. Driven through
    /// the delegate directly: no fake transport reaches this, and a real one cannot be asked for it.
    @Test func aBodyLongerThanItsPinIsRefusedWhileItArrives() async throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let file = store.root.appending(path: "model.safetensors")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let writer = try RangeWriter(
            destination: file, offset: 0, path: "model.safetensors", expecting: 8, progress: { _ in })  
        let task = URLSession.shared.dataTask(with: try #require(URL(string: "https://example.invalid/x")))

        writer.urlSession(.shared, dataTask: task, didReceive: Data(count: 4))
        writer.urlSession(.shared, dataTask: task, didReceive: Data(count: 99))

        // **What is on disk is the assertion.** Asking the writer for its outcome would mean
        // resuming the task, and a test that reaches the network hangs where there is none — which
        // is worse than the defect: a guard that regressed would stall the suite instead of failing
        // it. Unrefused, the second chunk lands and the file is 103 bytes.
        let onDisk = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        #expect(onDisk == 4, "the oversized chunk was written before it was refused")
        #expect(task.state != .running, "the refused download was left running")
    }

    /// The standard model's directory is named for its repository and commit, under the support
    /// directory the ledger shares — which is what lets the service find what the app downloaded.
    @Test func theModelLivesWhereTheServiceWillLook() throws {
        let support = URL(filePath: "/tmp/support", directoryHint: .isDirectory)
        let store = ModelStore.standard(applicationSupport: support)
        #expect(store.directory(for: LocalModelSize.standard.manifest).path()
            == "/tmp/support/XiaolaiDict/Models/mlx-community/Qwen3.5-4B-4bit@ab9c7a42fd31095a40634b3362317779dee9e7fa/")
    }
}
