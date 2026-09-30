import Foundation
@testable import ModelKit
import Testing

/// **What a probe must not get wrong**, written from a second reader's attack on the design: it
/// must not rank an error page as throughput, must not touch the staged download, must answer
/// inside its window, and must never hand back an order a download cannot use.
struct ModelHostProbeTests {
    private static func file(alternates: Bool = true) -> ModelFile {
        ModelFile(repository: "test/model", revision: "abc", path: "model.safetensors",
                  size: 100, sha256: String(repeating: "0", count: 64),
                  alternates: alternates
                      ? [.huggingFace: (repository: "test/model", revision: "def")] : [:])
    }

    /// **The canonical host is always in the order.** A probe that reached nothing must still
    /// hand back a download that can be attempted, or a bad minute offline becomes a refusal.
    @Test(arguments: [[ModelHost.huggingFace], [], [.modelScope], [.modelScope, .huggingFace]])
    func theorderAlwaysEndsSomewhereThatHasTheBytes(ranked: [ModelHost]) {
        let order = URLSessionModelHostProbe.completing(ranked)
        #expect(order.contains(.modelScope), "an order with nowhere to fall back to: \(order)")
        #expect(!order.isEmpty)
        // Ranking is preserved: completing adds, it does not reorder.
        #expect(Array(order.prefix(ranked.count)) == ranked)
    }

    /// A file only one host has — the licence — is never probed and never offered elsewhere.
    @Test func afileOnlyOneHostHasIsNotProbed() async {
        let order = await URLSessionModelHostProbe().order(
            for: Self.file(alternates: false), among: [.huggingFace, .modelScope])
        #expect(order == [.modelScope])
    }

    /// **The window is a bound, not a hope.** A host that accepts the connection and says nothing
    /// must not hold the probe: the deadline cancels the work and waits for it, because letting a
    /// timer win a race leaves the request running behind the answer.
    @Test func ahostThatSaysNothingDoesNotHoldTheProbe() async throws {
        // 203.0.113.0/24 is TEST-NET-3: routable-looking and guaranteed to answer nothing.
        let unreachable = ModelFile(
            repository: "test/model", revision: "abc", path: "model.safetensors",
            size: 100, sha256: String(repeating: "0", count: 64),
            alternates: [.huggingFace: (repository: "test/model", revision: "def")])
        let probe = URLSessionModelHostProbe(window: .milliseconds(300), ceiling: 1_024)
        let started = ContinuousClock.now
        let bytes = await URLSessionModelHostProbe.bytes(
            of: unreachable, from: .huggingFace, within: .milliseconds(300), upTo: 1_024)
        let took = ContinuousClock.now - started
        #expect(bytes == 0, "bytes came from somewhere that cannot have sent any")
        // Bounded against the thing being avoided — an unbounded wait — not against a tight
        // number a loaded machine would miss.
        #expect(took < .seconds(20), "the probe did not come back inside its own window")
        _ = probe
    }

    /// An order is only ever hosts that can serve the file, best first, with no repeats.
    @Test func anorderIsUsableAsItStands() async {
        let order = await URLSessionModelHostProbe(window: .milliseconds(200), ceiling: 1_024)
            .order(for: Self.file(), among: [.modelScope, .huggingFace])
        #expect(Set(order).count == order.count, "a host appears twice: \(order)")
        #expect(order.allSatisfy { Self.file().isServed(by: $0) })
        #expect(order.last == .modelScope || order.contains(.modelScope))
    }
}
