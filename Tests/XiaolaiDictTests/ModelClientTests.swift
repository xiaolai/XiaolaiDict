import Foundation
@testable import ModelKit
import Testing
@testable import XiaolaiDict
@testable import XiaolaiDictCore
import XiaolaiDictTestSupport

/// The app's side of the model service: a dead or silent service is nil — "not here" — and the next
/// question opens a fresh session, which is how launchd relaunches a service that ended itself.
struct ModelClientTests {
    /// A service that answers from a script, can die, and counts what it was asked, per session.
    final class Service: @unchecked Sendable {
        let sessions = Recorder(0)
        let asked = Recorder<[ModelRequest]>([])
        let dies = Recorder(false)
        let cancelHandlers = Recorder<[@Sendable () -> Void]>([])
        /// What being told to unload does to this service's **process**. The real one answers and
        /// exits a moment later, and it is the exit rather than the answer that `unload` waits for —
        /// so a test that wants an unload to take ends its own process here. The default is a
        /// service that was asked and stayed, which is the failure the quarantine exists for.
        let whenUnloaded: @Sendable () -> Void

        init(whenUnloaded: @escaping @Sendable () -> Void = {}) { self.whenUnloaded = whenUnloaded }

        /// What this service explains with, so its answer can be told from Apple's.
        static let explanation = "Here the word names the ship's cargo space, not the verb."

        struct Died: Error {}

        struct Transport: ModelTransport {
            let service: Service
            func send(_ request: ModelRequest) async throws -> ModelReply {
                service.asked.withLock { $0.append(request) }
                if service.dies.withLock({ $0 }) { throw Died() }
                switch request {
                case .prewarm: return .prewarmed
                case .explain: return .explanation(Service.explanation)
                case .unload:
                    service.whenUnloaded()
                    return .unloading
                default: return .sense(1)
                }
            }
            func cancel(reason: String) {}
        }

        func connect(_ onCancel: @escaping @Sendable () -> Void) -> any ModelTransport {
            sessions.withLock { $0 += 1 }
            cancelHandlers.withLock { $0.append(onCancel) }
            return Transport(service: self)
        }

        /// The service ends itself, as it does when idle: XPC cancels the session.
        func endItself() { cancelHandlers.withLock { $0 }.last?() }
    }

    private static let question = ModelRequest.pickSense(
        SenseQuestion(sentence: "The ship's hold was full.", partOfSpeech: "noun", senses: ["a", "b"]))

    /// The scratch directories this test made, held for as long as the test instance lives so they
    /// are removed when it ends. A local `let` would be released while the store is still in use.
    private let scratches = Recorder<[TemporaryDirectory]>([])

    @Test func aDeadServiceIsNilAndTheNextQuestionOpensAFreshSession() async {
        let service = Service()
        let client = ModelClient(connect: { service.connect($0) })
        service.dies.withLock { $0 = true }
        #expect(await client.ask(Self.question) == nil)
        #expect(await client.openSessionGeneration == nil, "a dead session was kept")
        service.dies.withLock { $0 = false }
        #expect(await client.ask(Self.question) == .sense(1))
        #expect(service.sessions.withLock { $0 } == 2)
    }

    /// Prewarmed once per service process — not once per lookup — and again after the service ended
    /// itself, because the one that comes back holds nothing.
    @Test func itPrewarmsOncePerServiceProcess() async throws {
        let service = Service()
        let client = ModelClient(connect: { service.connect($0) })
        await client.prewarmOnce()
        await client.prewarmOnce()
        #expect(service.asked.withLock { $0.filter { $0 == .prewarm }.count } == 1)

        service.endItself()
        for _ in 0..<200 where await client.openSessionGeneration != nil { try await Task.sleep(for: .milliseconds(5)) }
        await client.prewarmOnce()
        #expect(service.asked.withLock { $0.filter { $0 == .prewarm }.count } == 2)
    }

    /// **A service that is not running is not started to be unloaded.** The service is
    /// launch-on-demand, so opening a session to ask is what *starts* one — which would then load
    /// nothing, be told to end, and count as having replaced the model it never held.
    @Test func unloadingWhenNothingRunsStartsNothing() async {
        let service = Service()
        let client = ModelClient(connect: { service.connect($0) }, servicePresence: { .gone })
        #expect(await client.unload())
        #expect(service.sessions.withLock { $0 } == 0, "a service was started in order to end it")
        #expect(service.asked.withLock { $0.isEmpty })
    }

    /// **The process decides, not the reply.** A service that could not be reached, or that never
    /// answered, is reported as still holding the model while its process is there — the app says so
    /// rather than claiming the old weights have gone.
    @Test func anUnloadThatWasNeverAnsweredReportsWhatTheProcessDid() async {
        let running = Recorder(true)
        let service = Service()
        service.dies.withLock { $0 = true }
        let client = ModelClient(
            connect: { service.connect($0) }, servicePresence: { running.withLock { $0 } ? .running : .gone },
            shutdownLimit: .milliseconds(50))
        #expect(await client.unload() == false, "a service still running was reported as ended")

        running.withLock { $0 = false }
        #expect(await client.unload(), "a process that had gone was reported as still there")
    }

    /// **"Could not tell" is not "gone".** A kernel that will not enumerate processes says nothing
    /// about the old model's weights; read as gone, it became the app's proof that a replacement
    /// was answering.
    @Test func anUnreadableProcessTableIsNotProofTheServiceEnded() async {
        let service = Service()
        let client = ModelClient(
            connect: { service.connect($0) }, servicePresence: { .couldNotTell },
            shutdownLimit: .milliseconds(50))
        #expect(await client.unload() == false, "a scan that failed was taken for a service that had gone")
    }

    /// **A held quarantine answers nothing, so the ladder falls through.** After an unload that
    /// could not be confirmed, the process with the replaced weights may still be answering — and
    /// an answer from the model the reader just replaced, drawn as confidently as any other, is the
    /// failure the whole lifecycle exists to prevent.
    @Test func aQuarantinedRungIsNotAsked() async throws {
        let service = Service()
        let (store, scratch) = try Self.storeWithAModel()
        scratches.withLock { $0.append(scratch) }
        let access = LocalModelAccess(
            client: ModelClient(connect: { service.connect($0) }), store: store,
            physicalMemory: 48 * 1_073_741_824)
        #expect(access.isInstalled)
        access.quarantine.hold()
        #expect(await access.ask(Self.question) == .failure(.notInstalled))
        await access.prewarm()
        #expect(service.sessions.withLock { $0 } == 0, "the held-back rung opened a session anyway")
    }

    /// **A model this Mac is not offered is not installed as far as the app is concerned.** The
    /// service refuses it for want of memory, so counting it here started a service on every lookup
    /// to be told so — and disagreed with the row the reader is shown.
    @Test func aModelThisMacCannotLoadDoesNotCountAsInstalled() async throws {
        let service = Service()
        let (store, scratch) = try Self.storeWithAModel()
        scratches.withLock { $0.append(scratch) }
        let roomy = LocalModelAccess(
            client: ModelClient(connect: { service.connect($0) }), store: store,
            physicalMemory: 48 * 1_073_741_824)
        let small = LocalModelAccess(
            client: ModelClient(connect: { service.connect($0) }), store: store,
            physicalMemory: 8 * 1_073_741_824)
        #expect(roomy.isInstalled)
        #expect(!small.isInstalled, "a model this Mac cannot load counted as one it has")
        #expect(await small.ask(Self.question) == .failure(.notInstalled))
        #expect(service.sessions.withLock { $0 } == 0)
    }

    /// **The sentence pane asks this model to *explain*, and the request is what says so.** Nothing
    /// else in the suite goes through `explainer`: the pane's only path to the service is this one
    /// closure, and `.explain` swapped for `.translate` there left every other check green while the
    /// reader got a translation in the explanation pane. So the assertion is on what the service
    /// received, not only on what came back — a fake that answered any request with prose would say
    /// nothing about which one was asked.
    @Test func theSentencePaneAsksTheModelToExplainTheReadersSentence() async throws {
        let service = Service()
        let (store, scratch) = try Self.storeWithAModel()
        scratches.withLock { $0.append(scratch) }
        let access = LocalModelAccess(
            client: ModelClient(connect: { service.connect($0) }), store: store,
            physicalMemory: 48 * 1_073_741_824)
        let question = SentenceQuestion(
            sentence: "The ship's hold was full.", term: "hold", senseText: "a cargo space in a ship")
        #expect(await access.explainer.explain(question) == .explained(Service.explanation, tier: .onDevice))
        #expect(service.asked.withLock { $0 } == [.explain(question)],
                "the pane's explainer asked the service something other than this sentence, explained")
    }

    /// A store holding the standard model whole, as the downloader would leave it. **Shared with
    /// `LocalModelCoordinatorTests`**, which installs into a store it has already handed the
    /// coordinator — the same fixture, reached the other way round, rather than a second copy of it.
    static func storeWithAModel() throws -> (ModelStore, TemporaryDirectory) {
        let scratch = TemporaryDirectory(named: "xiaolaidict-access")
        let store = ModelStore(root: scratch.url)
        try installTheModel(into: store)
        return (store, scratch)
    }

    /// Writes the standard model into `store` exactly as a finished download leaves it: every file
    /// at its listed size, then the completion marker that says the directory is whole.
    ///
    /// **The weights are a hole in the file, not three gigabytes of zeroes.** `ModelStore.installed`
    /// reads each file's size attribute and never a byte of it — "sizes, not hashes", as it says
    /// there — so a sparse file is the same fixture. Measured 2026-09-23 on the 3,034,300,695-byte
    /// safetensors: written out, **1.79 s and 3 GB of disk**; truncated, **0.4 ms and 0 blocks**,
    /// with the same size attribute, and a hole reads back as the zeroes it stands in for. Five
    /// tests want this store, so written out it is nine seconds and fifteen gigabytes — and three
    /// of those gigabytes live in memory at once per test, while the tests run in parallel. The two
    /// that had it measured 4.25 s and 4.28 s before this and 0.019 s and 0.016 s after.
    static func installTheModel(into store: ModelStore) throws {
        let manifest = LocalModelSize.standard.manifest
        let directory = store.directory(for: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in manifest.files {
            let url = directory.appending(path: file.path)
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.size))
            try handle.close()
        }
        try ModelStore.markerText(for: manifest).write(
            to: directory.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
    }

    /// Nothing is asked of a service that has no model to answer with.
    @Test func withNoModelInstalledTheServiceIsNeverAsked() async {
        let service = Service()
        let empty = ModelStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let access = LocalModelAccess(client: ModelClient(connect: { service.connect($0) }), store: empty)
        #expect(await access.ask(Self.question) == .failure(.notInstalled))
        await access.prewarm()
        #expect(service.sessions.withLock { $0 } == 0)
    }
}
