import Capture
import Foundation

/// Everything `HoverReader` asks of the screen — **the seam its tests replace.**
///
/// The reader's own decisions — the gate, the order of the paths, acceptance, the capture guard —
/// were reachable only through a real pointer over a real app, so they were checked by grepping
/// its source. Behind this they are driven with a word source that answers whatever a test needs.
protocol ScreenWordSource: Sendable {
    /// The compositor's on-screen windows, front to back, every level.
    func listedWindows() -> [ListedWindow]
    /// Who owns the pixel, through Accessibility, without reading any text.
    func target(at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow]) async -> ScreenWordReader.TargetOutcome
    /// The site `target` shows, if it is a web page — asked only when the reader excluded a site.
    func host(of target: ScreenWordReader.Target, budget: Duration) async -> HostReading
    /// The word at `point` in `target`, through Accessibility, within `budget`.
    func read(at point: CGPoint, in target: ScreenWordReader.Target, budget: Duration) async -> ScreenWordReader.Outcome
    /// The word at `point` read off the pixels of `window`, which the caller chose.
    func recognise(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition
}

/// The real screen.
struct SystemScreenWords: ScreenWordSource {
    let recogniser: ScreenTextRecogniser

    init(recogniser: ScreenTextRecogniser = ScreenTextRecogniser()) {
        self.recogniser = recogniser
    }

    func listedWindows() -> [ListedWindow] { ScreenWordReader.listedWindows() }

    /// Through `AccessibilityLane`: detached, because Accessibility is synchronous IPC and a hung
    /// app must not stall the main actor; one at a time with the selection shortcut's reads; and
    /// **the caller's cancellation passed on**, which a detached task does not inherit. Without that
    /// a reader who moved on left the read running to its end.
    func target(at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow]) async -> ScreenWordReader.TargetOutcome {
        await AccessibilityLane.system.run(timeout: ScreenWordReader.messagingTimeout) {
            ScreenWordReader.target(at: point, windows: windows)
        } cancelled: {
            .none("the reader moved on")
        }
    }

    func host(of target: ScreenWordReader.Target, budget: Duration) async -> HostReading {
        await AccessibilityLane.system.run(timeout: ScreenWordReader.messagingTimeout) {
            ScreenWordReader.host(of: target, with: AccessibilitySession(budget: budget))
        } cancelled: {
            .unreadable
        }
    }

    func read(at point: CGPoint, in target: ScreenWordReader.Target, budget: Duration) async -> ScreenWordReader.Outcome {
        await AccessibilityLane.system.run(timeout: ScreenWordReader.messagingTimeout) {
            ScreenWordReader.read(at: point, in: target, budget: budget)
        } cancelled: {
            .cancelled
        }
    }

    func recognise(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition {
        try await recogniser.read(at: point, window: window, policy: policy)
    }
}
