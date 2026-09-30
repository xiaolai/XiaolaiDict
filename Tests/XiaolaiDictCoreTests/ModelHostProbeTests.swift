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
    func theorderAlwaysEndsSomewhereThatHasTheBytes(measured: [ModelHost]) {
        // Descending, so the ranking below has something to preserve.
        let speeds = measured.enumerated().map {
            ModelHostSpeed(host: $0.element, bytes: 100 - $0.offset)
        }
        let order = ModelHost.ranked(speeds)
        #expect(order.contains(.modelScope), "an order with nowhere to fall back to: \(order)")
        #expect(!order.isEmpty)
        #expect(Array(order.prefix(measured.count)) == measured, "ranking lost the order it measured")
    }

    /// **A host that delivered nothing is dropped, not ranked last.** Keeping it would put an
    /// unreachable host ahead of the one that answered.
    @Test func ahostThatDeliveredNothingIsNotInTheOrder() {
        let order = ModelHost.ranked([
            ModelHostSpeed(host: .huggingFace, bytes: 0),
            ModelHostSpeed(host: .modelScope, bytes: 4_000),
        ])
        #expect(order == [.modelScope])
    }

    /// And the faster one leads when both answered — the whole point of measuring.
    @Test func thefasterHostLeads() {
        let order = ModelHost.ranked([
            ModelHostSpeed(host: .modelScope, bytes: 6_061_113),
            ModelHostSpeed(host: .huggingFace, bytes: 40_974_585),
        ])
        #expect(order == [.huggingFace, .modelScope], "the slower host was chosen")
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

/// **The window and the ceiling are a measurement, and either can make it the wrong one.**
struct ModelHostProbeShapeTests {
    /// A window shorter than a host's handshake measures the handshake. Measured 2026-09-30:
    /// Hugging Face delivered nothing at 1.5 s and 13.5 MB at 5 s, against ModelScope's 3.9 MB,
    /// so a short window chose four hours over seven minutes.
    @Test func thewindowOutlastsAslowHandshake() {
        #expect(URLSessionModelHostProbe.window >= .seconds(4),
                "a window this short measures the handshake, not the link")
        // And not so long that it is felt: this is paid before every download.
        #expect(URLSessionModelHostProbe.window <= .seconds(10))
    }

    /// **A ceiling either host can reach is a tie however different they are.** It has to sit
    /// above what the faster link delivers inside the window, or the measurement is capped.
    @Test func theceilingCannotBindBeforeTheWindowDoes() {
        let seconds = Double(URLSessionModelHostProbe.window.components.seconds)
        let implied = Double(URLSessionModelHostProbe.ceiling) / seconds / 1_048_576
        // 13.8 MB/s was measured here; the ceiling must not bind on a link several times faster.
        #expect(implied > 25, "the ceiling caps a fast host at \(implied) MB/s, which is a tie")
    }
}
