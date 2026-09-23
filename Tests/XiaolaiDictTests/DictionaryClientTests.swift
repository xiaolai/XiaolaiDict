@testable import XiaolaiDict
import Foundation
import XiaolaiDictCore
import Synchronization
import Testing

/// The client's policy around the service: fallback, session replacement after a crash, and which
/// session a late failure may touch. The transport is faked; `XiaolaiDict --lookup` covers the real one.
struct DictionaryClientTests {
    private static let entries = NonEmpty([
        DictionaryEntry(dictionary: DictionaryIdentity(name: "Oxford"), headword: "ephemeral", lookedUp: "ephemeral", html: "<html/>", document: nil),
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

/// **The two service clients ask one question the same way, and this is what holds them to it.**
///
/// `ServiceSessions` exists because each client had kept its own copy of the session policy and
/// the copies had drifted. The catch clause drifted afterwards, the other way about: the model
/// client asks the *thrown error* whether the caller was superseded, the dictionary client asked
/// `Task.isCancelled` — so a transport failure or a deadline landing in the same moment a newer
/// lookup replaced this one was read as harmless, and the wedged session was kept and handed to
/// every lookup after it.
///
/// **Mechanical because a behavioural check cannot decide it.** `withDeadline` is first-wins and
/// settles `CancellationError` the instant the calling task is cancelled, so no test can force a
/// transport failure to be the error in hand while the caller is already cancelled: every
/// cancellation arrangeable from outside arrives as a `CancellationError`, which both spellings
/// read identically. The spelling is what can fail, so the spelling is what is read.
///
/// The scan is as wide as the one spelling it looks for — a `catch` guarded by
/// `where Task.isCancelled` — with whitespace removed so a wrapped clause is the same string as a
/// one-line one. A cancellation read off the task some other way is not something it can see.
struct DictionaryClientCancellationDriftTests {
    private static let clients = ["DictionaryClient.swift", "ModelClient.swift"]

    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
    }

    @Test func bothClientsAskTheThrownErrorAndNotTheTask() throws {
        for client in Self.clients {
            let file = Self.sources.appending(path: "XiaolaiDict/\(client)")
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(code.contains("catch is CancellationError where Task.isCancelled"),
                    "\(client) does not keep its session for a caller that was superseded")
        }
    }

    /// And nowhere else either: an unqualified clause anywhere in `Sources` reads a service that
    /// failed as a caller that moved on.
    @Test func noCatchInTheSourcesReadsCancellationOffTheTask() throws {
        let root = Self.sources
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { throw ScanFailure.unreadable(root.path) }

        // `catch` … `where Task.isCancelled`, with whatever pattern stands between them.
        let cancellationCatch = #/catch (?<pattern>[^{]*?)where Task\.isCancelled/#
        var scanned = 0
        var offenders: [String] = []
        for case let file as URL in walk where file.pathExtension == "swift" {
            scanned += 1
            // Thrown rather than defaulted to "": a scanner that silently reads nothing passes
            // forever and guards nothing.
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for match in code.matches(of: cancellationCatch)
            where !match.pattern.contains("is CancellationError") {
                offenders.append("\(file.lastPathComponent): catch \(match.pattern)where Task.isCancelled")
            }
        }

        // The positive control. If the walk ever stops finding files this test would pass while
        // reading nothing at all.
        #expect(scanned > 20, "the scan found \(scanned) Swift files, so it is not reading the sources")
        #expect(offenders.isEmpty, "a cancellation read off the task rather than the error: \(offenders)")
    }

    enum ScanFailure: Error {
        case unreadable(String)
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

        func send(_ request: ServiceRequest) async throws -> ServiceReply {
            service.state.withLock { _ = $0.sent.insert(number) }
            guard case .lookup = request else { return .dictionaries([]) }
            return .lookup(try await service.reply(number))
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
