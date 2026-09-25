import AppKit
import ApplicationServices
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI
import Synchronization
import os

/// The app a selection is read from, captured on the main actor before the Accessibility work
/// moves off it.
struct FrontApp: Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?

    /// The frontmost app, with a process ID Accessibility can use.
    @MainActor
    static func frontmost() -> FrontApp? {
        NSWorkspace.shared.frontmostApplication.flatMap(resolve)
    }

    /// A running app by bundle identifier, with a usable process ID.
    @MainActor
    static func running(_ bundleID: String) -> FrontApp? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return (apps.first { $0.processIdentifier > 0 } ?? apps.first).flatMap(resolve)
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

/// What the reader had selected, where, and how far to trust it.
struct Selection: Sendable, Equatable {
    /// The term to look up (`SelectedTerm`): the selection without its wrapping punctuation.
    let text: String
    /// The sentence around it, when the app exposes surrounding text consistent with the selection.
    let sentence: String?
    /// Where `text` sits in `sentence`, UTF-16, when the capture knows.
    let rangeInSentence: NSRange?
    let quality: CaptureQuality
    /// Where it was read: the app always, and the page or the file where the app could say — never
    /// both in one field, which is the defect `where-a-word-was-read.md` §2 is about.
    let place: ReadingPlace

    var appName: String { place.name ?? "" }
    var bundleID: String? { place.bundleID }
}

/// Reads an app's selection through Accessibility. Apps expose text in one of two dialects — the
/// same two the screen-word spike found for hover:
///
/// - **text range**: `AXSelectedText` + `AXSelectedTextRange` — Cocoa text views, most native apps.
/// - **text markers**: `AXSelectedTextMarkerRange` — WebKit (Safari, Mail) and Chromium.
enum SelectionReader {
    enum Outcome: Sendable, Equatable {
        case selected(Selection)
        /// Nothing usable, and why — shown to the reader, never swallowed.
        case nothing(String)
    }

    static let maximumLength = LookupRequest.maximumLength
    /// The whole read, however many requests it takes.
    static let budget: Duration = .seconds(2)
    /// Nodes visited looking for a browser window's page, which sits a few levels under toolbars and
    /// tab groups. A tree this search cannot cross is reported, not treated as "no page".
    static let webAreaSearchLimit = 400
    /// Text read either side of a selection to find its sentence, in UTF-16 units: widened while the
    /// sentence runs into the edge of what was read, up to the last.
    static let contextRadii = [400, 1_600, 6_400]

    /// Synchronous IPC into another app, so it runs detached — never on the caller's actor.
    static func read(from app: FrontApp) async -> Outcome {
        await oneAtATime {
            let application = AXUIElementCreateApplication(app.pid)
            // Chromium and Electron build their tree only when asked; every other app ignores this.
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            return read(application: application, of: app, with: AccessibilitySession(budget: budget))
        } cancelled: {
            .nothing(message(for: .cancelled, app: app.name))
        }
    }

    private static let lastRead = Mutex<Task<Outcome, Never>?>(nil)

    /// Runs `work` detached, after every earlier read has finished. A read replaced by a newer one
    /// is cancelled — a detached task does not inherit that, so it is passed on — but cancellation
    /// takes effect only between Accessibility requests, never inside one. So a superseded read may
    /// still be finishing a request; the next waits for it rather than running beside it, and
    /// however fast the shortcut is pressed, one read at a time reaches into the other app.
    static func oneAtATime(
        _ work: @escaping @Sendable () -> Outcome, cancelled: @escaping @Sendable () -> Outcome
    ) async -> Outcome {
        let task = lastRead.withLock { last -> Task<Outcome, Never> in
            let previous = last
            let next = Task.detached(priority: .userInitiated) { () -> Outcome in
                _ = await previous?.value
                return Task.isCancelled ? cancelled() : work()
            }
            last = next
            return next
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// The whole read, against any Accessibility client — the real one, or a test's.
    static func read(application: AXUIElement, of app: FrontApp, with ax: some AccessibilityReading) -> Outcome {
        do {
            switch try find(in: application, ax) {
            case .found(let capture):
                // Where it came from is worth having, not worth the selection: if reading it fails,
                // the selection stands without it.
                let place = (try? readPlace(host: capture.host, app: app, ax, policy: .shipped)) ?? ReadingPlace(
                    bundleID: app.bundleID, name: app.name)
                return selection(from: capture, app: app, place: place)
            case .nothing:
                return .nothing("Nothing is selected in \(app.name), or it does not expose its selection to Accessibility.")
            case .searchLimitReached:
                return .nothing("""
                    Nothing is selected in \(app.name)'s focused element, and its window is too large to search \
                    for a page within \(webAreaSearchLimit) elements.
                    """)
            }
        } catch {
            return .nothing(message(for: error, app: app.name))
        }
    }

    // MARK: - Finding the selection

    /// A capture, and the element it was read from.
    struct Capture {
        let text: String
        let context: SentenceContext?
        let source: CaptureQuality.Source
        let host: AXUIElement
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
        let byMarkers = try markerCapture(element, ax)
        if let byMarkers, byMarkers.context != nil { return byMarkers }
        return byRange ?? byMarkers
    }

    // MARK: - text range dialect

    private static func rangeCapture(_ element: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> Capture? {
        guard let selected = try ax.string(element, kAXSelectedTextAttribute),
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let context = try sentenceAroundSelectedRange(element, selected: selected, ax)
        return Capture(text: selected, context: context, source: .accessibilityTextRange, host: element)
    }

    /// The sentence from a window of text around the selection — widened while the sentence runs
    /// into the window's edge. Nil unless the window holds the selected text exactly where the
    /// range says: text, range and window are separate reads of state the reader can change.
    private static func sentenceAroundSelectedRange(
        _ element: AXUIElement, selected: String, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> SentenceContext? {
        guard let range = try ax.range(element, kAXSelectedTextRangeAttribute) else { return nil }
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
        let context = try sentenceCovering(selection, selected: text, in: host, ax)
        return Capture(text: text, context: context, source: .accessibilityTextMarkers, host: host)
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
        if let selectionIndex = try ax.integer(host, "AXIndexForTextMarker", start),
           let sentenceIndex = try ax.integer(host, "AXIndexForTextMarker", sentenceStart) {
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

    // MARK: - The result

    static func selection(from capture: Capture, app: FrontApp, place: ReadingPlace) -> Outcome {
        guard let term = SelectedTerm(from: capture.text) else {
            return .nothing("The selection in \(app.name) has no word in it.")
        }
        guard term.text.count <= maximumLength else {
            return .nothing("The selection in \(app.name) is \(term.text.count) characters — too long to look up.")
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
            quality: .accessibility(capture.source, context: quality), place: place))
    }

    static func message(for error: CaptureError, app: String) -> String {
        switch error {
        case .notResponding: "\(app) did not answer Accessibility in time — it may be busy. Try again in a moment."
        case .deadlineExceeded:
            "Reading the selection from \(app) took longer than \(budget.components.seconds) seconds, so it was stopped."
        case .accessibilityDisabled:
            "Accessibility access for XiaolaiDict is off. Allow it in \(PrivacySettings.accessibilityLocation)."
        case .appUnavailable: "\(app) quit, or stopped answering Accessibility requests."
        case .accessibilityRefused: "\(app) refused Accessibility requests — is the screen locked?"
        case .cancelled: "A newer lookup replaced this one."
        }
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
