@testable import XiaolaiDict
import XiaolaiDictCore
import Synchronization
import Testing

/// The client's policy around the service: fallback, session replacement after a crash, and which
/// session a late failure may touch. The transport is faked; `XiaolaiDict --lookup` covers the real one.
struct DictionaryClientTests {
    private static let entries = NonEmpty([
        DictionaryEntry(dictionary: "Oxford", headword: "ephemeral", lookedUp: "ephemeral", html: "<html/>"),
    ])!

    @Test func entriesPassThrough() async throws {
        let service = FakeService { _ in .entries(Self.entries, unreadable: ["Wikipedia"]) }
        let client = service.client()
        #expect(try await client.lookup("ephemeral") == .entries(Self.entries, unreadable: ["Wikipedia"]))
    }

    /// Recorded with each lookup: the service answered, or the plain-text fallback had to.
    @Test func eachOutcomeSaysWhatAnsweredIt() {
        #expect(LookupOutcome.entries(Self.entries, unreadable: []).answeredBy == .dictionaryService)
        #expect(LookupOutcome.notFound(serviceFailure: nil).answeredBy == .dictionaryService)
        #expect(LookupOutcome.plainText("plain", serviceFailure: "down").answeredBy == .publicFallback)
        #expect(LookupOutcome.notFound(serviceFailure: "down").answeredBy == .publicFallback)
    }

    @Test func aMissIsNotFoundWithoutAFailure() async throws {
        let client = FakeService { _ in .notFound }.client()
        #expect(try await client.lookup("qzxqzx") == .notFound(serviceFailure: nil))
    }

    /// A reply that is a failure falls back to plain text and says why — and keeps the session: the
    /// service answered, so it is alive.
    @Test func aFailedReplyFallsBackAndSaysWhy() async throws {
        let service = FakeService { _ in .failure(.dictionaryServicesUnavailable("no DCSGetActiveDictionaries")) }
        let client = service.client(fallback: { _ in "plain" })
        #expect(try await client.lookup("ephemeral")
            == .plainText("plain", serviceFailure: "DictionaryServices unavailable: no DCSGetActiveDictionaries"))
        #expect(await client.openSessionGeneration == 1)
    }

    /// A transport that fails is dropped, and the next lookup opens a fresh one.
    @Test func aBrokenSessionIsReplaced() async throws {
        struct Broken: Error {}
        let service = FakeService { connection in
            if connection == 1 { throw Broken() }
            return .entries(Self.entries, unreadable: [])
        }
        let client = service.client(fallback: { _ in nil })
        guard case .notFound(let failure?) = try await client.lookup("ephemeral") else {
            Issue.record("expected a failure to be reported")
            return
        }
        #expect(failure.contains("Broken"))
        #expect(service.cancelled(1), "the failed session was not cancelled")
        #expect(try await client.lookup("ephemeral") == .entries(Self.entries, unreadable: []))
        #expect(service.connections == 2)
    }

    @Test func aHungServiceIsAbandonedAtTheDeadline() async throws {
        let service = FakeService { _ in
            try await Task.sleep(for: .seconds(30))
            return .notFound
        }
        let client = service.client(deadline: .milliseconds(100), fallback: { _ in "plain" })
        guard case .plainText("plain", let failure) = try await client.lookup("ephemeral") else {
            Issue.record("expected the fallback")
            return
        }
        #expect(failure.contains("no answer within"))
    }

    /// Found by audit. Lookup A waits on session 1; the service dies, session 1's cancellation drops
    /// it, and lookup B opens session 2. When A's failure finally arrives it must cancel session 1
    /// — the one it used — not session 2, which B and everything after it is using.
    @Test func aLateFailureDoesNotTouchTheNewerSession() async throws {
        let gate = Gate()
        let service = FakeService { connection in
            if connection == 1 {
                await gate.wait()
                throw ServiceDied()
            }
            return .entries(Self.entries, unreadable: [])
        }
        let client = service.client(fallback: { _ in nil })

        let lookupA = Task { try await client.lookup("a") }
        await service.waitForSend(on: 1)
        service.die(1)
        for _ in 0..<200 where await client.openSessionGeneration != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await client.openSessionGeneration == nil, "the dead session was not forgotten")

        #expect(try await client.lookup("b") == .entries(Self.entries, unreadable: []))
        gate.open()
        _ = try await lookupA.value

        #expect(await client.openSessionGeneration == 2, "A's late failure dropped B's session")
        #expect(!service.cancelled(2), "A's late failure cancelled B's session")
        #expect(try await client.lookup("c") == .entries(Self.entries, unreadable: []))
        #expect(service.connections == 2, "a healthy session was replaced")
    }

    /// Cancelled by a newer lookup: the caller hears so at once, and the session — which did nothing
    /// wrong — is kept.
    @Test func cancellationIsTheCallersNotTheServices() async throws {
        let service = FakeService { _ in
            try await Task.sleep(for: .seconds(30))
            return .notFound
        }
        let client = service.client(fallback: { _ in "plain" })
        let lookup = Task { try await client.lookup("ephemeral") }
        await service.waitForSend(on: 1)
        lookup.cancel()
        await #expect(throws: CancellationError.self) { try await lookup.value }
        #expect(await client.openSessionGeneration == 1)
        #expect(!service.cancelled(1))
    }
}

private struct ServiceDied: Error {}

/// A scripted service. Each connection is numbered from 1; `reply` gets the number.
private final class FakeService: Sendable {
    private struct State {
        var connections = 0
        var cancelled: Set<Int> = []
        var sent: Set<Int> = []
        var onCancel: [Int: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())
    private let reply: @Sendable (Int) async throws -> LookupReply

    init(reply: @escaping @Sendable (Int) async throws -> LookupReply) {
        self.reply = reply
    }

    var connections: Int { state.withLock { $0.connections } }
    func cancelled(_ connection: Int) -> Bool { state.withLock { $0.cancelled.contains(connection) } }

    func client(deadline: Duration = .seconds(3), fallback: @escaping @Sendable (String) -> String? = { _ in nil }) -> DictionaryClient {
        DictionaryClient(deadline: deadline, connect: { onCancel in
            let number = self.state.withLock { state in
                state.connections += 1
                state.onCancel[state.connections] = onCancel
                return state.connections
            }
            return Transport(service: self, number: number)
        }, fallback: fallback)
    }

    /// The service process died: the transport's own cancellation handler fires.
    func die(_ connection: Int) {
        state.withLock { $0.onCancel[connection] }?()
    }

    func waitForSend(on connection: Int) async {
        while !state.withLock({ $0.sent.contains(connection) }) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    fileprivate struct Transport: DictionaryTransport {
        let service: FakeService
        let number: Int

        func send(_ request: LookupRequest) async throws -> LookupReply {
            service.state.withLock { _ = $0.sent.insert(number) }
            return try await service.reply(number)
        }

        func cancel(reason: String) {
            service.state.withLock { _ = $0.cancelled.insert(number) }
        }
    }
}

/// Holds its waiters until opened.
private final class Gate: Sendable {
    private let opened = Mutex(false)

    func open() { opened.withLock { $0 = true } }

    func wait() async {
        while !opened.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
