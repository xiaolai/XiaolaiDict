import AppKit
import ApplicationServices
import Capture
import CaptureModel
import DictionaryModel
import XiaolaiDictCore
import Synchronization

/// The word under a screen point, read through Accessibility — the fast path, and the one that
/// gets the **whole sentence** because it reads text rather than pixels.
///
/// Apps expose text in one of three dialects, and three is a floor rather than a ceiling: each new
/// app family may add one, and the OCR fallback is what keeps that from being a correctness
/// problem (measured in the screen-word spike).
///
/// | Dialect | Where | Warm cost |
/// |---|---|---|
/// | text range — `AXRangeForPosition` → `AXStringForRange` | Cocoa text views | 8.5 ms |
/// | text markers — `AXTextMarkerForPosition` and friends | WebKit | 3.2 ms |
/// | bounds scan — `AXBoundsForRange` per word | Chromium, Electron | 1.1 ms |
enum ScreenWordReader {
    struct Hit: Sendable {
        let word: WordAtPoint
        let source: CaptureQuality.Source
        let appName: String
        let bundleID: String?
    }

    enum Outcome: Sendable {
        case hit(Hit)
        /// Nothing readable here, and why — the reason is what makes a miss diagnosable rather
        /// than a shrug.
        case miss(String)        /// The reader moved on, and the read stopped between two requests.
        case cancelled
    }

    /// Chromium and Electron build their accessibility tree only when asked; remember whom we
    /// asked, so the write happens once per process rather than per hover.
    /// Keyed by process **and its launch**: a process id is reused, and a new app under an old
    /// app's id would otherwise never be woken.
    private static let awakened = Mutex<Set<String>>([])
    /// The launches asked for their whole tree, by the same key — see `escalate`.
    private static let escalated = Mutex<Set<String>>([])

    /// A hung app must not stall a hover. Accessibility is synchronous IPC into another process.
    /// Per request; the whole read is bounded by `budget`.
    static let messagingTimeout: Float = 0.25

    /// Who owns the pixel under the pointer — **without reading any text**.
    ///
    /// Separate from `read` so exclusion can be enforced *before* anything is read. Checking the
    /// frontmost app instead is not the same question: hovering a visible background terminal
    /// while a browser is active would read the terminal's text and only then reject it.
    /// `@unchecked`: `AXUIElement` is a CF type the SDK does not mark `Sendable`, and it is only
    /// ever *used* on the detached task that reads it — never mutated, and never touched from two
    /// tasks at once. The same treatment `SelectionReader` already gives its elements.
    struct Target: @unchecked Sendable {
        let element: AXUIElement
        let appName: String
        let bundleID: String?

        /// The process Accessibility found the element in — whose window a capture reads.
        var pid: pid_t {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            return pid
        }
    }

    /// A target, or why there is none. Not `Result`: the reason is a message for the log, not an
    /// error anybody throws.
    enum TargetOutcome: @unchecked Sendable {
        case found(Target)
        /// No element here, and why. The recogniser may still be worth trying.
        case none(String)
        /// The pointer is over XiaolaiDict's own window. **Nothing else must be tried**: falling through
        /// to the recogniser would capture the window *underneath* XiaolaiDict's panel, so resting the
        /// pointer on the panel would read whatever it happens to be covering.
        case ourOwnWindow
    }

    /// `access` and `windows` are parameters so a test can drive both refusals without this Mac's
    /// grant or this Mac's screen deciding the answer. **`granted()` and never `ensure()`**: a hover
    /// the reader walked away from must not raise a permission dialog. Hover asks neither permission
    /// of the system — `ScreenRecordingAccess` has no request to make either.
    static func target(
        at point: CGPoint, access: AccessibilityAccess = .system,
        windows: () -> [ListedWindow] = ScreenWordReader.listedWindows
    ) -> TargetOutcome {
        guard access.granted() else { return .none("Accessibility access for XiaolaiDict is off") }
        // **Whose window this is, asked of the compositor before Accessibility is asked anything.**
        //
        // The `pid` check below cannot do this job, and no check on a returned element ever could:
        // where the window under the pointer is one of XiaolaiDict's own, the crash is *inside*
        // `AXUIElementCopyElementAtPosition`. Accessibility services a request about this process
        // in-process, on the **calling thread** — here a cooperative-pool thread, because the read is
        // detached so a hung app cannot stall a hover — so `-[NSApplication accessibilityHitTest:]`
        // runs, `NSHostingView` answers it, and the panel's SwiftUI body is evaluated off the main
        // actor. Its first `@MainActor` call then traps. Measured: crash report 2026-09-25,
        // `EXC_BREAKPOINT` in `dispatch_assert_queue` under `LookupPanelContent.content`, nine minutes
        // into an ordinary session — the panel opens beside the pointer, so reaching for it with the
        // modifier still held is the shortest route there.
        //
        // **After the grant, never before it.** The cheap refusal stays cheapest: a reader who is
        // simply reading pays one set comparison, not a window list — ADR-0015.
        if PointerWindow.ours(at: point, in: windows(), ours: getpid()) { return .ourOwnWindow }
        // The messaging timeout is the lane's to set — see `AccessibilityLane`.
        let system = AXUIElementCreateSystemWide()

        var found: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found)
        guard status == .success, let element = found else {
            return .none("nothing at the pointer (AXError \(status.rawValue))")
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        // Kept as the second line. The compositor's list is a moment old, so a window that arrived or
        // moved since is answered here instead — by then the hit test has happened, which is why this
        // cannot be the only line.
        guard pid != getpid() else { return .ourOwnWindow }
        let running = NSRunningApplication(processIdentifier: pid)
        return .found(Target(
            element: element, appName: running?.localizedName ?? "pid \(pid)",
            bundleID: running?.bundleIdentifier))
    }

    /// The whole hover read, however many requests it takes. **Where the recogniser is measured to
    /// be as fast** — 250–570 ms warm — so past it, reading the pixels is the cheaper answer. A read
    /// overruns this by at most the one request in flight, a quarter of a second.
    static let budget: Duration = .milliseconds(500)

    /// Reads the text, given a target whose owner has already been vetted. `point` is global with a
    /// top-left origin — the CGEvent space, which is also AX's.
    static func read(at point: CGPoint, in target: Target, budget: Duration) -> Outcome {
        read(at: point, in: target, with: AccessibilitySession(budget: budget))
    }

    /// The three dialects in order, against any Accessibility client — the real one or a test's.
    ///
    /// **A failure ends the read.** `.notResponding` means the app did not answer one request in a
    /// quarter second, and asking it the next hundred questions only multiplies that; the budget
    /// running out, or the reader moving on, ends it the same way. Only an *absent* value moves on
    /// to the next dialect.
    static func read(at point: CGPoint, in target: Target, with ax: some AccessibilityReading) -> Outcome {
        let element = target.element
        func hit(_ word: WordAtPoint, _ source: CaptureQuality.Source) -> Outcome {
            .hit(Hit(word: word, source: source, appName: target.appName, bundleID: target.bundleID))
        }
        do throws(CaptureError) {
            try awaken(target, ax)
            if let word = try textRange(element, at: point, ax) { return hit(word, .accessibilityTextRange) }
            if let word = try textMarkers(element, at: point, ax) { return hit(word, .accessibilityTextMarkers) }
            if let word = try boundsScan(element, at: point, ax) { return hit(word, .accessibilityBoundsScan) }
            // **Nothing answered: ask the app, once, to build its tree for an assistive client.** Chrome
            // exposes no page until it is told one is reading it, so without this every Chrome hover
            // went to the pixels. This hover still does — the tree arrives about two seconds later —
            // and the next one reads text. Asked only here, so an app that answers is never told.
            try escalate(target, ax)
            let role = try ax.string(element, kAXRoleAttribute) ?? "unknown role"
            return .miss("\(target.appName) · \(role) exposes no text at this point")
        } catch {
            if error == .cancelled { return .cancelled }
            return .miss("\(target.appName) · \(String(describing: error))")
        }
    }

    /// The site `target` shows: the host of its web area's address, from the same walk to the page
    /// the marker dialect makes. No web area is not web content; a web area whose address cannot
    /// be read, or a read that failed, is `unreadable` — never guessed to be harmless.
    static func host(of target: Target, with ax: some AccessibilityReading) -> HostReading {
        do throws(CaptureError) {
            // **Woken first.** An unwoken Chromium tree has no web area yet, and "no page" read from
            // it would let an excluded site through as `.notWebContent`.
            try awaken(target, ax)
            let area: AXUIElement
            switch try ax.walkToPage(from: target.element) {
            case .page(let found): area = found
            case .application: return .notWebContent
            // **A walk that stopped short is not "no page"**: a parent that could not be read reads as
            // absent, and taken for the top it let an excluded site through as `.notWebContent`.
            case .stoppedShort: return .unreadable
            }
            let raw = try ax.attribute(area, kAXURLAttribute, ofApplication: false)
            guard let url = (raw as? URL) ?? (raw as? String).flatMap({ URL(string: $0) }) else { return .unreadable }
            // In its IDNA form, the form an excluded host is stored in: `host()` percent-encodes
            // a Unicode name, and `bücher.de` would never match its own exclusion.
            if let host = url.host(percentEncoded: false), !host.isEmpty { return .known(host) }
            // A local file or a blank page is a page with no site, which no site exclusion is about.
            return url.isFileURL || url.scheme == "about" ? .notWebContent : .unreadable
        } catch {
            return .unreadable
        }
    }

    // MARK: - text range

    private static func textRange(
        _ element: AXUIElement, at point: CGPoint, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> WordAtPoint? {
        guard let index = try ax.range(element, kAXRangeForPositionParameterizedAttribute, value(point))?.location,
              let count = try ax.integer(element, kAXNumberOfCharactersAttribute),
              index >= 0, index < count
        else { return nil }
        let start = max(0, index - 300)
        let end = min(count, index + 300)
        guard let text = try ax.string(
            element, kAXStringForRangeParameterizedAttribute, value(CFRange(location: start, length: end - start)))
        else { return nil }
        // The window is ±300 characters, so a longer sentence is cut by *this* rather than by the
        // app — and a cut sentence must say so. Without these flags a truncated sentence was
        // reported `.complete`, which is the one thing the capture-quality invariant forbids.
        var clipped = TextSegmenter.Clipping()
        if start > 0 { clipped.insert(.start) }
        if end < count { clipped.insert(.end) }
        // `AXRangeForPosition` answers with the *nearest* character even from a margin or a blank
        // line, and just past a word that character is the following space — so without a glyph
        // check, blank space looks up the closest word (finding 9). Weigh it and its neighbours by
        // their glyph boxes, under the tolerance every path shares.
        var best: (hit: WordAtPoint, distance: CGFloat)?
        for candidate in [index, index - 1, index + 1] where candidate >= start && candidate < end {
            guard let glyph = try ax.rect(
                    element, kAXBoundsForRangeParameterizedAttribute, value(CFRange(location: candidate, length: 1))),
                  let distance = HitTolerance.distance(from: point, to: glyph),
                  let hit = TextSegmenter.word(in: text, utf16Offset: candidate - start, clipped: clipped)
            else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (hit, distance) }
        }
        return best?.hit
    }

    // MARK: - text markers

    /// The marker dialect: the word the pointer is over, then its sentence — `markedWord` picks the
    /// word, `context` places it in its sentence (audit round 3, #36).
    private static func textMarkers(
        _ element: AXUIElement, at point: CGPoint, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> WordAtPoint? {
        let host = try ax.webArea(containing: element) ?? element
        guard let marker = try ax.parameterized(host, "AXTextMarkerForPosition", value(point)),
              let best = try markedWord(at: point, marker: marker, in: host, ax)
        else { return nil }
        return try context(of: best, at: point, marker: marker, in: host, ax)
    }

    /// A word under the pointer, as the markers give it: its text, its box, and how far the pointer is
    /// from that box.
    private typealias MarkedWord = (word: String, box: CGRect, distance: CGFloat)

    /// The nearer of the words either side of `marker`, or nil where neither is within the tolerance.
    private static func markedWord(
        at point: CGPoint, marker: CFTypeRef, in host: AXUIElement, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> MarkedWord? {
        // A marker is a caret position, *between* characters: from the right half of a word's last
        // letter it points past the word, at the following space. Weigh both neighbours.
        var best: MarkedWord?
        for attribute in ["AXRightWordTextMarkerRangeForTextMarker", "AXLeftWordTextMarkerRangeForTextMarker"] {
            guard let wordRange = try ax.parameterized(host, attribute, marker),
                  let box = try ax.rect(host, "AXBoundsForTextMarkerRange", wordRange),
                  let distance = HitTolerance.distance(from: point, to: box),
                  let raw = try ax.string(host, "AXStringForTextMarkerRange", wordRange)
            else { continue }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !word.isEmpty else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (word, box, distance) }
        }
        return best
    }

    /// `best` in its sentence, segmented at the pointer — or the word alone, marked cut at both ends,
    /// where the sentence cannot be read or the word cannot be placed in it.
    private static func context(
        of best: MarkedWord, at point: CGPoint, marker: CFTypeRef, in host: AXUIElement, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> WordAtPoint? {
        // **No sentence is the word alone, and says so** — read as a sentence, the word would be
        // a complete context of one word, which it is not.
        guard let range = try ax.parameterized(host, "AXSentenceTextMarkerRangeForTextMarker", marker),
              let sentence = try ax.string(host, "AXStringForTextMarkerRange", range)
        else { return TextSegmenter.word(in: best.word, utf16Offset: 0, clipped: [.start, .end]) }
        // Whole words only. A plain substring search takes the first *occurrence*, so hovering
        // "he" in "there he stood" found it inside "there" and re-segmented to "there".
        //
        // A substring match is accepted only for CJK, which is the one case where the app's word
        // breaks and the tokeniser's are *expected* to disagree — WebKit calls 看书 one word and
        // the tokeniser splits it, so no whole-word match exists and the substring position is
        // still the right one. For anything else, no whole word means no reliable position, and
        // the word alone is returned rather than a confident reading of the wrong word.
        var wholeWord = Self.wholeWordRange(of: best.word, in: sentence)
        if wholeWord == nil, LineJoiner.isCJKText(best.word) {
            let found = (sentence as NSString).range(of: best.word, options: [.literal])
            if found.location != NSNotFound { wholeWord = found }
        }
        // **The word alone is not a sentence**, and must not be reported as a complete one: it is
        // marked cut at both ends, so the card does not present it as context.
        guard let wholeWord else { return TextSegmenter.word(in: best.word, utf16Offset: 0, clipped: [.start, .end]) }
        // WebKit's word breaks and NLTokenizer's differ — WebKit calls 看书 one word — so
        // re-segment at the pointer's position *within* WebKit's word, not at its first character.
        let within = CaptureGeometry.characterIndex(
            at: point.x, across: best.box.minX...best.box.maxX, count: best.word.utf16.count)
        return TextSegmenter.word(in: sentence, utf16Offset: wholeWord.location + within)
    }

    /// Where `word` appears in `sentence` as a whole word, by the same tokeniser the rest of XiaolaiDict
    /// segments with — so "he" does not match inside "there". Nil when it appears nowhere as one,
    /// and the caller falls back to a plain search.
    ///
    /// Still the *first* whole-word occurrence: a word twice in one sentence is a known limit the
    /// markers give no way to resolve, and it is a wrong offset rather than a wrong word.
    static func wholeWordRange(of word: String, in sentence: String) -> NSRange? {
        for range in TextSegmenter.wordRanges(in: sentence) where String(sentence[range]) == word {
            return NSRange(
                location: sentence.utf16.distance(from: sentence.startIndex, to: range.lowerBound),
                length: sentence.utf16.distance(from: range.lowerBound, to: range.upperBound))
        }
        return nil
    }

    // MARK: - bounds scan

    /// One AX call per word, hence the cap: past it, OCR is the cheaper answer.
    static let maximumScannedWords = 120

    private static func boundsScan(
        _ element: AXUIElement, at point: CGPoint, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> WordAtPoint? {
        guard let text = try ax.string(element, kAXValueAttribute), !text.isEmpty else { return nil }
        let words = TextSegmenter.wordRanges(in: text)
        guard words.count <= maximumScannedWords else { return nil }
        var best: (offset: Int, distance: CGFloat)?
        for word in words {
            let location = text.utf16.distance(from: text.startIndex, to: word.lowerBound)
            let length = text.utf16.distance(from: word.lowerBound, to: word.upperBound)
            guard let box = try ax.rect(
                    element, kAXBoundsForRangeParameterizedAttribute, value(CFRange(location: location, length: length))),
                  !box.isEmpty,
                  let distance = HitTolerance.distance(from: point, to: box)
            else { continue }
            // Follow the pointer inside the word, so CJK re-segmentation lands on the right character.
            let within = CaptureGeometry.characterIndex(
                at: point.x, across: box.minX...box.maxX, count: length)
            if best.map({ distance < $0.distance }) ?? true { best = (location + within, distance) }
        }
        return best.flatMap { TextSegmenter.word(in: text, utf16Offset: $0.offset) }
    }

    // MARK: - Plumbing

    /// The compositor's on-screen windows, front to back — **every level**, which is what lets a hover
    /// see XiaolaiDict's own panel at `.floating`. Costs no permission: an owner and a frame are public,
    /// and only a window's *title* needs Screen Recording.
    ///
    /// **0.38–0.41 ms for 17 windows**, measured 2026-09-30 on this Mac over five passes — against the
    /// 1–9 ms Accessibility round trip it precedes, and only on hovers the gate has already admitted.
    /// Not `SCShareableContent`, which is the same question at 60–85 ms and needs a grant.
    static func listedWindows() -> [ListedWindow] {
        PointerWindow.listed(
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? [])
    }

    /// Chromium and Electron switch their tree on; every other app ignores the unknown attribute.
    /// Sent once per process **that answered it** — remembered only after it went through, so a
    /// transient failure is tried again on the next hover rather than never.
    private static func awaken(_ target: Target, _ ax: some AccessibilityReading) throws(CaptureError) {
        let pid = target.pid
        let launched = NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970 ?? 0
        let key = "\(pid)@\(launched)"
        guard !awakened.withLock({ $0.contains(key) }) else { return }
        try ax.wake(AXUIElementCreateApplication(pid))
        awakened.withLock { _ = $0.insert(key) }
    }

    /// `AXEnhancedUserInterface`, at most once per launch of an app. **It makes the app build its whole
    /// tree** — work, memory, and in some apps slower window moves for a window manager — which is why
    /// it waits for an app that answered nothing, rather than going out with `awaken`.
    private static func escalate(_ target: Target, _ ax: some AccessibilityReading) throws(CaptureError) {
        let pid = target.pid
        let launched = NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970 ?? 0
        let key = "\(pid)@\(launched)"
        guard !escalated.withLock({ $0.contains(key) }) else { return }
        try ax.enhance(AXUIElementCreateApplication(pid))
        escalated.withLock { _ = $0.insert(key) }
    }

    private static func value(_ point: CGPoint) -> AXValue {
        var point = point
        // Nil only when the type and the pointer disagree, and they are written together here.
        // swiftlint:disable:next force_unwrapping
        return AXValueCreate(.cgPoint, &point)!
    }

    private static func value(_ range: CFRange) -> AXValue {
        var range = range
        // Nil only when the type and the pointer disagree, and they are written together here.
        // swiftlint:disable:next force_unwrapping
        return AXValueCreate(.cfRange, &range)!
    }
}
