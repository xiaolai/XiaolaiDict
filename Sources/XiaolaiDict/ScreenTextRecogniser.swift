import XiaolaiDictCore
import XiaolaiDictUI
@preconcurrency import ScreenCaptureKit
@preconcurrency import Vision

/// What the recogniser saw: where it looked, what it read, and how far to trust it.
struct Recognition: Sendable {
    let word: WordAtPoint
    /// Vision's confidence in the line the word came from, 0...1.
    let confidence: Double
    /// The recognised text ran into the edge of the capture, so the sentence may be cut — or
    /// worse, spliced from two cut lines into one that reads fine and was never on screen.
    let mayBeCut: Bool
    let appName: String?
    let bundleID: String?
}

enum RecognitionError: LocalizedError {
    case noDisplay(CGPoint)
    /// The display exists but ScreenCaptureKit does not offer it — seen while the screen is locked.
    case displayNotCapturable(CGDirectDisplayID)
    case nothingUnderPointer
    /// The window under the pointer belongs to an app XiaolaiDict does not read.
    case excludedApp(String)
    /// No window under the pointer, so the capture could not be attributed to any app — and an
    /// unattributable region cannot be checked against the exclusion list.
    case unattributable
    /// Screen Recording is off for XiaolaiDict, and asking produced no grant.
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        // Formatted as a Double, not an Int: `Int(1e100)` traps, and the point reaches here
        // straight from a caller — `--read-point 1e100 0` passes a finite-number check.
        case .noDisplay(let point):
            "no display contains (\(String(format: "%.0f", point.x)), \(String(format: "%.0f", point.y)))"
        // No longer "or Screen Recording is off": that is its own case now, checked before the
        // capture, so this one means what it says.
        case .displayNotCapturable: "the screen is locked"
        case .nothingUnderPointer: "no word under the pointer"
        case .excludedApp(let name): "XiaolaiDict does not look things up in \(name)"
        case .unattributable: "no window under the pointer"
        case .screenRecordingDenied:
            "XiaolaiDict needs Screen Recording to read words off the screen. Allow it in "
                + "\(PrivacySettings.screenRecordingLocation), then try again."
        }
    }
}

/// The last path: capture the window under the pointer and read it with Vision, on-device.
///
/// It is the slow one — **250–570 ms warm, 0.8–1.8 s cold**, against 1–9 ms for Accessibility —
/// and the only one that can be *wrong* rather than merely absent. It exists because some surfaces
/// expose no text at all: a terminal, a canvas, an image.
final class ScreenTextRecogniser: Sendable {
    /// A band the full width of the window, tall enough for a sentence that wraps.
    ///
    /// Not a box around the pointer: that scope **fabricates sentences**. Two visible line
    /// fragments were joined into one that reads perfectly and was never on screen. A band costs
    /// 349 ms against the box's 267 ms and gets the sentence whole.
    static let bandHeight: CGFloat = 140
    /// Used only when there is no window under the pointer to scope to.
    static let displayRegion = CGSize(width: 420, height: 100)

    private let cache = ShareableContentCache()

    /// `excluding` is checked against the window's owner **before any pixel is captured**. The
    /// Accessibility path cannot vet an app that exposes no element, and that is exactly the case
    /// this path serves — so the exclusion has to be enforced here too, not only afterwards.
    /// Whether XiaolaiDict may capture at all. Injectable so the refusal can be tested; `.system` asks
    /// CoreGraphics.
    let access: ScreenRecordingAccess

    init(access: ScreenRecordingAccess = .system) {
        self.access = access
    }

    func read(at point: CGPoint, excluding: Set<String> = []) async throws -> Recognition {
        // Asked before anything is attempted. `SCShareableContent` needs this permission too, so
        // without it every call below fails with a message about capture rather than about consent
        // — which is exactly how a machine with Accessibility granted and Screen Recording not
        // reported "no word under the pointer" and hid the real answer.
        guard access.ensure() else { throw RecognitionError.screenRecordingDenied }
        let target = try await target(at: point)
        // An owner XiaolaiDict cannot name cannot be checked against the exclusion list, and a region it
        // cannot attribute is a region it must not read: a display-scoped capture could contain a
        // password manager's window and no check would ever see it. Refusing is the only honest
        // option — the case it gives up is the desktop, where there is nothing to look up anyway.
        guard let bundleID = target.bundleID else { throw RecognitionError.unattributable }
        if excluding.contains(bundleID) {
            throw RecognitionError.excludedApp(target.appName ?? bundleID)
        }
        let config = SCStreamConfiguration()
        config.sourceRect = target.sourceRect
        config.width = Int(target.region.width * CGFloat(target.filter.pointPixelScale))
        config.height = Int(target.region.height * CGFloat(target.filter.pointPixelScale))
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: target.filter, configuration: config)
        let lines = try recognise(image)

        let cursor = CaptureGeometry.normalized(point, in: target.region)
        // The shared tolerance, expressed in the capture's normalised units.
        let slack = CGSize(
            width: HitTolerance.horizontal / target.region.width,
            height: HitTolerance.vertical / target.region.height)
        guard let pick = RecognisedTextPicker.pick(
            at: cursor, in: lines, slack: slack, region: target.region.size) else {
            throw RecognitionError.nothingUnderPointer
        }
        // A sentence outruns its line, so segment over the whole block of lines around it.
        let block = LineJoiner.block(around: pick.line, in: lines)
        let clipped = CaptureEdge.clips(block.lineIndices.map { lines[$0].box })
        guard let word = TextSegmenter.word(
            in: block.text,
            utf16Offset: block.offsetShift + lines[pick.line].words[pick.word].utf16Offset,
            clipped: clipped ? [.start, .end] : [])
        else { throw RecognitionError.nothingUnderPointer }

        return Recognition(
            word: word, confidence: lines[pick.line].confidence, mayBeCut: clipped,
            appName: target.appName, bundleID: target.bundleID)
    }

    private struct Target {
        let filter: SCContentFilter
        /// In global screen points.
        let region: CGRect
        /// The same region in the filter's own coordinates.
        let sourceRect: CGRect
        let appName: String?
        let bundleID: String?
    }

    private func target(at point: CGPoint) async throws -> Target {
        if let window = try await windowUnderPointer(point) {
            let frame = window.frame
            let region = CaptureGeometry.rect(
                around: point, size: CGSize(width: frame.width, height: Self.bandHeight), within: frame)
            // `sourceRect` is window-local and starts at (0, 0), even though `filter.contentRect`
            // reports the window's frame in *global* screen coordinates. Adding that origin puts
            // the rect outside the window and the capture fails with "invalid parameter" — and
            // nothing in the API says which convention is which.
            return Target(
                filter: SCContentFilter(desktopIndependentWindow: window), region: region,
                sourceRect: CGRect(
                    origin: CGPoint(x: region.minX - frame.minX, y: region.minY - frame.minY),
                    size: region.size),
                appName: window.owningApplication?.applicationName,
                bundleID: window.owningApplication?.bundleIdentifier)
        }

        var displayID = CGDirectDisplayID()
        var matches: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &matches) == .success, matches == 1 else {
            throw RecognitionError.noDisplay(point)
        }
        var content = try await shareableContent()
        if !content.displays.contains(where: { $0.displayID == displayID }) {
            content = try await shareableContent(refresh: true)  // cached while locked, or a display appeared
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecognitionError.displayNotCapturable(displayID)
        }
        let bounds = CGDisplayBounds(displayID)
        // No window to scope to, so keep XiaolaiDict's own panel out of the capture by hand.
        let own = content.applications.filter { $0.processID == getpid() }
        let region = CaptureGeometry.rect(around: point, size: Self.displayRegion, within: bounds)
        return Target(
            filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
            region: region, sourceRect: region.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
            appName: nil, bundleID: nil)
    }

    /// The frontmost ordinary window under the pointer, XiaolaiDict's own excluded. `CGWindowList` is
    /// ordered front to back, which `SCShareableContent` does not promise.
    private func windowUnderPointer(_ point: CGPoint) async throws -> SCWindow? {
        guard let listed = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in listed {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != getpid(),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let frame = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({
                      CGRect(dictionaryRepresentation: $0 as CFDictionary)
                  }),
                  frame.contains(point)
            else { continue }
            // The window is *found* from live bounds but its geometry comes from the cached
            // `SCWindow`, which is up to three seconds old. Move or resize a window inside that
            // window and the capture crops the place it used to be — a miss, or worse, the wrong
            // word read confidently. So the cached frame is checked against the live one.
            if let window = try await shareableContent().windows.first(where: { $0.windowID == id }),
               Self.sameGeometry(window.frame, frame) {
                return window
            }
            return try await shareableContent(refresh: true).windows.first { $0.windowID == id }
        }
        return nil
    }

    /// Frames are compared with a tolerance: the two APIs round independently, and a sub-point
    /// disagreement is not a moved window.
    static func sameGeometry(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The window and display list, cached briefly. Fetching it is the dominant cost of this whole
    /// path and — unlike the capture and the recognition — it never gets cheaper with use.
    ///
    /// Measured on this machine, three passes: every window, on screen or not, is 402 windows and
    /// 436-566 ms. **On-screen only is 37 windows and 60-85 ms** — six to seven times faster, every
    /// time, warm or cold. The comment this replaces estimated 200 ms, which was optimistic by half.
    ///
    /// On-screen only is not merely faster, it is the right question. The candidate window is found
    /// by `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` and is then looked up here by id,
    /// so a window this call adds beyond that list can never match. A window under the pointer is
    /// on screen by definition.
    private func shareableContent(refresh: Bool = false) async throws -> SCShareableContent {
        if !refresh, let cached = cache.current(newerThan: .seconds(3)) { return cached }
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cache.store(fresh)
        return fresh
    }

    private func recognise(_ image: CGImage) throws -> [RecognisedLine] {
        let request = VNRecognizeTextRequest()
        // `.fast` is 10× quicker and truncates words — "rendipity", "repa". For a dictionary a
        // wrong word is worse than a miss.
        request.recognitionLevel = .accurate
        // A dictionary exists for the rare words, and language correction "fixes" them into
        // common ones.
        request.usesLanguageCorrection = false
        // **Never pin the language — detect it.** Pinned `en-US` reads Chinese as Latin garbage;
        // pinned `zh-Hans` reads Latin at confidence 0.5, turning terminal text into "exthdt6n6"
        // and ASCII punctuation into fullwidth forms, and misreads 今天 as 念天. Detection reads
        // both at 1.0 — and is faster (524 ms against 1171 ms on the same image).
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            let words = TextSegmenter.wordRanges(in: text).compactMap { range -> RecognisedWord? in
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { return nil }
                return RecognisedWord(
                    text: String(text[range]),
                    utf16Offset: text.utf16.distance(from: text.startIndex, to: range.lowerBound),
                    box: CaptureGeometry.flippedFromVision(box))
            }
            return RecognisedLine(
                text: text, box: CaptureGeometry.flippedFromVision(observation.boundingBox),
                words: words, confidence: Double(candidate.confidence))
        }
    }
}

/// A short-lived cache for ScreenCaptureKit's window list.
///
/// Behind a plain lock rather than inside an actor, and the lock is **never held across an
/// `await`**: one wedged capture inside an actor serialises every later lookup behind it and takes
/// them all down. That is what made an actor the wrong shape here.
private final class ShareableContentCache: @unchecked Sendable {  // read-only once built
    private let lock = NSLock()
    private var value: SCShareableContent?
    private var fetched: ContinuousClock.Instant?

    func current(newerThan age: Duration) -> SCShareableContent? {
        lock.lock()
        defer { lock.unlock() }
        guard let value, let fetched, ContinuousClock.now - fetched < age else { return nil }
        return value
    }

    func store(_ content: SCShareableContent) {
        lock.lock()
        defer { lock.unlock() }
        value = content
        fetched = .now
    }
}
