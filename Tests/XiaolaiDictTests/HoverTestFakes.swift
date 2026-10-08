import AppKit
import ApplicationServices
import Capture
import CaptureModel
import DictionaryModel
@testable import MacCapture
import Synchronization
import Testing

/// The stand-ins hover's behavioural tests share — **one spelling each**, for the reason
/// `Wiring` gives: two copies of a fake drift, and then a test proves something about the copy.

/// Events a test emits by hand.
@MainActor
final class ScriptedHoverEvents: HoverEventSource {
    private var handler: (@MainActor (HoverEvent) -> Void)?
    var installs = true
    private(set) var stops = 0

    func start(_ handler: @escaping @MainActor (HoverEvent) -> Void) -> Bool {
        guard installs else { return false }
        self.handler = handler
        return true
    }

    func stop() {
        handler = nil
        stops += 1
    }

    var isStarted: Bool { handler != nil }

    func emit(_ event: HoverEvent) { handler?(event) }

    /// Down, up, down with the event's own times.
    func doubleTap(from instant: TimeInterval, modifier: HoverModifier = .option) {
        emit(.modifiers([modifier], at: instant, location: nil))
        emit(.modifiers([], at: instant + 0.08, location: nil))
        emit(.modifiers([modifier], at: instant + 0.2, location: nil))
    }
}

/// Where the pointer is and what is held, set by the test.
@MainActor
final class ScriptedPointer {
    var at = UpPoint(x: 100, y: 100)
    var held: Set<HoverModifier> = []
    func read() -> (UpPoint, Set<HoverModifier>) { (at, held) }
}

/// A settle timer the test fires.
@MainActor
final class ManualSchedule {
    private var pending: [Int: @MainActor () -> Void] = [:]
    private var serial = 0

    var armed: Int { pending.count }

    func schedule(_ delay: Duration, _ work: @escaping @MainActor () -> Void) -> HoverWatcher.Cancel {
        serial += 1
        let mine = serial
        pending[mine] = work
        return { [weak self] in self?.pending[mine] = nil }
    }

    /// Runs whatever is armed, as the timer would.
    func fire() {
        let due = pending
        pending.removeAll()
        for key in due.keys.sorted() { due[key]?() }
    }
}

/// A reader whose reads end when the test says so.
@MainActor
final class ScriptedHoverReader: HoverReading {
    struct Ask: Equatable {
        let point: CGPoint
        let held: Set<HoverModifier>
        let tapped: Bool
        let request: Int
    }

    var onCaptureReleased: (@MainActor () -> Void)?
    var onCaptureHealth: (@MainActor (CaptureHealth) -> Void)?
    private(set) var asks: [Ask] = []
    private(set) var remembered: [String] = []
    private var waiting: [CheckedContinuation<HoverReader.Outcome, Never>] = []

    var pendingReads: Int { waiting.count }

    func read(
        at point: CGPoint, modifiersHeld: Set<HoverModifier>, tappedTwice: Bool,
        pointerStillFor: Duration, begin: @MainActor () -> Int
    ) async -> HoverReader.Outcome {
        asks.append(Ask(point: point, held: modifiersHeld, tapped: tappedTwice, request: begin()))
        return await withCheckedContinuation { waiting.append($0) }
    }

    func remember(_ key: String) { remembered.append(key) }

    private(set) var forgotten: [String] = []
    func forget(_ key: String) { forgotten.append(key) }

    private(set) var hoversEnded = 0
    func endHover() { hoversEnded += 1 }

    /// Ends the oldest read in flight with a word, for the request it was given.
    func answerWord(_ text: String = "hold") {
        guard let ask = asks.last else { return }
        answer(.selection(HoverFixtures.selection(text), request: ask.request, key: "key-\(text)-\(ask.request)"))
    }

    func answer(_ outcome: HoverReader.Outcome) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: outcome)
    }
}

/// The app's side: a request sequence and a list of what was delivered.
@MainActor
final class RecordingDelivery: HoverDelivering {
    var requests = RequestSequence()
    private(set) var delivered: [(text: String, at: UpPoint, request: Int, requestedAt: Date)] = []

    func beginRequest() -> Int { requests.begin() }

    func deliver(_ selection: Selection, at pointer: UpPoint, request: Int, requestedAt: Date,
                 askedAt: ContinuousClock.Instant, seen: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard requests.claim(request) else { return false }
        delivered.append((selection.text, pointer, request, requestedAt))
        seens.append(seen)
        return true
    }

    /// Each delivery's `seen`, for a test to answer as the compositor would.
    private(set) var seens: [@MainActor (Bool) -> Void] = []

    private(set) var screenRecordingNotices = 0

    func screenRecordingNeeded(at pointer: UpPoint, request: Int) -> Bool {
        screenRecordingNotices += 1
        return true
    }
}

/// A screen whose Accessibility and pixels answer what the test scripted.
final class ScriptedScreenWords: ScreenWordSource, @unchecked Sendable {
    /// Read only after the test has set it up, from the one read in flight.
    var targetOutcome: ScreenWordReader.TargetOutcome = .none("nothing scripted")
    var readOutcome: ScreenWordReader.Outcome = .miss("nothing scripted")
    var recognition: Result<Recognition, any Error> = .failure(RecognitionError.nothingUnderPointer)
    var windows: [ListedWindow] = []
    private(set) var recognitions = 0

    func listedWindows() -> [ListedWindow] { windows }

    func target(at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow]) async -> ScreenWordReader.TargetOutcome {
        targetOutcome
    }

    var hostReading: HostReading = .notWebContent
    private(set) var hostsAsked = 0

    func host(of target: ScreenWordReader.Target, budget: Duration) async -> HostReading {
        hostsAsked += 1
        return hostReading
    }

    func read(at point: CGPoint, in target: ScreenWordReader.Target, budget: Duration) async -> ScreenWordReader.Outcome {
        readOutcome
    }

    private(set) var recognisedWindows: [ListedWindow] = []
    /// When set, a capture does not return until `finishCapture()` — a wedged ScreenCaptureKit call.
    var hangs = false
    /// Whether the captures have been let go, and who is still waiting. **Released is remembered**:
    /// a capture whose task is scheduled only after `finishCapture()` must return at once rather than
    /// wait for a release that already happened — under a busy run that race hung the whole suite.
    private let hung = Mutex<(released: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    func recognise(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition {
        recognitions += 1
        recognisedWindows.append(window)
        if hangs {
            await withCheckedContinuation { continuation in
                let released = hung.withLock { state -> Bool in
                    if !state.released { state.waiting.append(continuation) }
                    return state.released
                }
                if released { continuation.resume() }
            }
        }
        return try recognition.get()
    }

    /// Lets every hung capture return, and every later one too.
    func finishCapture() {
        let waiting = hung.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

enum HoverFixtures {
    /// A capture deadline for tests that are not about the deadline. The shipped 5 s fired under a
    /// busy full-suite run, and a test about consent then failed on a deadline it never mentioned.
    static let patient: Duration = .seconds(600)

    static func selection(_ text: String, in bundleID: String = "com.apple.TextEdit") -> Selection {
        Selection(
            text: text, sentence: text, rangeInSentence: NSRange(location: 0, length: text.utf16.count),
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            place: ReadingPlace(bundleID: bundleID, name: "TextEdit"))
    }

    /// An Accessibility target in an app that is not this one. The element is never asked anything:
    /// the scripted screen answers instead.
    static func target(bundleID: String = "com.apple.TextEdit") -> ScreenWordReader.Target {
        ScreenWordReader.Target(element: AXUIElementCreateApplication(getpid() + 1), appName: "TextEdit", bundleID: bundleID)
    }

    /// An Accessibility hit on `word`, as the text-range dialect reports one.
    static func hit(_ word: String, bundleID: String = "com.apple.TextEdit") -> ScreenWordReader.Outcome {
        guard let found = TextSegmenter.word(in: word, utf16Offset: 0) else { return .miss("no word in \(word)") }
        return .hit(ScreenWordReader.Hit(word: found, source: .accessibilityTextRange, appName: "TextEdit", bundleID: bundleID))
    }

    /// Lets started work run until `condition` holds — waiting for the work, not for a call that
    /// started it. **Yields first, then sleeps a millisecond a turn**: work on the cooperative pool
    /// is not scheduled by the main actor's yields, and under a full parallel run two thousand bare
    /// yields went by before a released capture's task had run at all. The bound only stops a
    /// failure hanging; nothing here asserts how long anything took.
    /// Lets already-started work run, for an assertion that something did **not** happen. Short on
    /// purpose: it cannot prove an absence, only give the absence a fair chance to be broken — so a
    /// slow machine can make it miss a defect, never invent one.
    @MainActor
    static func drain() async {
        for turn in 0..<250 {
            if turn < 200 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
        }
    }

    @MainActor
    static func settle(until condition: @MainActor () -> Bool) async {
        for turn in 0..<12_000 where !condition() {
            if turn < 200 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
        }
    }
}
