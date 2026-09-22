import Foundation
import Testing
@testable import XiaolaiDict
import XiaolaiDictCore
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

        struct Died: Error {}

        struct Transport: ModelTransport {
            let service: Service
            func send(_ request: ModelRequest) async throws -> ModelReply {
                service.asked.withLock { $0.append(request) }
                if service.dies.withLock({ $0 }) { throw Died() }
                return request == .prewarm ? .prewarmed : .sense(1)
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
        let client = ModelClient(connect: { service.connect($0) }, serviceIsRunning: { false })
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
            connect: { service.connect($0) }, serviceIsRunning: { running.withLock { $0 } },
            shutdownLimit: .milliseconds(50))
        #expect(await client.unload() == false, "a service still running was reported as ended")

        running.withLock { $0 = false }
        #expect(await client.unload(), "a process that had gone was reported as still there")
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
