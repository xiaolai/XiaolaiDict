import CryptoKit
import Foundation

/// Where the local model lives on disk, and the one rule that makes it safe to load: **a model is
/// loadable only once it is whole.**
///
/// A model arrives into a staging directory, file by file, each checked against its listed size and
/// SHA-256. Only when every file has passed is a marker written and the directory moved into place —
/// one `rename(2)`, so the model's own directory either does not exist or holds all of it. The
/// service loads from the model's directory and nowhere else, so a half-downloaded model is not
/// something it can be pointed at.
public struct ModelStore: Sendable, Equatable {
    /// `~/Library/Application Support/XiaolaiDict/Models`, beside the ledger.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let directoryName = "Models"
    /// Written last, inside the staging directory, just before it is moved into place.
    static let completionMarker = ".complete"
    static let stagingName = ".staging"
    /// What a file is called while it is still arriving. Never the name the loader reads.
    static let partialSuffix = ".partial"

    /// The reader's store. `applicationSupport` is a parameter so tests can use a directory of
    /// their own; the path under it is fixed, because the service and the app must agree on it
    /// without asking each other.
    ///
    /// Not throwing, on purpose: the user's Application Support is a fixed path, and a store that
    /// could be nil made every caller invent a meaning for "no store" — one of which was a Download
    /// button that silently did nothing. Whether the directory can be *written* is the download's
    /// question, and it fails loudly there.
    public static func standard(applicationSupport: URL = .applicationSupportDirectory) -> ModelStore {
        ModelStore(root: applicationSupport.appending(path: "XiaolaiDict", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory))
    }

    /// `Models/<repository>@<revision>` — the repository's own slash makes it two levels.
    public func directory(for manifest: ModelManifest) -> URL {
        root.appending(path: manifest.identifier, directoryHint: .isDirectory)
    }

    func stagingDirectory(for manifest: ModelManifest) -> URL {
        root.appending(path: Self.stagingName, directoryHint: .isDirectory)
            .appending(path: manifest.identifier, directoryHint: .isDirectory)
    }

    /// The model's directory, **only if it is complete**: moved into place, marked, and every file
    /// there at its listed size. Sizes, not hashes — the hashes were checked as each file arrived,
    /// and reading 3 GB on every launch to check them again would cost seconds for nothing.
    public func installed(_ manifest: ModelManifest) -> URL? {
        let directory = directory(for: manifest)
        let marker = directory.appending(path: Self.completionMarker)
        guard (try? String(contentsOf: marker, encoding: .utf8)) == Self.markerText(for: manifest)
        else { return nil }
        for file in manifest.files {
            let size = (try? FileManager.default.attributesOfItem(
                atPath: directory.appending(path: file.path).path)[.size] as? NSNumber)?.int64Value
            guard size == file.size else { return nil }
        }
        return directory
    }

    /// Of `manifests`, the ones installed whole — by default every manifest the app knows.
    ///
    /// **Always asked with an explicit `among:` by anything that speaks for this Mac.** An
    /// `installedSizes()` convenience over the default list was here and was the wrong question: it
    /// answers with a model copied from a larger Mac, which is on disk and can never be loaded here
    /// — read as ready it promises an answer the service then refuses for want of memory.
    /// `LocalModelController` passes the sizes this Mac is *offered*, and that is the only reading
    /// the reader is shown.
    public func installedManifests(among manifests: [ModelManifest] = ModelManifest.all) -> [ModelManifest] {
        manifests.filter { installed($0) != nil }
    }

    /// Removes a model and anything of it still staged. **Not `public`, and not called by the
    /// app**: pruning is `removeStrays(keeping:)`, which holds off while an install is in flight.
    /// This is the tests' own way of putting a store into a state.
    func remove(_ manifest: ModelManifest) throws {
        for directory in [directory(for: manifest), stagingDirectory(for: manifest)]
        where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Every complete model directory under the root **except** `keeping`'s, removed. Returns what
    /// it could not do — a removal that failed, a store it could not read, or a prune it did not
    /// run because something else was writing — so a caller can say so rather than read silence as
    /// success. An empty answer means the store is as this pin wants it.
    ///
    /// A model's directory is named for its pin — `repository@revision` — so bumping the pin
    /// installs the new weights *beside* the old ones rather than over them. Removing by manifest
    /// cannot reach those: `ModelManifest.all` no longer lists the revision that wrote them, and
    /// several gigabytes stay on disk for a model nothing will ever name again. They are found by
    /// their completion markers instead, which is what makes a directory a model whatever pin
    /// wrote it.
    @discardableResult
    public func removeStrays(keeping: ModelManifest) -> [String] {
        // **Never while an install is in flight anywhere on this Mac.** The downloader runs in the
        // app *and* in `--model-report`, so a model finished by the other process would be found as
        // a stray by a prune that read the store before it landed — and three gigabytes deleted a
        // moment after they arrived. A staged download is never at risk (`.staging` is hidden from
        // the walk below); a *completed* one is, which is what this guards.
        guard !isInstalling else { return ["the store was busy, so nothing was pruned"] }
        // **Held for the whole run.** Taken after the check above and given back at the end, so an
        // install cannot commit between the enumeration and the removals. Not taken means somebody
        // is committing right now; the prune is retried on the next refresh.
        // **A prune never brings the store into existence.** The staging directory is made here
        // because the lock lives in it — and with intermediate directories, which is the root as
        // well. So a prune that arrived after its store had been removed *recreated* it, with the
        // lock inside and nothing else: measured 2026-09-23 as one directory per test run under
        // the system's temporary directory, each holding exactly `.staging/store.lock`, left by a
        // detached prune that outran the fixture that owned the store. There is nothing to prune
        // in a store that is not there, so there is nothing to make either — and the staging
        // directory is made one level only, so no later change can put the root back by accident.
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try? FileManager.default.createDirectory(
            at: root.appending(path: Self.stagingName, directoryHint: .isDirectory),
            withIntermediateDirectories: false)
        guard let store = InstallLock(storeLockFile()) else {
            return ["the store was busy, so nothing was pruned"]
        }
        defer { store.release() }
        // Nothing is removed on behalf of a model that is not there: whatever the caller believed
        // about the store, it is not what the store says now.
        guard installed(keeping) != nil else { return [] }
        let keep = directory(for: keeping).standardizedFileURL.path
        var failures: [String] = []
        let complete = completeDirectories()
        if complete.isEmpty, FileManager.default.fileExists(atPath: root.path) {
            // The keeper is installed — asked above — so the walk finding nothing means it failed.
            failures.append("the model directory could not be read")
        }
        for directory in complete where directory.standardizedFileURL.path != keep {
            // No re-check here: the store lock above is held across the enumeration *and* these
            // removals, and an install commits under the same lock — so nothing can land between
            // the decision and the deletion. That is what the lock is for.
            do { try FileManager.default.removeItem(at: directory) }
            catch { failures.append(directory.lastPathComponent) }
        }
        return failures + removeStagedStrays(keeping: keeping)
    }

    /// What an interrupted download of a **superseded pin** left in `.staging`. Nothing ever names
    /// that revision again, so its part-file sits there for good: measured against the same defect
    /// as the completed strays above, and gigabytes either way.
    ///
    /// Each is removed only while **its own install lock can be taken** — which is what says nobody
    /// is downloading it now — and the lock is given straight back afterwards.
    private func removeStagedStrays(keeping: ModelManifest) -> [String] {
        let staging = root.appending(path: Self.stagingName, directoryHint: .isDirectory)
        let keep = stagingDirectory(for: keeping).standardizedFileURL.path
        var failures: [String] = []
        for directory in stagedModels(under: staging) where directory.standardizedFileURL.path != keep {
            // The identifier is the path under `.staging` — the same shape the lock is named from.
            let identifier = directory.standardizedFileURL.path
                .replacingOccurrences(of: staging.standardizedFileURL.path + "/", with: "")
            guard let taken = InstallLock(
                staging.appending(path: identifier.replacing("/", with: "-") + ".lock"))
            else { continue }  // somebody is downloading it
            do { try FileManager.default.removeItem(at: directory) }
            catch { failures.append(identifier) }
            taken.release()
        }
        return failures
    }

    /// The staged model directories: one level below `.staging/<owner>`, which is how an identifier
    /// of the form `owner/name@revision` lands on disk.
    private func stagedModels(under staging: URL) -> [URL] {
        let owners = (try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return owners.flatMap { owner -> [URL] in
            guard (try? owner.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return [] }
            return ((try? FileManager.default.contentsOfDirectory(
                at: owner, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { $0.lastPathComponent.contains("@") }
        }
    }

    /// Every directory under the root holding a completion marker. Hidden entries are skipped,
    /// which is what keeps `.staging` out of it — a download writes its marker there, inside the
    /// directory it is about to move, and a prune that reached in would delete a model mid-install.
    private func completeDirectories() -> [URL] {
        // A root that cannot be walked is not a root with nothing in it. The caller is told by the
        // failure it gets back, rather than by a prune that quietly removed nothing.
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var found: [URL] = []
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard FileManager.default.fileExists(
                atPath: url.appending(path: Self.completionMarker).path) else { continue }
            found.append(url)
            walk.skipDescendants()
        }
        return found
    }

    /// The bytes other installs in this store still have to fetch — what their manifests list, less
    /// what is already on disk for them. Read from `.staging`, which is where an install in flight
    /// keeps its files, so it needs no coordination beyond the directory itself.
    func outstandingElsewhere(excluding mine: URL) -> Int64 {
        let mine = mine.standardizedFileURL.path
        var outstanding: Int64 = 0
        for manifest in ModelManifest.all {
            let directory = stagingDirectory(for: manifest)
            guard directory.standardizedFileURL.path != mine,
                  FileManager.default.fileExists(atPath: directory.path)
            else { continue }
            for file in manifest.files {
                let onDisk = [file.path, file.path + Self.partialSuffix]
                    .map { directory.appending(path: $0).path }
                    .compactMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.int64Value }
                    .max() ?? 0
                outstanding += max(0, file.size - onDisk)
            }
        }
        return outstanding
    }

    /// Whether any install anywhere in this store is holding its lock right now — asked by trying
    /// to take each lock and giving it straight back. A lock file with nobody on it is left behind
    /// by every finished install, so the *file* proves nothing; only the `flock` does.
    var isInstalling: Bool {
        let staging = root.appending(path: Self.stagingName, directoryHint: .isDirectory)
        // **Fails closed.** A staging directory that is there and cannot be read says nothing about
        // what is downloading — and the answer is used to decide whether to delete gigabytes, so
        // "could not tell" has to mean "do not".
        guard let locks = try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil)
        else { return FileManager.default.fileExists(atPath: staging.path) }
        // **The store's own lock is not an install's.** A prune holds it for its whole run, so
        // counting it here made the prune read itself as an install in flight and remove nothing.
        for lock in locks where lock.pathExtension == "lock"
            && lock.lastPathComponent != Self.storeLockName {
            guard let taken = InstallLock(lock) else { return true }
            taken.release()
        }
        return false
    }

    /// **The lock a prune holds for its whole run, and an install takes while it commits.** One
    /// name, so the two cannot interleave: a prune enumerating the store while an install renames
    /// its staging directory into place would find the new model a stray and delete it a moment
    /// after it arrived. Per-manifest locks cannot close that, because the prune's decision spans
    /// every model rather than one.
    func storeLockFile() -> URL {
        root.appending(path: Self.stagingName, directoryHint: .isDirectory)
            .appending(path: Self.storeLockName)
    }

    static let storeLockName = "store.lock"

    /// The lock one install of `manifest` holds — against another process, and against this one.
    func lockFile(for manifest: ModelManifest) -> URL {
        root.appending(path: Self.stagingName, directoryHint: .isDirectory)
            .appending(path: manifest.identifier.replacing("/", with: "-") + ".lock")
    }

    /// Names the manifest it completes, so a directory left by an older pin is not taken for this one.
    static func markerText(for manifest: ModelManifest) -> String {
        manifest.identifier + "\n" + manifest.files.map { "\($0.path) \($0.size) \($0.sha256)" }.joined(separator: "\n")
    }
}

/// How far a download has got, in bytes, across every file of the model.
public struct ModelDownloadProgress: Sendable, Equatable {
    public let received: Int64
    public let total: Int64

    public init(received: Int64, total: Int64) {
        self.received = received
        self.total = total
    }

    public var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
}

public enum ModelDownloadError: Error, Equatable, Sendable {
    /// Checked before a byte is fetched, against what is still to come — never discovered 2 GB in.
    case insufficientDisk(needed: Int64, available: Int64)
    /// The volume would not say how much room it has. Refused rather than started hopefully: a
    /// download that fills a disk is worse than one that did not begin.
    case diskCapacityUnknown(path: String)
    /// The file arrived, and it is not the one pinned. It is deleted, so a retry starts clean.
    case hashMismatch(path: String)
    /// More or fewer bytes than listed.
    case sizeMismatch(path: String, expected: Int64, received: Int64)
    /// A file that should not have survived the failure that made it — and the reason it did.
    case couldNotDiscard(path: String, reason: String)
    /// The model was assembled and still did not read back as installed.
    case incomplete(identifier: String)
    /// The host answered with something other than the file.
    case http(status: Int, path: String)
    /// Another install of this model is running — in this process or another. One writes; the other
    /// waits for the reader to ask again rather than writing over it.
    case alreadyInstalling(identifier: String)
}

/// Fetches one file's bytes. The seam tests replace: the real one is `URLSessionModelTransport`.
public protocol ModelFileTransport: Sendable {
    /// Appends `file`'s bytes, **starting at byte `offset`**, to the end of `destination`, calling
    /// `progress` with **how many bytes of this file are now on disk** — not how many this call
    /// wrote. A host that ignores the range and sends the whole file makes the two differ, and the
    /// downloader adds this to the other files' totals, so a restart must not read as extra bytes.
    /// Returns once the host has sent all it will; the downloader, not the transport, decides
    /// whether that was the whole file.
    func fetch(
        _ file: ModelFile, from offset: Int64, appendingTo destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws
}

/// Puts a model into the store: resumable, checked, atomic, and refused up front where the disk
/// cannot hold it.
public struct ModelDownloader: Sendable {
    public let store: ModelStore
    private let transport: any ModelFileTransport
    private let freeDisk: @Sendable (URL) -> Int64?

    /// Left free after the download, so a model never takes the last of the reader's disk.
    public static let diskMargin: Int64 = 512 * 1_048_576

    public init(
        store: ModelStore, transport: any ModelFileTransport = URLSessionModelTransport(),
        freeDisk: @escaping @Sendable (URL) -> Int64? = ModelDownloader.availableDisk(at:)
    ) {
        self.store = store
        self.transport = transport
        self.freeDisk = freeDisk
    }

    /// Downloads whatever of `manifest` is missing and moves it into place. Returns the model's
    /// directory. Safe to call again after any failure or cancellation: what already arrived — a
    /// finished file, or the front of an unfinished one — is kept and not fetched again.
    ///
    /// **One install of a model at a time, across processes.** The app's own board and the
    /// `--model-report` instrument share a store, and two installs of one manifest write the same
    /// staging files and can remove each other's finished directory. The second to arrive is
    /// refused rather than allowed to interleave.
    @discardableResult
    public func install(
        _ manifest: ModelManifest, progress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        if let installed = store.installed(manifest) { return installed }
        let staging = store.stagingDirectory(for: manifest)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        guard let lock = InstallLock(store.lockFile(for: manifest)) else {
            throw ModelDownloadError.alreadyInstalling(identifier: manifest.identifier)
        }
        defer { lock.release() }
        // Installed while this waited for the lock, or between the two looks.
        if let installed = store.installed(manifest) { return installed }

        try normalizeStaging(manifest, in: staging)
        let present = arrivedBytes(of: manifest, in: staging)
        let total = manifest.totalBytes
        try checkDisk(needing: total - present, at: staging)

        progress(ModelDownloadProgress(received: present, total: total))
        for file in manifest.files {
            try Task.checkCancellation()
            let finished = staging.appending(path: file.path)
            if FileManager.default.fileExists(atPath: finished.path) { continue }
            try await fetch(file, of: manifest, into: staging, total: total, progress: progress)
        }

        try Task.checkCancellation()
        try ModelStore.markerText(for: manifest).write(
            to: staging.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
        // **Never committed without the store's lock.** A prune decides across every model at once,
        // so it holds this for its whole run; committing inside it is what keeps a model that lands
        // mid-prune from being read as a stray and deleted. An earlier version gave up after five
        // seconds and committed anyway, which put the race back exactly where the lock had removed
        // it. Waited for instead, with no deadline and with cancellation honoured: a prune holds
        // this for the length of a directory walk, and the kernel gives a lock back when the
        // process holding it dies, so there is nothing here to wait out for ever.
        let held = try await Self.waitForStoreLock(store.storeLockFile())
        defer { held.release() }
        return try commit(staging, of: manifest, holding: held)
    }

    /// What is in staging, made trustworthy before anything is counted or fetched.
    ///
    /// A **finished** file is only trusted once its bytes are checked: it may be a stale copy from
    /// an older pin, or a corrupted one, and the final check reads sizes alone — so a same-size
    /// wrong file would be marked complete. A **partial** longer than the file can be is not a front
    /// to resume from, and counting it as a whole file is what once let it skip the disk check.
    private func normalizeStaging(_ manifest: ModelManifest, in staging: URL) throws {
        for file in manifest.files {
            let finished = staging.appending(path: file.path)
            if FileManager.default.fileExists(atPath: finished.path) {
                if size(of: finished) == file.size, try Self.sha256(of: finished) == file.sha256 { continue }
                try discard(finished, because: "it is not the file that was pinned")
            }
            let partial = staging.appending(path: file.path + ModelStore.partialSuffix)
            if size(of: partial) > file.size {
                try discard(partial, because: "it is longer than the file it claims to be")
            }
        }
    }

    /// Refused before a byte is fetched — and refused too where the volume will not say what it has,
    /// which is not the same as having room.
    private func checkDisk(needing needed: Int64, at staging: URL) throws {
        guard needed > 0 else { return }
        guard let available = freeDisk(staging) else {
            throw ModelDownloadError.diskCapacityUnknown(path: staging.path)
        }
        // **What every other install still has to fetch counts too.** Each one asked this question
        // under its own per-model lock, so two sizes downloading at once — the app's 4B and the
        // report's 9B — both saw the same free space, both counted the same margin, and between
        // them could fill the volume. What is already staged is on disk and is not counted again;
        // what those files still lack is.
        let outstanding = store.outstandingElsewhere(excluding: staging)
        let wanted = needed + outstanding + Self.diskMargin
        guard available >= wanted else {
            throw ModelDownloadError.insufficientDisk(needed: wanted, available: available)
        }
    }

    /// One file: resumed from what is there, checked against its listed size and hash, and only then
    /// given the name the loader reads.
    private func fetch(
        _ file: ModelFile, of manifest: ModelManifest, into staging: URL, total: Int64,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        let partial = staging.appending(path: file.path + ModelStore.partialSuffix)
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let offset = size(of: partial)
        if offset < file.size {
            // Everything but this file, so a restart inside the transport cannot double-count.
            let others = arrivedBytes(of: manifest, in: staging, excluding: file)
            try await transport.fetch(file, from: offset, appendingTo: partial) { onDisk in
                progress(ModelDownloadProgress(received: others + min(onDisk, file.size), total: total))
            }
        }
        let received = size(of: partial)
        guard received == file.size else {
            // Short is kept, to resume from; long is discarded, because it cannot be a front.
            if received > file.size { try discard(partial, because: "it is longer than the file it claims to be") }
            throw ModelDownloadError.sizeMismatch(path: file.path, expected: file.size, received: received)
        }
        guard try Self.sha256(of: partial) == file.sha256 else {
            try discard(partial, because: "its bytes are not the ones that were pinned")
            throw ModelDownloadError.hashMismatch(path: file.path)
        }
        try FileManager.default.moveItem(at: partial, to: staging.appending(path: file.path))
        progress(ModelDownloadProgress(received: arrivedBytes(of: manifest, in: staging), total: total))
    }

    /// The move that makes a model loadable: one rename, after which the directory holds all of it.
    private func commit(_ staging: URL, of manifest: ModelManifest, holding held: InstallLock) throws -> URL {
        _ = held  // held by the caller for the whole commit; named so it cannot be dropped early
        let destination = store.directory(for: manifest)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Only an incomplete directory can be in the way — an installed one returned above, and the
        // lock keeps another install of this model from having put one there meanwhile.
        if FileManager.default.fileExists(atPath: destination.path) {
            try discard(destination, because: "it is an unfinished copy of this model")
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        guard let installed = store.installed(manifest) else {
            throw ModelDownloadError.incomplete(identifier: manifest.identifier)
        }
        return installed
    }

    /// The store lock, waited for until it is free. Throws only when the caller is cancelled — and
    /// then before the model is moved into place, so the staged copy survives for the next attempt.
    static func waitForStoreLock(_ file: URL) async throws -> InstallLock {
        while true {
            try Task.checkCancellation()
            if let held = InstallLock(file) { return held }
            try await Task.sleep(for: storeLockPoll)
        }
    }

    /// How often the wait above looks. Short, because what it waits for is a directory walk.
    static let storeLockPoll = Duration.milliseconds(20)

    /// Removes what must not survive — and says so when it cannot, rather than leaving a bad file to
    /// fail every retry from behind the error that made it.
    private func discard(_ url: URL, because reason: String) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ModelDownloadError.couldNotDiscard(path: url.lastPathComponent, reason: "\(reason); \(error)")
        }
    }

    /// Bytes of `file` already in staging: all of it once finished, or the front of it so far.
    private func arrived(_ file: ModelFile, in staging: URL) -> Int64 {
        let finished = staging.appending(path: file.path)
        if FileManager.default.fileExists(atPath: finished.path) { return file.size }
        return min(file.size, size(of: staging.appending(path: file.path + ModelStore.partialSuffix)))
    }

    private func arrivedBytes(of manifest: ModelManifest, in staging: URL, excluding: ModelFile? = nil) -> Int64 {
        manifest.files.filter { $0.path != excluding?.path }.reduce(0) { $0 + arrived($1, in: staging) }
    }

    private func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// Read in 8 MB pieces, so hashing 3 GB never holds more than that in memory — and stops when
    /// the reader has stopped waiting, rather than reading gigabytes nobody wants.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Free space **on the volume the model is written to** — asked of the staging directory itself,
    /// because a store put on another mount is a different volume from the one above it.
    public static func availableDisk(at url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

/// One install of one model, held across processes by `flock(2)` — which the kernel releases if the
/// holder dies, so a crash never leaves a model permanently unlockable.
final class InstallLock: @unchecked Sendable {
    private let descriptor: Int32

    /// Nil when another install already holds it.
    ///
    /// **Created by `open` with `O_CREAT`, never by `FileManager.createFile`**, which replaces an
    /// existing file: the second caller then locked a fresh inode while the first held the orphaned
    /// one, and both "took" the lock. Measured — the test for this passed a second installer through.
    init?(_ file: URL) {
        descriptor = open(file.path, O_RDONLY | O_CREAT, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// The real transport: an HTTP range request, written to disk as it arrives.
///
/// A data task with a delegate rather than `bytes(for:)`: iterating `AsyncBytes` one byte at a time
/// over 3 GB is billions of suspensions for nothing, where the delegate hands over whole chunks.
public struct URLSessionModelTransport: ModelFileTransport {
    public init() {}

    public func fetch(
        _ file: ModelFile, from offset: Int64, appendingTo destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: file.url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let writer = try RangeWriter(
            destination: destination, offset: offset, path: file.path, expecting: file.size,
            progress: progress)
        let task = URLSession.shared.dataTask(with: request)
        task.delegate = writer
        try await withTaskCancellationHandler {
            try await writer.run(task)
        } onCancel: {
            task.cancel()
        }
    }
}

/// Appends a response body to a file as it arrives, and settles once.
///
/// The settling is a small state machine rather than a stored continuation, because the two can
/// arrive in either order: a task cancelled before `run` installs its continuation completes first,
/// and a writer that only stored continuations would drop that result and suspend forever.
/// Internal rather than private so its refusals can be driven directly: the guard below fires on a
/// server that keeps sending, which no fake transport reaches and no unit test can ask a real one for.
final class RangeWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum State {
        case waiting
        case running(CheckedContinuation<Void, any Error>)
        case settled(Result<Void, any Error>)
        case done
    }

    private let lock = NSLock()
    private let handle: FileHandle
    private let offset: Int64
    private let path: String
    private let progress: @Sendable (Int64) -> Void
    /// What the pin says this file is. **A body is refused the moment it passes it**, rather than
    /// after it has all arrived: the disk was reserved for this many bytes and nothing else, so a
    /// server sending an endless one would fill the reader's disk before the size check that was
    /// meant to catch it ever ran.
    private let expected: Int64
    /// Bytes of this file on disk: what was already there, plus what has arrived — and reset when a
    /// host ignores the range and starts the file again, so progress never counts a discarded front.
    private var onDisk: Int64
    private var state = State.waiting

    init(
        destination: URL, offset: Int64, path: String, expecting: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) throws {
        handle = try FileHandle(forWritingTo: destination)
        self.offset = offset
        self.path = path
        self.expected = expecting
        self.progress = progress
        onDisk = offset
    }

    func run(_ task: URLSessionDataTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let settled: Result<Void, any Error>? = lock.withLock {
                switch state {
                case .settled(let result):
                    state = .done
                    return result
                case .waiting:
                    state = .running(continuation)
                    return nil
                case .running, .done:
                    return .failure(ModelDownloadError.http(status: 0, path: path))
                }
            }
            if let settled { continuation.resume(with: settled) } else { task.resume() }
        }
    }

    /// Settles once, whichever arrives first — the completion or the caller's continuation.
    private func settle(_ result: Result<Void, any Error>) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            switch state {
            case .running(let continuation):
                state = .done
                return continuation
            case .waiting:
                state = .settled(result)
                return nil
            case .settled, .done:
                return nil
            }
        }
        continuation?.resume(with: result)
    }

    /// ModelScope answers with a redirect to its CDN. The range goes with it, or the CDN sends the
    /// whole file and a resumed download becomes a doubled one.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var redirected = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            redirected.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206 where offset > 0:
                try handle.seekToEnd()
            case 200:
                // The host ignored the range and is sending the whole file: start the file again,
                // rather than appending a second copy to the front of the first. What was there is
                // gone, and the progress this reports says so.
                try handle.truncate(atOffset: 0)
                lock.withLock { onDisk = 0 }
            default:
                throw ModelDownloadError.http(status: status, path: path)
            }
            completionHandler(.allow)
        } catch {
            settle(.failure(error))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // **Refused before it is written, not after it has all arrived.** The disk was checked for
        // the pinned size; a body that runs past it is either the wrong file or an endless one, and
        // writing it first means finding out when the disk is full.
        let would = lock.withLock { onDisk } + Int64(data.count)
        guard would <= expected else {
            settle(.failure(ModelDownloadError.sizeMismatch(
                path: path, expected: expected, received: would)))
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
            let total = lock.withLock { onDisk += Int64(data.count); return onDisk }
            progress(total)
        } catch {
            settle(.failure(error))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle.close()
        settle(error.map { .failure($0) } ?? .success(()))
    }
}
