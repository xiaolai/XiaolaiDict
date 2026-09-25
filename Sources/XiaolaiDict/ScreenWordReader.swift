import AppKit
import ApplicationServices
import DictionaryModel
import XiaolaiDictCore
import Synchronization
import XiaolaiDictUI

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
        case miss(String)
    }

    /// Chromium and Electron build their accessibility tree only when asked; remember whom we
    /// asked, so the write happens once per process rather than per hover.
    private static let awakened = Mutex<Set<pid_t>>([])

    /// A hung app must not stall a hover. Accessibility is synchronous IPC into another process.
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

    /// `access` is a parameter so a test can drive the refusal without this Mac's grant deciding
    /// the answer. **`granted()` and never `ensure()`**: a hover the reader walked away from must
    /// not raise a permission dialog, which is the rule `ScreenRecordingAccess` already keeps for
    /// the other permission.
    static func target(at point: CGPoint, access: AccessibilityAccess = .system) -> TargetOutcome {
        guard access.granted() else { return .none("Accessibility access for XiaolaiDict is off") }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var found: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found)
        guard status == .success, let element = found else {
            return .none("nothing at the pointer (AXError \(status.rawValue))")
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid() else { return .ourOwnWindow }
        let running = NSRunningApplication(processIdentifier: pid)
        return .found(Target(
            element: element, appName: running?.localizedName ?? "pid \(pid)",
            bundleID: running?.bundleIdentifier))
    }

    /// Reads the text, given a target whose owner has already been vetted. `point` is global with a
    /// top-left origin — the CGEvent space, which is also AX's.
    static func read(at point: CGPoint, in target: Target) -> Outcome {
        let element = target.element
        let appName = target.appName
        let bundleID = target.bundleID
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        awaken(pid)

        for (source, read) in [
            (CaptureQuality.Source.accessibilityTextRange, textRange),
            (.accessibilityTextMarkers, textMarkers),
            (.accessibilityBoundsScan, boundsScan),
        ] as [(CaptureQuality.Source, (AXUIElement, CGPoint) -> WordAtPoint?)] {
            if let word = read(element, point) {
                return .hit(Hit(word: word, source: source, appName: appName, bundleID: bundleID))
            }
        }
        let role = copy(element, kAXRoleAttribute) as? String ?? "unknown role"
        return .miss("\(appName) · \(role) exposes no text at this point")
    }

    // MARK: - text range

    private static func textRange(_ element: AXUIElement, at point: CGPoint) -> WordAtPoint? {
        guard let index = range(param(element, kAXRangeForPositionParameterizedAttribute, value(point)))?.location,
              let count = copy(element, kAXNumberOfCharactersAttribute) as? Int,
              index >= 0, index < count
        else { return nil }
        let start = max(0, index - 300)
        let end = min(count, index + 300)
        guard let text = param(
            element, kAXStringForRangeParameterizedAttribute,
            value(CFRange(location: start, length: end - start))) as? String
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
            guard let glyph = rect(param(
                    element, kAXBoundsForRangeParameterizedAttribute,
                    value(CFRange(location: candidate, length: 1)))),
                  let distance = HitTolerance.distance(from: point, to: glyph),
                  let hit = TextSegmenter.word(in: text, utf16Offset: candidate - start, clipped: clipped)
            else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (hit, distance) }
        }
        return best?.hit
    }

    // MARK: - text markers

    private static func textMarkers(_ element: AXUIElement, at point: CGPoint) -> WordAtPoint? {
        let host = webArea(containing: element)
        guard let marker = param(host, "AXTextMarkerForPosition", value(point)) else { return nil }
        // A marker is a caret position, *between* characters: from the right half of a word's last
        // letter it points past the word, at the following space. Weigh both neighbours.
        var best: (word: String, box: CGRect, distance: CGFloat)?
        for attribute in ["AXRightWordTextMarkerRangeForTextMarker", "AXLeftWordTextMarkerRangeForTextMarker"] {
            guard let wordRange = param(host, attribute, marker),
                  let box = rect(param(host, "AXBoundsForTextMarkerRange", wordRange)),
                  let distance = HitTolerance.distance(from: point, to: box),
                  let raw = param(host, "AXStringForTextMarkerRange", wordRange) as? String
            else { continue }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !word.isEmpty else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (word, box, distance) }
        }
        guard let best else { return nil }
        let sentence = param(host, "AXSentenceTextMarkerRangeForTextMarker", marker)
            .flatMap { param(host, "AXStringForTextMarkerRange", $0) as? String } ?? best.word
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
        guard let wholeWord else { return TextSegmenter.word(in: best.word, utf16Offset: 0) }
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

    private static func boundsScan(_ element: AXUIElement, at point: CGPoint) -> WordAtPoint? {
        guard let text = copy(element, kAXValueAttribute) as? String, !text.isEmpty else { return nil }
        let words = TextSegmenter.wordRanges(in: text)
        guard words.count <= maximumScannedWords else { return nil }
        var best: (offset: Int, distance: CGFloat)?
        for word in words {
            let location = text.utf16.distance(from: text.startIndex, to: word.lowerBound)
            let length = text.utf16.distance(from: word.lowerBound, to: word.upperBound)
            guard let box = rect(param(
                    element, kAXBoundsForRangeParameterizedAttribute,
                    value(CFRange(location: location, length: length)))),
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

    /// This reader's own unbounded reads, as `AccessibilityReading`, so the page walk is the one in
    /// `AccessibilitySession.swift` rather than a second copy of it. Nothing here throws: the hover
    /// path classifies no failure — a value it cannot read is a value it does not have — and its
    /// timeout is `messagingTimeout`, a quarter of what a selection read allows, which is why it
    /// cannot simply borrow an `AccessibilitySession`.
    private struct DirectReads: AccessibilityReading {
        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            copy(element, name)
        }

        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            param(element, name, argument)
        }
    }

    /// The page containing `element`, or `element` itself where there is none.
    private static func webArea(containing element: AXUIElement) -> AXUIElement {
        ((try? DirectReads().webArea(containing: element)) ?? nil) ?? element
    }

    private static func awaken(_ pid: pid_t) {
        guard awakened.withLock({ $0.insert(pid).inserted }) else { return }
        // Chromium and Electron switch their tree on; every other app ignores the unknown
        // attribute. Whether Chrome needs this at all is unresolved — it began answering after
        // repeated AX queries — so it is sent once and its failure ignored.
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success ? out : nil
    }

    private static func param(_ element: AXUIElement, _ attribute: String, _ argument: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(
            element, attribute as CFString, argument, &out) == .success ? out : nil
    }

    private static func value(_ point: CGPoint) -> AXValue {
        var point = point
        return AXValueCreate(.cgPoint, &point)!
    }

    private static func value(_ range: CFRange) -> AXValue {
        var range = range
        return AXValueCreate(.cfRange, &range)!
    }

    private static func rect(_ ref: CFTypeRef?) -> CGRect? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(ref as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private static func range(_ ref: CFTypeRef?) -> CFRange? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(ref as! AXValue, .cfRange, &range) ? range : nil
    }
}
