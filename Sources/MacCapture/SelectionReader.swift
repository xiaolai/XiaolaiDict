import AppKit
import ApplicationServices
import Capture
import CaptureModel
import DictionaryModel
import XiaolaiDictBase
import os

/// The app a selection is read from, captured on the main actor before the Accessibility work
/// moves off it.
public struct FrontApp: Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?

    /// The frontmost app, with a process ID Accessibility can use.
    @MainActor
    public static func frontmost() -> FrontApp? {
        NSWorkspace.shared.frontmostApplication.flatMap { FrontApp($0) }
    }

    /// macOS 27 reports some apps — Safari, launched from a system cryptex — with process ID -1.
    /// The window server knows the real one; it is asked only then.
    @MainActor
    private static func resolve(_ app: NSRunningApplication) -> FrontApp? {
        guard let pid = ProcessResolver.pid(
            reported: app.processIdentifier, bundleID: app.bundleIdentifier, windowOwners: windowOwners())
        else { return nil }
        return FrontApp(pid: pid, name: app.localizedName ?? app.bundleIdentifier ?? "the app", bundleID: app.bundleIdentifier)
    }

    @MainActor
    private static func windowOwners() -> [WindowOwner] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
            .map { WindowOwner(pid: $0, bundleID: NSRunningApplication(processIdentifier: $0)?.bundleIdentifier) }
    }
}

extension FrontApp {
    /// `app`, with a process ID Accessibility can use — **the one public way to make a `FrontApp`**: `frontmost()` reads
    /// the shortcut's app through it, and `--read-selection` an app it found by bundle identifier. That search is the
    /// instrument's own and lives with it, in the app behind its define, since this module left the app (2026-10-08,
    /// P5): a member only an instrument calls would ship in a release here, where no condition may compile it out.
    @MainActor
    public init?(_ app: NSRunningApplication) {
        guard let resolved = Self.resolve(app) else { return nil }
        self = resolved
    }
}

/// What the reader had selected, where, and how far to trust it.
public struct Selection: Sendable, Equatable {
    /// The term to look up (`SelectedTerm`): the selection without its wrapping punctuation.
    public let text: String
    /// The sentence around it, when the app exposes surrounding text consistent with the selection.
    public let sentence: String?
    /// Where `text` sits in `sentence`, UTF-16, when the capture knows.
    public let rangeInSentence: NSRange?
    public let quality: CaptureQuality
    /// Where it was read: the app always, and the page or the file where the app could say — never
    /// both in one field, which is the defect `where-a-word-was-read.md` §2 is about.
    public let place: ReadingPlace

    /// Written out, because a struct's own memberwise initialiser is never public: the app makes a selection of
    /// its own for a word the reader named, a reading reopened and an instrument's panel.
    public init(text: String, sentence: String?, rangeInSentence: NSRange?, quality: CaptureQuality, place: ReadingPlace) {
        self.text = text
        self.sentence = sentence
        self.rangeInSentence = rangeInSentence
        self.quality = quality
        self.place = place
    }

}

/// Reads an app's selection through Accessibility. Apps expose text in one of two dialects — the
/// same two the screen-word spike found for hover:
///
/// - **text range**: `AXSelectedText` + `AXSelectedTextRange` — Cocoa text views, most native apps.
/// - **text markers**: `AXSelectedTextMarkerRange` — WebKit (Safari, Mail) and Chromium.
public enum SelectionReader {
    public enum Outcome: Sendable, Equatable {
        /// What was selected — and **where it is on screen**, y down, where the app could say: what the panel anchors its
        /// card on (the owner's decision of 2026-10-09). Beside the selection, never in it, as a hover's box is: a selection
        /// is recorded and reopened, and a rectangle is true only for the moment it was read.
        case selected(Selection, bounds: ReadBounds?)
        /// Nothing usable, and why — shown to the reader, never swallowed.
        case nothing(Refusal)
    }

    /// Why nothing could be looked up, **typed rather than worded**: each case carries what its sentence names —
    /// the app, a count — and the words are the view layer's (`SelectionReader.Refusal.message`), moved there verbatim
    /// when the reader left the app (2026-10-08, plan-macos-modularisation P5). "Try again", "grant access" and
    /// "nothing is selected" are still different answers; only who says them changed.
    public enum Refusal: Sendable, Equatable {
        /// Nothing is selected in the app, or it does not expose its selection to Accessibility.
        case nothingSelected(app: String)
        /// The focused element had nothing, and the window was too large to search for a page within `limit`
        /// elements — not the same as knowing there is no selection.
        case searchLimitReached(app: String, limit: Int)
        /// The selection is only whitespace and punctuation.
        case noWord(app: String)
        /// The selection is `characters` long, past `maximumLength`.
        case tooLong(app: String, characters: Int)
        /// Reading it failed, and how — each failure needs a different answer for the reader.
        case failed(CaptureError, app: String)
    }

    static let maximumLength = LookupRequest.maximumLength
    /// The whole read, however many requests it takes.
    public static let budget: Duration = .seconds(2)
    /// Nodes visited looking for a browser window's page, which sits a few levels under toolbars and
    /// tab groups. A tree this search cannot cross is reported, not treated as "no page".
    static let webAreaSearchLimit = 400
    /// Text read either side of a selection to find its sentence, in UTF-16 units: widened while the
    /// sentence runs into the edge of what was read, up to the last.
    static let contextRadii = [400, 1_600, 6_400]

    /// Synchronous IPC into another app, so it runs detached — never on the caller's actor.
    ///
    /// **Except when the app is this one, which is read on the main actor instead.** The reader can
    /// press the shortcut while XiaolaiDict is frontmost — Settings, the library and the review window
    /// all activate it — and then `FrontApp.frontmost()` is us. An Accessibility request about *this*
    /// process is not IPC at all: it is serviced in-process on the calling thread, so
    /// `-[NSApplication accessibilityFocusedUIElement]` reaches `NSHostingView` and SwiftUI evaluates a
    /// body wherever the call was made from. Off the main actor its first `@MainActor` call traps —
    /// the second instance of the class the compositor check in `ScreenWordReader.target(at:)` closes,
    /// whose first instance is crash report 2026-09-25. There is no hung app to be stalled by here and
    /// nothing to serialise against, so the two reasons `AccessibilityLane` exists do not apply.
    public static func read(from app: FrontApp) async -> Outcome {
        guard app.pid != getpid() else { return await MainActor.run { readNow(app) } }
        return await AccessibilityLane.system.run(timeout: AccessibilitySession.messagingTimeout) {
            readNow(app)
        } cancelled: {
            .nothing(.failed(.cancelled, app: app.name))
        }
    }

    /// One read of `app`, wherever the caller has decided it may happen.
    private static func readNow(_ app: FrontApp) -> Outcome {
        let application = AXUIElementCreateApplication(app.pid)
        return read(application: application, of: app, with: AccessibilitySession(budget: budget))
    }

    /// The whole read, against any Accessibility client — the real one, or a test's.
    static func read(application: AXUIElement, of app: FrontApp, with ax: some AccessibilityReading) -> Outcome {
        do {
            // Chromium and Electron build their tree only when asked — inside the budget, and an
            // app that does not answer is told as one, not asked everything else.
            try ax.wake(application)
            switch try find(in: application, ax) {
            case .found(let capture):
                // Where it came from is worth having, not worth the selection: if reading it fails,
                // the selection stands without it.
                let place = (try? readPlace(host: capture.host, app: app, ax, policy: .shipped)) ?? ReadingPlace(
                    bundleID: app.bundleID, name: app.name)
                // Where it is on screen, likewise: worth having, not worth the selection — **but a cancellation is the
                // reader moving on, and ends the read** (audit of 2026-10-10: `try?` took one for "no box").
                let located = try SelectedTerm(from: capture.text).flatMap { (term) throws(CaptureError) in
                    try orNone { () throws(CaptureError) in try bounds(of: capture, term: term, ax) }
                }
                return selection(from: capture, app: app, place: place) { _ in located }
            case .nothing:
                return .nothing(.nothingSelected(app: app.name))
            case .searchLimitReached:
                return .nothing(.searchLimitReached(app: app.name, limit: webAreaSearchLimit))
            }
        } catch {
            return .nothing(.failed(error, app: app.name))
        }
    }

    // MARK: - Finding the selection

    /// A capture, and the element it was read from.
    struct Capture {
        let text: String
        let context: SentenceContext?
        let source: CaptureQuality.Source
        let host: AXUIElement
        /// The selection's markers, in the marker dialect — what its box is asked for by.
        var markers: AXTextMarkerRange?
        /// The selected range, in the text-range dialect, **as it was when `text` was read** — read once and kept, so
        /// the sentence is found around it and its box asked for by it, never by a range read again later.
        var range: CFRange?
    }

    private enum Search {
        case found(Capture)
        case nothing
        /// The page search ran out of budget: not the same as knowing there is no selection.
        case searchLimitReached
    }

    /// The focused element first, then — only if that has nothing — the focused window's page.
    /// Safari reports no focused element when it is not frontmost, and focus can sit in its address
    /// bar, yet a selection in the page is still there to read.
    private static func find(in application: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> Search {
        let focused = try ax.element(application, kAXFocusedUIElementAttribute, ofApplication: true)
        if let focused, let found = try capture(from: focused, ax) { return .found(found) }
        var window = try ax.element(application, kAXFocusedWindowAttribute, ofApplication: true)
        if window == nil { window = try ax.element(application, kAXMainWindowAttribute, ofApplication: true) }
        guard let window else { return .nothing }
        switch try breadthFirst(
            from: window, limit: webAreaSearchLimit,
            children: { (node) throws(CaptureError) in try ax.elements(node, kAXChildrenAttribute) },
            matches: { (node) throws(CaptureError) in try ax.string(node, kAXRoleAttribute) == "AXWebArea" })
        {
        case .found(let page) where page != focused: return try capture(from: page, ax).map(Search.found) ?? .nothing
        case .found, .absent: return .nothing
        case .limitReached:
            log.notice("no web area within \(webAreaSearchLimit) elements of the focused window")
            return .searchLimitReached
        }
    }

    /// One element's selection. A dialect's answer is used whole — its text with its own context —
    /// never text from one and sentence from the other: Chrome answers both dialects, and they need
    /// not describe the same selection. Text with context beats text without.
    private static func capture(from element: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> Capture? {
        let byRange = try rangeCapture(element, ax)
        if let byRange, byRange.context != nil { return byRange }
        // **A selection already in hand survives the second dialect failing** — a spent budget
        // throws at its first request, and the range dialect's text went with it.
        let byMarkers: Capture?
        do throws(CaptureError) { byMarkers = try markerCapture(element, ax) } catch {
            guard let byRange, error != .cancelled else { throw error }
            return byRange
        }
        if let byMarkers, byMarkers.context != nil { return byMarkers }
        return byRange ?? byMarkers
    }

    // MARK: - text range dialect

    private static func rangeCapture(_ element: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> Capture? {
        guard let selected = try ax.string(element, kAXSelectedTextAttribute),
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let range = try orNone { () throws(CaptureError) in try ax.range(element, kAXSelectedTextRangeAttribute) }
        let context = try orNone { () throws(CaptureError) -> SentenceContext? in
            guard let range else { return nil }
            return try sentenceAroundSelectedRange(element, selected: selected, range: range, ax)
        }
        return Capture(text: selected, context: context, source: .accessibilityTextRange, host: element, range: range)
    }

    /// The sentence from a window of text around the selection — widened while the sentence runs
    /// into the window's edge. Nil unless the window holds the selected text exactly where the
    /// range says: text, range and window are separate reads of state the reader can change.
    private static func sentenceAroundSelectedRange(
        _ element: AXUIElement, selected: String, range: CFRange, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> SentenceContext? {
        let count = try ax.integer(element, kAXNumberOfCharactersAttribute)
        var best: SentenceContext?
        for radius in contextRadii {
            guard let window = SelectionWindow(selection: range, documentLength: count, radius: radius),
                  let request = AccessibilitySession.rangeValue(window.cfRange),
                  let text = try ax.string(element, kAXStringForRangeParameterizedAttribute, request)
            else { break }
            guard window.holds(selected, in: text) else { return nil }
            best = TextSegmenter.sentence(
                in: text, around: window.selection, clipped: window.clipping(returnedLength: text.utf16.count))
            guard best?.mayBeCut == true else { return best }
        }
        if best != nil { return best }
        // Some views answer only with their whole value: then the window is the whole document.
        guard let whole = try ax.string(element, kAXValueAttribute),
              let window = SelectionWindow(selection: range, documentLength: whole.utf16.count, radius: .max),
              window.holds(selected, in: whole)
        else { return nil }
        return TextSegmenter.sentence(in: whole, around: window.selection)
    }

    // MARK: - text marker dialect

    private static func markerCapture(_ element: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> Capture? {
        let host = try ax.webArea(containing: element) ?? element
        guard let selection = try ax.markerRange(host, "AXSelectedTextMarkerRange"),
              let text = try ax.string(host, "AXStringForTextMarkerRange", selection),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let context = try orNone { () throws(CaptureError) in try sentenceCovering(selection, selected: text, in: host, ax) }
        return Capture(text: text, context: context, source: .accessibilityTextMarkers, host: host, markers: selection)
    }

    /// Something read around a selection already read — its range, its sentence — **or none, if reading it failed**. The
    /// selection is what the reader asked about; a slow app or a spent budget while reading the
    /// context used to throw the selection away with it. Only the reader moving on ends the read.
    private static func orNone<Value>(_ read: () throws(CaptureError) -> Value?) throws(CaptureError) -> Value? {
        do throws(CaptureError) { return try read() } catch {
            if error == .cancelled { throw error }
            return nil
        }
    }

    /// The sentences covering the whole selection: from the one holding its first character to the
    /// one holding its last. The end marker sits after the last character, and at a sentence
    /// boundary it belongs to the next sentence — so the marker before it is asked for. WebKit has
    /// no attribute for a range's own start or end; the public AXTextMarkerRangeCopy… split it.
    private static func sentenceCovering(
        _ selection: AXTextMarkerRange, selected: String, in host: AXUIElement, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> SentenceContext? {
        let start = AXTextMarkerRangeCopyStartMarker(selection)
        let end = AXTextMarkerRangeCopyEndMarker(selection)
        let last = try ax.marker(host, "AXPreviousTextMarkerForTextMarker", end) ?? end
        guard let first = try ax.markerRange(host, "AXSentenceTextMarkerRangeForTextMarker", start),
              let final = try ax.markerRange(host, "AXSentenceTextMarkerRangeForTextMarker", last)
        else { return nil }
        let sentenceStart = AXTextMarkerRangeCopyStartMarker(first)
        let covering = AXTextMarkerRangeCreate(nil, sentenceStart, AXTextMarkerRangeCopyEndMarker(final))
        guard let raw = try ax.string(host, "AXStringForTextMarkerRange", covering) else { return nil }
        // Where the selection starts in the sentence, from the markers' indices when the app gives
        // them; checked against the text either way.
        var offset: Int?
        // Indices from another process: checked, never trusted — `-` on them traps on overflow.
        if let selectionIndex = try ax.integer(host, "AXIndexForTextMarker", start),
           let sentenceIndex = try ax.integer(host, "AXIndexForTextMarker", sentenceStart),
           selectionIndex >= 0, sentenceIndex >= 0 {
            // Both non-negative, so the difference cannot overflow — the check above is the guard.
            offset = selectionIndex - sentenceIndex
        }
        return MarkerSentence.context(raw: raw, selected: selected, reportedOffset: offset)
    }

    // MARK: - Pages and provenance

    /// Where the word was read: a browser's page URL, a document app's file, and the window's
    /// title — three separate coordinates, read from the element the selection came from and its
    /// own window, never the app's focused window, which may be another document.
    ///
    /// The page and the file are never folded into one field. A page URL can itself be a `file://`,
    /// so a local HTML page open in Safari and a file open in an editor are indistinguishable once
    /// they share a column, and nothing downstream can separate them afterwards.
    ///
    /// Apps on the exclusion list contribute their name and nothing more.
    static func readPlace(
        host: AXUIElement, app: FrontApp, _ ax: some AccessibilityReading, policy: PlacePolicy
    ) throws(CaptureError) -> ReadingPlace {
        var page: String?
        if let area = try ax.webArea(containing: host),
           let url = try ax.attribute(area, kAXURLAttribute, ofApplication: false) {
            page = (url as? URL)?.absoluteString ?? (url as? String)
        }
        var document: String?
        var rawTitle: String?
        if let window = try ax.element(host, kAXWindowAttribute) {
            document = try ax.string(window, kAXDocumentAttribute)
            // The window's title, not the web area's: Safari leaves the web area's empty, and
            // Chrome puts 157 characters in it.
            rawTitle = try ax.string(window, kAXTitleAttribute)
        }
        return policy.applied(to: ReadingPlace(
            bundleID: app.bundleID, name: app.name, document: document, page: page,
            title: rawTitle.map { Self.strippingAppName(app.name, from: $0) }, rawTitle: rawTitle))
    }

    /// A window title with its app-name suffix removed — Chrome appends " - Google Chrome". The raw
    /// title is kept beside this, because the stripping is a heuristic and a heuristic's input is
    /// worth keeping. A title that is *only* the app's name strips to nothing, so it is left whole.
    static func strippingAppName(_ app: String, from title: String) -> String {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty else { return title }
        for separator in [" - ", " — ", " – ", " | "] {
            let suffix = separator + app
            guard title.hasSuffix(suffix), title.count > suffix.count else { continue }
            return String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    // MARK: - Where it is

    /// **Where the term is on screen**, y down, or nil where the app cannot say (the owner's decision of 2026-10-09: the
    /// card anchored on the word). The text-range dialect is asked for **the term's own range** — the selection less the
    /// punctuation it was trimmed of — so its box is the word's: exact. WebKit is asked for the term's own markers too
    /// where punctuation was trimmed (`termBox`), and for the selection's where it cannot say where the term is: a box
    /// that holds the term and whatever was trimmed from it, `containing`, never corrected by a guessed punctuation width.
    ///
    /// **The box is the captured text's, or there is none** (audit of 2026-10-10). The range boxed is the one captured with
    /// the text, never one read again, and its text is **read back** first: a range of the same length was taken for the
    /// same text, so *dog* edited in where *cat* was selected was boxed as *cat*. A selection that has moved since — even
    /// onto the same word — locates nothing, and the card keeps the pointer rule. The markers are read back the same way.
    static func bounds(of capture: Capture, term: SelectedTerm, _ ax: some AccessibilityReading) throws(CaptureError) -> ReadBounds? {
        let whole = term.range.location == 0 && term.range.length == (capture.text as NSString).length
        switch capture.source {
        case .accessibilityTextRange:
            guard let captured = capture.range, captured.length == (capture.text as NSString).length,
                  let range = termRange(term.range, within: captured),
                  try text(at: captured, in: capture.host, ax) == capture.text,
                  let now = try ax.range(capture.host, kAXSelectedTextRangeAttribute),
                  now.location == captured.location, now.length == captured.length,
                  let request = AccessibilitySession.rangeValue(range),
                  let box = try ax.rect(capture.host, kAXBoundsForRangeParameterizedAttribute, request)
            else { return nil }
            return ReadBounds.checked(box, quality: .exact)
        case .accessibilityTextMarkers:
            guard let markers = capture.markers,
                  try ax.string(capture.host, "AXStringForTextMarkerRange", markers) == capture.text
            else { return nil }
            if !whole,
               let box = try orNone({ () throws(CaptureError) in try termBox(in: markers, term: term, host: capture.host, ax) }),
               let exact = ReadBounds.checked(box, quality: .exact) {
                return exact
            }
            guard let box = try ax.rect(capture.host, "AXBoundsForTextMarkerRange", markers) else { return nil }
            return ReadBounds.checked(box, quality: whole ? .exact : .containing)
        case .accessibilityBoundsScan, .opticalRecognition:
            return nil
        }
    }

    /// The text at `range` now: asked for that range, or — from a view that answers only with its whole value — cut from
    /// that. Nil where neither answers, or the range is not inside the value.
    private static func text(at range: CFRange, in host: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> String? {
        if let request = AccessibilitySession.rangeValue(range),
           let text = try ax.string(host, kAXStringForRangeParameterizedAttribute, request) {
            return text
        }
        guard let value = try ax.string(host, kAXValueAttribute),
              let inside = Range(NSRange(location: range.location, length: range.length), in: value)
        else { return nil }
        return String(value[inside])
    }

    /// **Where the term is in the document**: `term`, which is where it sits in the selection, moved to where the
    /// selection is. Nil for a selection no text can have — a negative location or length, an end past `Int.max` — and for
    /// a term that is not inside it. **The range comes from another process**, so it is checked before it is summed, and
    /// the sums are checked as they are made: `+` on it trapped at `Int.max`, which ends the app (audit of 2026-10-10).
    static func termRange(_ term: NSRange, within selected: CFRange) -> CFRange? {
        guard selected.location >= 0, selected.length >= 0, term.location >= 0, term.length >= 0,
              !selected.location.addingReportingOverflow(selected.length).overflow,
              term.location <= selected.length, term.length <= selected.length - term.location
        else { return nil }
        // Both sums are bounded by the selection's own end, which did not overflow.
        return CFRange(location: selected.location + term.location, length: term.length)
    }

    /// **The term's own box, inside a selection it was trimmed from** (D3, 2026-10-10). The selection's box centres the
    /// card's tail on the selection, and with more punctuation on one side than the other that middle is off the word by
    /// half the difference — measured on the E2E Mac, `“Q…”` boxed whole put it 8 pt right of *Q*'s middle, on the ellipsis.
    /// WebKit counts a page's text in UTF-16 from its start
    /// (`AXIndexForTextMarker`, the unit `select-web` and the sentence context use too), so the term's markers are the
    /// selection's first index plus where the term sits in it; the range they make is **read back and held to the term**
    /// before its box is believed. Nil where any step goes unanswered or reads back as something else — the selection's
    /// own box then stands, `containing`. A request that fails throws, and the caller keeps the selection's box for any
    /// failure but a cancellation, which ends the read (audit of 2026-10-10: a `catch` here took one for "no box").
    /// Indices come from another process, so the sums are checked, never trusted.
    static func termBox(
        in selection: AXTextMarkerRange, term: SelectedTerm, host: AXUIElement, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> CGRect? {
        let start = AXTextMarkerRangeCopyStartMarker(selection)
        guard let index = try ax.integer(host, "AXIndexForTextMarker", start), index >= 0 else { return nil }
        let (first, overflowed) = index.addingReportingOverflow(term.range.location)
        let (last, overflowedAgain) = first.addingReportingOverflow(term.range.length)
        guard !overflowed, !overflowedAgain,
              let from = try ax.marker(host, "AXTextMarkerForIndex", first as CFNumber),
              let to = try ax.marker(host, "AXTextMarkerForIndex", last as CFNumber),
              let range = try ax.markerRange(host, "AXTextMarkerRangeForUnorderedTextMarkers", [from, to] as CFArray),
              try ax.string(host, "AXStringForTextMarkerRange", range) == term.text
        else { return nil }
        return try ax.rect(host, "AXBoundsForTextMarkerRange", range)
    }

    // MARK: - The result

    static func selection(
        from capture: Capture, app: FrontApp, place: ReadingPlace, locate: (SelectedTerm) -> ReadBounds? = { _ in nil }
    ) -> Outcome {
        guard let term = SelectedTerm(from: capture.text) else { return .nothing(.noWord(app: app.name)) }
        guard term.text.count <= maximumLength else {
            return .nothing(.tooLong(app: app.name, characters: term.text.count))
        }
        let context = capture.context
        let rangeInSentence = context?.selection.map {
            NSRange(location: $0.location + term.range.location, length: term.range.length)
        }
        let quality: CaptureQuality.Context = switch context {
        case nil: .missing
        case let context? where context.mayBeCut: .mayBeCut
        case .some: .complete
        }
        return .selected(Selection(
            text: term.text, sentence: context?.text, rangeInSentence: rangeInSentence,
            quality: .accessibility(capture.source, context: quality), place: place), bounds: locate(term))
    }

    private static let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "selection")
}

/// The marker dialect's sentence, checked against the selection it is meant to contain.
enum MarkerSentence {
    /// Trimmed, with the selection located in it: at `reportedOffset` (UTF-16, in `raw`) if the text
    /// there is the selection, else at its one occurrence. Nil when the sentence does not contain
    /// the selection at all — they were separate reads, and the selection may have moved between.
    static func context(raw: String, selected: String, reportedOffset: Int?) -> SentenceContext? {
        guard let first = raw.firstIndex(where: { !$0.isWhitespace }),
              let last = raw.lastIndex(where: { !$0.isWhitespace })
        else { return nil }
        let text = String(raw[first...last])
        let leading = raw.utf16.distance(from: raw.startIndex, to: first)

        let source = raw as NSString
        let length = (selected as NSString).length
        func holds(_ offset: Int) -> Bool {
            offset >= 0 && offset <= source.length - length
                && source.substring(with: NSRange(location: offset, length: length)) == selected
        }
        var offset = reportedOffset.flatMap { holds($0) ? $0 : nil }
        if offset == nil {
            var occurrences: [Int] = []
            var searched = NSRange(location: 0, length: source.length)
            while occurrences.count < 2 {
                let found = source.range(of: selected, options: .literal, range: searched)
                guard found.location != NSNotFound else { break }
                occurrences.append(found.location)
                searched = NSRange(location: found.location + 1, length: source.length - found.location - 1)
            }
            guard !occurrences.isEmpty else { return nil }
            // A repeated selection is not placed: which occurrence was selected is not guessed.
            if occurrences.count == 1 { offset = occurrences[0] }
        }
        let selection = offset.map { NSRange(location: $0 - leading, length: length) }
            .flatMap { $0.location >= 0 && $0.length <= text.utf16.count - $0.location ? $0 : nil }
        return SentenceContext(text: text, mayBeCut: false, selection: selection)
    }
}
