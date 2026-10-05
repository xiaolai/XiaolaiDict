import DictionaryModel
import XiaolaiDictCore
import XiaolaiDictUI
@preconcurrency import ScreenCaptureKit
@preconcurrency import Vision

/// What the recogniser saw: where it looked, what it read, and how far to trust it.
struct Recognition: Sendable {
    let word: WordAtPoint
    /// Vision's lowest confidence among the observations that make up **the sentence in `word`**,
    /// 0...1 — not the line the pointer landed on, and not the whole block the sentence was cut
    /// out of. Both of those describe more or less text than the reader is actually shown.
    let confidence: Double
    /// The **sentence** ran into the edge of the capture, so it may be cut — or worse, spliced
    /// from two cut lines into one that reads fine and was never on screen. Scoped the same way as
    /// `confidence`: a neighbouring sentence touching the edge says nothing about this one.
    let mayBeCut: Bool
    let appName: String?
    let bundleID: String?
}

enum RecognitionError: LocalizedError, Equatable {
    /// The window chosen to read is no longer offered for capture — it closed, or the screen locked.
    case windowNotCapturable
    case nothingUnderPointer
    /// The window under the pointer belongs to an app XiaolaiDict does not read.
    case excludedApp(String)
    /// No window under the pointer, so the capture could not be attributed to any app — and an
    /// unattributable region cannot be checked against the exclusion list.
    case unattributable
    /// Screen Recording is off for XiaolaiDict. Hover does not ask for it; the reader is told where.
    case screenRecordingDenied
    /// The grant could not be read — which is **not** the same as its being absent, and must not be
    /// reported as one. A cold `SCShareableContent` call fails this way, and the next hover will
    /// find the subsystem warm.
    case screenRecordingUnreadable

    var errorDescription: String? {
        switch self {
        // **Says what was established, which is absence and not a reason.** A lock is one way a
        // window leaves `SCShareableContent`; this only knows that it is not in the list.
        case .windowNotCapturable: "that window is not available for capture"
        case .nothingUnderPointer: "no word under the pointer"
        case .excludedApp(let name): "words are not looked up in \(name)"
        case .unattributable: "no window under the pointer"
        case .screenRecordingDenied:
            "XiaolaiDict needs Screen Recording to read words off the screen. Allow it in "
                + "\(PrivacySettings.screenRecordingLocation), then try again."
        // Says nothing about consent, and names no settings pane, because the permission may well
        // be granted — sending the reader to a list where the switch is already on is how a
        // transient failure becomes a support question.
        case .screenRecordingUnreadable: "could not tell whether Screen Recording is allowed"
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

    /// **The widest image, in pixels, Vision is given in one call.** The band is the window's whole width — 5120
    /// px on the dev Mac — and the width of the *image* decides whether small text is read: in one call that band
    /// read 47% of uncommon words exactly on real Ghostty captures (0% at 12 pt, 25–30% at 14 pt) and 2000 px strips
    /// 100%, the one call returning in 24 ms — Vision answering fast with almost nothing. The cliff sits between
    /// 2400 and 2600 px (99.7% and 93.1%), so this is under it with a fifth to spare. Measured at 2x only; the
    /// limit is in pixels because Vision works in them, which is a premise for 1x and 3x and not a result.
    ///
    /// **The band is tiled, not narrowed**: its width is the sentence the reader pointed into, and narrowing it
    /// would have traded the context for the accuracy of the word. `BandTiling` has the rest, and
    /// `ScreenTextRecogniserBandTests` the table.
    static let maximumTilePixels: CGFloat = 2000

    /// How far neighbouring tiles overlap, in pixels: a word on a boundary is whole in one of them when the overlap
    /// reaches half its length past the boundary on each side, so this holds a word of 25 cells at 2x.
    static let tileOverlapPixels: CGFloat = 600

    private let cache = ShareableContentCache()

    /// Whether XiaolaiDict may capture at all. Injectable so the refusal can be tested; `.system`
    /// asks through `Permission.screenRecording`, which probes with `SCShareableContent` — the API
    /// this file captures through. **Not CoreGraphics**, which is what this said and what the rule
    /// in `AGENTS.md` exists to prevent.
    let access: ScreenRecordingAccess

    init(access: ScreenRecordingAccess = .system) {
        self.access = access
    }

    /// Reads `window` — **the one the caller chose, never one of this type's own choosing** — in
    /// a band around `point`. The window's owner is checked against `policy` **before any pixel is
    /// captured**: the Accessibility path cannot vet an app that exposes no element, and that is
    /// exactly the case this path serves.
    func read(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition {
        // **Orchestration only, and every cancellation check lives here** (audit round 3, #31): each
        // stage below is one effect, and nothing new is started for a reader who has moved on.
        try Task.checkCancellation()
        let target = try await authorisedTarget(at: point, window: window, policy: policy)
        // **Nothing new is started for a reader who has moved on.** Resolving the target awaits
        // shareable content, and a hover superseded during that wait would otherwise go on to take
        // a screenshot and run Vision for an answer nobody is waiting for — holding the one-capture
        // guard while it did, so the lookup that *is* wanted queues behind it. Two simultaneous
        // captures deadlock, which is why that guard exists and why occupying it needlessly costs
        // the next lookup rather than only this one.
        try Task.checkCancellation()
        let image = try await capture(target, of: window)
        // Recognition is synchronous and the slowest step after the capture; a cancellation that
        // arrived during the capture should not pay for it.
        try Task.checkCancellation()
        return try Self.hit(in: try recognise(image), at: point, target: target)
    }

    /// Consent, then the window's capture target, then its owner against `policy` — all before a pixel.
    private func authorisedTarget(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Target {
        // Asked before anything is attempted, and **only asked**. `SCShareableContent` needs this
        // permission too, so without it every call below fails with a message about capture rather
        // than about consent — which is how a machine with Accessibility granted and Screen
        // Recording not reported "no word under the pointer" and hid the real answer.
        switch await access.probe() {
        case .granted: break
        case .declined: throw RecognitionError.screenRecordingDenied
        case .couldNotTell: throw RecognitionError.screenRecordingUnreadable
        }
        try Task.checkCancellation()
        let target = try await target(at: point, window: window)
        // An owner XiaolaiDict cannot name cannot be checked against the exclusion list, and a region it
        // cannot attribute is a region it must not read. Refusing is the only honest option.
        guard let bundleID = target.bundleID else { throw RecognitionError.unattributable }
        if CaptureAuthorization.refusal(bundleID: bundleID, policy: policy) != nil {
            throw RecognitionError.excludedApp(target.appName ?? bundleID)
        }
        return target
    }

    /// The band around the pointer, captured — and refused if the window moved while it was taken.
    private func capture(_ target: Target, of window: ListedWindow) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.sourceRect = target.sourceRect
        config.width = Int(target.region.width * CGFloat(target.filter.pointPixelScale))
        config.height = Int(target.region.height * CGFloat(target.filter.pointPixelScale))
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: target.filter, configuration: config)
        // **And still there after it.** A window moved or resized while the capture ran was captured
        // where it used to be, and the pointer would be mapped onto whatever text is now under it.
        guard let after = Self.liveBounds(of: window.windowID), Self.sameGeometry(after, target.frame) else {
            throw RecognitionError.windowNotCapturable
        }
        return image
    }

    /// The recognised word under `point`, or `.nothingUnderPointer`.
    private static func hit(in lines: [RecognisedLine], at point: CGPoint, target: Target) throws -> Recognition {
        let cursor = CaptureGeometry.normalized(point, in: target.region)
        // The shared tolerance, expressed in the capture's normalised units.
        let slack = CGSize(
            width: HitTolerance.horizontal / target.region.width,
            height: HitTolerance.vertical / target.region.height)
        guard let pick = RecognisedTextPicker.pick(
            at: cursor, in: lines, slack: slack, region: target.region.size) else {
            throw RecognitionError.nothingUnderPointer
        }
        guard let read = reading(
            lines, pick: pick, at: cursor, region: target.region.size,
            appName: target.appName, bundleID: target.bundleID)
        else { throw RecognitionError.nothingUnderPointer }
        return read
    }

    /// **The deterministic half of `read`**, separated so it can be exercised without a screen.
    ///
    /// Everything above it is platform effect — consent, window choice, capture, Vision. From here
    /// down it is recognised lines and a pointer, and the answer is a pure function of them. It was
    /// inline, which meant the quality signals below could only be checked by capturing a real
    /// screen, and so were not checked at all.
    static func reading(
        _ lines: [RecognisedLine], pick: RecognisedPick, at cursor: CGPoint, region: CGSize,
        appName: String?, bundleID: String?
    ) -> Recognition? {
        // A sentence outruns its line, so segment over the whole block of lines around it.
        let block = LineJoiner.block(around: pick.line, in: lines, region: region)
        let blockClipped = CaptureEdge.clips(block.lineIndices.map { lines[$0].box })
        // **Which token of the run, decided by the pointer.** A run is all Vision can box, so
        // taking its start meant `/Users/alice/…` answered `Users` wherever in it the reader
        // pointed, and `state-of-the-art` answered `state`. The bounds-scan and text-marker
        // dialects already interpolate for exactly this reason (finding 8); this is the third.
        let run = lines[pick.line].runs[pick.run]
        let within = CaptureGeometry.characterIndex(
            at: cursor.x, across: run.box.minX...run.box.maxX, count: run.text.utf16.count)
        // Nearest, not containing: a separator is one character wide, and landing on the `/` in a
        // path means beside a word rather than away from one.
        let start = TextSegmenter.wordStart(nearest: within, in: run.text) ?? 0
        let offset = block.offsetShift + run.utf16Offset + start
        guard let word = TextSegmenter.word(
            in: block.text, utf16Offset: offset,
            clipped: blockClipped ? [.start, .end] : [])
        else { return nil }

        // **Both quality signals are scoped to the sentence that is actually returned.** The block
        // may hold several sentences and only one of them reaches the reader; the block's minimum
        // confidence marks a perfectly read sentence as doubtful because its neighbour was not,
        // and the block's clipping says a whole interior sentence may be cut when it cannot be.
        let span = Self.span(of: word.sentence, containing: offset, in: block.text)
        let covering = block.lines(covering: span, in: lines)
        let clipped = CaptureEdge.clips(covering.map { lines[$0].box })

        // **One clipping answer, because the two were answering different questions.** The
        // geometric test says an *observation* touches the capture's edge; `SentenceContext`
        // says the *sentence* runs to the text's boundary. Both are needed and neither is the
        // answer alone: one edge-touching observation reading "First sentence. Middle sentence.
        // Last sentence." is clipped geometrically while its middle sentence plainly is not, and
        // reporting the geometric answer told the reader an interior sentence might be cut.
        //
        // So the geometric result is an *input* to the segmenter and the segmenter's is the only
        // output. Cutting again where it differs costs one more segmentation and removes the
        // possibility of the two disagreeing, rather than relying on them not to.
        let settled = clipped == blockClipped ? word : TextSegmenter.word(
            in: block.text, utf16Offset: offset, clipped: clipped ? [.start, .end] : [])
        guard let settled else { return nil }

        // **And the junction, which neither answer sees.** A sentence running across two
        // observations passes through the boundary between them; if the capture was cut there,
        // words are missing from the *middle* of the sentence — while the sentence touches neither
        // end of the block, so the textual answer is `false`, and an answer scoped to the ends
        // cannot find it.
        //
        // Asking only whether some contributing observation touches *any* edge over-warns: two
        // fragments side by side, the first starting at the capture's left margin, are not cut
        // between each other. `cutsBetween` asks about the sides that face.
        let junction = zip(covering, covering.dropFirst()).contains {
            CaptureEdge.cutsBetween(lines[$0].box, lines[$1].box)
        }

        // **One value, used for both.** `SentenceContext.mayBeCut` is positional — does the
        // sentence reach the block's ends — so it cannot express a cut in the middle, and leaving
        // the two to be computed separately is what let them disagree in the first place. The
        // sentence is rebuilt carrying the answer rather than left to derive its own.
        let cut = settled.sentence.mayBeCut || junction
        guard let sentence = SentenceContext(
            text: settled.sentence.text, mayBeCut: cut, selection: settled.sentence.selection)
        else { return nil }

        return Recognition(
            word: WordAtPoint(word: settled.word, sentence: sentence),
            confidence: block.confidence(over: span, in: lines),
            mayBeCut: cut,
            appName: appName, bundleID: bundleID)
    }

    /// Where the returned sentence sits inside the block, UTF-16.
    ///
    /// **The occurrence that covers the pointer**, found by searching. An earlier version derived
    /// it arithmetically — the pointer's offset minus the word's offset inside the sentence — on
    /// the assumption that the offset handed to the segmenter *is* the word's start. It is not,
    /// and Chinese is where that shows: joining the fragments `学` and `习。` produces `学习。`,
    /// which the tokeniser reads as one word beginning in the *first* fragment. The computed start
    /// then fell inside the word, excluded the fragment the word began in, and reported that
    /// fragment's poor confidence as the good one's.
    ///
    /// Searching is exact here because the pointer disambiguates: a sentence repeated in the block
    /// has several occurrences and only one of them contains the offset. Falls back to the whole
    /// block when none does, which can only over-state how much text the quality signals cover —
    /// the safe direction.
    static func span(
        of sentence: SentenceContext, containing offset: Int, in block: String
    ) -> NSRange {
        let whole = NSRange(location: 0, length: (block as NSString).length)
        let text = block as NSString
        let needle = sentence.text
        guard !needle.isEmpty else { return whole }
        var searched = NSRange(location: 0, length: text.length)
        while searched.length > 0 {
            let found = text.range(of: needle, options: [], range: searched)
            guard found.location != NSNotFound else { break }
            // **Half-open, and the exception that was here picked the wrong sentence.** Accepting
            // `offset == NSMaxRange(found)` let the occurrence *ending* at the pointer win over the
            // one starting there: in `学习。学习。`, pointing at offset 3 — the second sentence's
            // first character — matched the first occurrence (0, 3) and reported its confidence.
            if NSLocationInRange(offset, found) { return found }
            let next = found.location + 1
            guard next < text.length else { break }
            searched = NSRange(location: next, length: text.length - next)
        }
        return whole
    }

    private struct Target {
        let filter: SCContentFilter
        /// In global screen points.
        let region: CGRect
        /// The same region in the filter's own coordinates.
        let sourceRect: CGRect
        let appName: String?
        let bundleID: String?
        /// The window's frame when the capture was set up, in global screen points.
        let frame: CGRect
    }

    /// The capture for `window`, found by its compositor number in ScreenCaptureKit's list.
    ///
    /// The window's *geometry* comes from the cached `SCWindow`, which is up to three seconds old.
    /// Move or resize a window inside that time and the capture crops the place it used to be — a
    /// miss, or worse, the wrong word read confidently — so the cached frame is checked against the
    /// live one the caller listed, and refreshed when they disagree.
    ///
    /// **Against the window as it is now**, not as it was listed when the hover began: the
    /// Accessibility read in between can take most of a second, and a window moved meanwhile would be
    /// cropped where it used to be. Its live bounds are read again here, and a point it no longer
    /// covers reads nothing.
    private func target(at point: CGPoint, window listed: ListedWindow) async throws -> Target {
        guard let live = Self.liveBounds(of: listed.windowID) else { throw RecognitionError.windowNotCapturable }
        guard live.contains(point) else { throw RecognitionError.nothingUnderPointer }
        var found = try await shareableContent().windows.first { $0.windowID == listed.windowID }
        if found.map({ !Self.sameGeometry($0.frame, live) }) ?? true {
            try Task.checkCancellation()
            found = try await shareableContent(refresh: true).windows.first { $0.windowID == listed.windowID }
        }
        guard let window = found, Self.sameGeometry(window.frame, live) else { throw RecognitionError.windowNotCapturable }
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
            bundleID: window.owningApplication?.bundleIdentifier, frame: frame)
    }

    /// The window's bounds as the compositor has them now, or nil where it is no longer on screen.
    private static func liveBounds(of windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let first = info.first,
              // **On screen**, which listing the window by number does not establish: a window moved
              // off screen keeps its bounds and would pass through on the cached path.
              first[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = first[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
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

    /// The maximal runs of non-whitespace in `text` — the unit Vision boxes, and nothing finer.
    ///
    /// Not `TextSegmenter.wordRanges`: that is the tokeniser's answer, which splits `well-known`
    /// and `/Users/alice` into pieces Vision cannot tell apart. The tokeniser still decides what
    /// the reader is handed; it just does so after the pointer has chosen a character.
    static func runs(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            found.append(index..<end)
            index = end
        }
        return found
    }

    private func recognise(_ image: CGImage) throws -> [RecognisedLine] {
        try Self.recognise(image, reading: Self.recogniseWhole)
    }

    /// **The band as the tiles it is read in.** One call where it fits; otherwise overlapping tiles, each read on
    /// its own and put back together by position (`BandTiling`), so the sentence is the band's and the words are read
    /// at the accuracy of a narrow strip. `readTile` is the seam: the wire from here to Vision is asserted without it.
    ///
    /// A reader who has moved on stops being read for between tiles — Vision cannot be interrupted, but the next
    /// tile need not be started. Sequential, because Vision does not run them faster side by side (measured).
    static func recognise(
        _ image: CGImage, reading readTile: (CGImage) throws -> [RecognisedLine]
    ) throws -> [RecognisedLine] {
        let tiles = BandTiling.tiles(
            forWidth: image.width, maximum: Int(maximumTilePixels), overlap: Int(tileOverlapPixels))
        guard tiles.count > 1 else { return try readTile(image) }
        var read: [(tile: BandTile, lines: [RecognisedLine])] = []
        for tile in tiles {
            try Task.checkCancellation()
            guard let part = image.cropping(to: CGRect(x: tile.x, y: 0, width: tile.width, height: image.height))
            else { throw RecognitionError.windowNotCapturable }
            read.append((tile, try readTile(part)))
        }
        return BandTiling.merged(read, bandWidth: image.width)
    }

    /// One Vision call on `image`, as it has always been read.
    private static func recogniseWhole(_ image: CGImage) throws -> [RecognisedLine] {
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
            // **Runs, not tokeniser words, because that is the granularity Vision has.** Asked for
            // a sub-range of a run it returns the run's whole box — measured 2026-09-30, six words
            // of `/Users/alice/github/xiaolai/myprojects/xiaolaidict` all at `x 0.0111 … 0.7667`.
            // Storing those as six words made every comparison a tie and handed the reader the
            // leftmost one; `reading` asks the pointer which token it was instead.
            let runs = Self.runs(in: text).compactMap { range -> RecognisedRun? in
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { return nil }
                return RecognisedRun(
                    text: String(text[range]),
                    utf16Offset: text.utf16.distance(from: text.startIndex, to: range.lowerBound),
                    box: CaptureGeometry.flippedFromVision(box))
            }
            return RecognisedLine(
                text: text, box: CaptureGeometry.flippedFromVision(observation.boundingBox),
                runs: runs, confidence: Double(candidate.confidence))
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
