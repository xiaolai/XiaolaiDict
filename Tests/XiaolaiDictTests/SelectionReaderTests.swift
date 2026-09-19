import ApplicationServices
import Foundation
@testable import XiaolaiDict
import XiaolaiDictCore
import Synchronization
import Testing

/// The reader end to end — which element, which dialect, which context, which provenance — against
/// a scripted Accessibility tree. The real apps' behaviour it scripts is recorded in the platform
/// facts note; `XiaolaiDict --read-selection` checks the real thing.
struct SelectionReaderTests {
    private let app = FrontApp(pid: 1, name: "Reader", bundleID: "com.example.reader")

    private func read(_ tree: FakeAccessibility) -> SelectionReader.Outcome {
        SelectionReader.read(application: tree.application, of: app, with: tree)
    }

    /// Cocoa text views: text, range and window agree, so the exact range reaches the lemmatizer —
    /// the second "meeting" is the verb.
    @Test func theRangeDialectCarriesTheExactRangeAndItsWindowsDocument() throws {
        let tree = FakeAccessibility()
        let document = "Intro line.\nThe meeting ended after we stopped meeting at noon. After."
        let second = (document as NSString).range(of: "meeting", options: .backwards)
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "meeting" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(second.location, second.length))
        tree.set(field, kAXNumberOfCharactersAttribute, document.utf16.count as CFNumber)
        tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(0, document.utf16.count), document as CFString)
        let window = tree.element(2)
        tree.set(field, kAXWindowAttribute, window)
        tree.set(window, kAXDocumentAttribute, "file:///tmp/notes.txt" as CFString)

        guard case .selected(let selection) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.sentence == "The meeting ended after we stopped meeting at noon.")
        #expect(selection.quality == .accessibility(.accessibilityTextRange, context: .complete))
        #expect(selection.place.document == "file:///tmp/notes.txt")
        #expect(selection.place.page == nil, "a file was reported as a page")
        #expect(selection.place.precision == .document)
        #expect(Lemmatizer.lemma(of: selection.text, in: selection.sentence, at: selection.rangeInSentence).text == "meet")
    }

    /// Chrome answers both dialects: text from the range dialect with no usable context, and the
    /// sentence only through markers. The markers' answer is used whole — never the range's text with
    /// the markers' sentence.
    @Test func aDialectWithContextIsUsedWholeNotMixed() throws {
        let tree = FakeAccessibility()
        let text = tree.element(1)
        let page = tree.element(2)
        tree.set(tree.application, kAXFocusedUIElementAttribute, text)
        tree.set(text, kAXSelectedTextAttribute, "word" as CFString)
        tree.set(text, kAXSelectedTextRangeAttribute, rangeValue(5, 0))
        tree.set(text, kAXNumberOfCharactersAttribute, 0 as CFNumber)
        tree.set(text, kAXParentAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "word", sentence: "A word here.")
        tree.set(page, kAXURLAttribute, URL(string: "https://example.com/a")! as CFURL)

        guard case .selected(let selection) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.quality.source == .accessibilityTextMarkers)
        #expect(selection.sentence == "A word here.")
        #expect(selection.rangeInSentence == NSRange(location: 2, length: 4))
        #expect(selection.place.page == "https://example.com/a")
        #expect(selection.place.document == nil, "a page was reported as a file")
        #expect(selection.place.precision == .page)
    }

    /// A sentence that does not contain the selection describes something else — the selection moved
    /// between the reads. No context is better than a wrong one, and the capture says it has none.
    @Test func anIncoherentSentenceIsDroppedAndSaidToBeMissing() throws {
        let tree = FakeAccessibility()
        let page = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "word", sentence: "Something else entirely.")

        guard case .selected(let selection) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.sentence == nil)
        #expect(selection.quality.context == .missing)
    }

    /// Running out of the page-search budget is its own answer, not "nothing is selected".
    @Test func anExhaustedPageSearchSaysSo() {
        let tree = FakeAccessibility()
        let window = tree.element(1)
        tree.set(tree.application, kAXFocusedWindowAttribute, window)
        var parent = window
        for index in 2...(SelectionReader.webAreaSearchLimit + 10) {
            let child = tree.element(Int32(index))
            tree.set(parent, kAXChildrenAttribute, [child] as CFArray)
            parent = child
        }
        guard case .nothing(let reason) = read(tree) else { Issue.record("expected nothing"); return }
        #expect(reason.contains("too large to search"))
    }

    @Test func aLockedScreenIsNotNothingSelected() {
        let tree = FakeAccessibility()
        tree.fail(tree.application, kAXFocusedUIElementAttribute, with: .accessibilityRefused)
        guard case .nothing(let reason) = read(tree) else { Issue.record("expected nothing"); return }
        #expect(reason.contains("locked"))
    }

    /// Provenance is worth having, not worth the selection.
    @Test func aFailedProvenanceReadKeepsTheSelection() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "ephemeral" as CFString)
        tree.fail(field, kAXWindowAttribute, with: .notResponding)
        guard case .selected(let selection) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "ephemeral")
        #expect(selection.place.document == nil)
        #expect(selection.place.precision == .appOnly)
    }

    /// Where it was read comes from the capture's own window — never the app's focused window,
    /// which may hold another document.
    @Test func provenanceNeverComesFromAnotherWindow() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        let otherWindow = tree.element(2)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(tree.application, kAXFocusedWindowAttribute, otherWindow)
        tree.set(otherWindow, kAXDocumentAttribute, "file:///tmp/other.txt" as CFString)
        tree.set(field, kAXSelectedTextAttribute, "ephemeral" as CFString)
        guard case .selected(let selection) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.place.document == nil)
    }

    /// Found by the verifier: a cancelled read stays inside its current Accessibility request, and
    /// rapid presses stacked such reads side by side. Reads now run one at a time, a new one
    /// waiting for a superseded one to finish, and a read cancelled while it waits never starts.
    @Test func readsRunOneAtATime() async {
        let running = Mutex((now: 0, most: 0))
        let started = Mutex(0)
        let slowRead: @Sendable () -> SelectionReader.Outcome = {
            started.withLock { $0 += 1 }
            running.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            Thread.sleep(forTimeInterval: 0.1)  // a request nothing can interrupt
            running.withLock { $0.now -= 1 }
            return .nothing("read")
        }
        let superseded = (0..<3).map { _ in
            Task { await SelectionReader.oneAtATime(slowRead, cancelled: { .nothing("cancelled") }) }
        }
        superseded.forEach { $0.cancel() }
        let last = await SelectionReader.oneAtATime(slowRead, cancelled: { .nothing("cancelled") })
        for task in superseded { _ = await task.value }
        #expect(last == .nothing("read"))
        #expect(running.withLock { $0.most } == 1, "reads ran side by side")
        #expect(started.withLock { $0 } < 4, "every superseded read ran in full")
    }

    private func rangeValue(_ location: Int, _ length: Int) -> AXValue {
        AccessibilitySession.rangeValue(CFRange(location: location, length: length))!
    }
}

/// A scripted Accessibility tree. Elements are application elements for made-up process IDs:
/// distinct, comparable CF objects that no request ever reaches.
private final class FakeAccessibility: AccessibilityReading {
    private struct Key: Hashable {
        let element: AXUIElement
        let name: String
        let argument: String?
    }

    let application = AXUIElementCreateApplication(90_000)
    private var values: [Key: CFTypeRef] = [:]
    private var failures: [Key: CaptureError] = [:]

    func element(_ number: Int32) -> AXUIElement { AXUIElementCreateApplication(90_000 + number) }

    func set(_ element: AXUIElement, _ name: String, argument: CFTypeRef? = nil, _ value: CFTypeRef) {
        values[Key(element: element, name: name, argument: argument.map(Self.describe))] = value
    }

    func fail(_ element: AXUIElement, _ name: String, with error: CaptureError) {
        failures[Key(element: element, name: name, argument: nil)] = error
    }

    /// The marker dialect for one selection inside one sentence, as WebKit answers it.
    func scriptMarkers(on page: AXUIElement, selected: String, sentence: String) {
        let start = marker(1), end = marker(2), last = marker(3), sentenceStart = marker(4), sentenceEnd = marker(5)
        let selection = AXTextMarkerRangeCreate(nil, start, end)
        let sentenceRange = AXTextMarkerRangeCreate(nil, sentenceStart, sentenceEnd)
        set(page, "AXSelectedTextMarkerRange", selection)
        set(page, "AXStringForTextMarkerRange", argument: selection, selected as CFString)
        set(page, "AXPreviousTextMarkerForTextMarker", argument: end, last)
        set(page, "AXSentenceTextMarkerRangeForTextMarker", argument: start, sentenceRange)
        set(page, "AXSentenceTextMarkerRangeForTextMarker", argument: last, sentenceRange)
        set(page, "AXStringForTextMarkerRange", argument: sentenceRange, sentence as CFString)
    }

    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        let key = Key(element: element, name: name, argument: nil)
        if let failure = failures[key] { throw failure }
        return values[key]
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        values[Key(element: element, name: name, argument: Self.describe(argument))]
    }

    private func marker(_ byte: UInt8) -> AXTextMarker { AXTextMarkerCreate(nil, [byte], 1) }

    /// Arguments compared by content: a range by its bounds, a marker by its bytes.
    private static func describe(_ argument: CFTypeRef) -> String {
        let type = CFGetTypeID(argument)
        if type == AXValueGetTypeID() {
            var range = CFRange()
            AXValueGetValue(argument as! AXValue, .cfRange, &range)
            return "range \(range.location) \(range.length)"
        }
        if type == AXTextMarkerGetTypeID() { return "marker \(bytes(argument as! AXTextMarker))" }
        if type == AXTextMarkerRangeGetTypeID() {
            let range = argument as! AXTextMarkerRange
            return "markers \(bytes(AXTextMarkerRangeCopyStartMarker(range))) \(bytes(AXTextMarkerRangeCopyEndMarker(range)))"
        }
        return String(describing: argument)
    }

    private static func bytes(_ marker: AXTextMarker) -> [UInt8] {
        Array(UnsafeBufferPointer(start: AXTextMarkerGetBytePtr(marker), count: AXTextMarkerGetLength(marker)))
    }
}
