import ApplicationServices
import Capture
import CaptureModel
import DictionaryModel
import Foundation
@testable import MacCapture
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

        guard case .selected(let selection, _) = read(tree) else { Issue.record("expected a selection"); return }
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

        guard case .selected(let selection, _) = read(tree) else { Issue.record("expected a selection"); return }
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

        guard case .selected(let selection, _) = read(tree) else { Issue.record("expected a selection"); return }
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
        #expect(reason == .searchLimitReached(app: "Reader", limit: SelectionReader.webAreaSearchLimit))
    }

    @Test func aLockedScreenIsNotNothingSelected() {
        let tree = FakeAccessibility()
        tree.fail(tree.application, kAXFocusedUIElementAttribute, with: .accessibilityRefused)
        guard case .nothing(let reason) = read(tree) else { Issue.record("expected nothing"); return }
        #expect(reason == .failed(.accessibilityRefused, app: "Reader"))
    }

    /// Provenance is worth having, not worth the selection.
    @Test func aFailedProvenanceReadKeepsTheSelection() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "ephemeral" as CFString)
        tree.fail(field, kAXWindowAttribute, with: .notResponding)
        guard case .selected(let selection, _) = read(tree) else { Issue.record("expected a selection"); return }
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
        guard case .selected(let selection, _) = read(tree) else { Issue.record("expected a selection"); return }
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
            return .nothing(.nothingSelected(app: "read"))
        }
        let lane = AccessibilityLane { _ in }
        let superseded = (0..<3).map { _ in
            Task { await lane.run(timeout: 1, slowRead, cancelled: { .nothing(.nothingSelected(app: "cancelled")) }) }
        }
        superseded.forEach { $0.cancel() }
        let last = await lane.run(timeout: 1, slowRead, cancelled: { .nothing(.nothingSelected(app: "cancelled")) })
        for task in superseded { _ = await task.value }
        #expect(last == .nothing(.nothingSelected(app: "read")))
        #expect(running.withLock { $0.most } == 1, "reads ran side by side")
        #expect(started.withLock { $0 } < 4, "every superseded read ran in full")
    }

    /// **A selection is kept when reading its sentence fails** — the reader asked about the
    /// selection, and a spent budget while reading the context used to throw it away with it. Red if
    /// a context failure fails the whole read.
    @Test func aSelectionSurvivesAFailedContextRead() throws {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "ephemeral" as CFString)
        tree.fail(field, kAXSelectedTextRangeAttribute, with: .deadlineExceeded)
        guard case .selected(let selection, _) = read(tree) else {
            Issue.record("a failed context read lost the selection")
            return
        }
        #expect(selection.text == "ephemeral")
        #expect(selection.sentence == nil)
        #expect(selection.quality.context == .missing)
    }

    // MARK: - Where the selection is (the owner's decision of 2026-10-09: the card anchored on the word)

    /// **The text-range dialect is asked for the term's own range** — the selection less the punctuation it was trimmed
    /// of — so the box is the word's, exact.
    @Test func theRangeDialectBoxesTheTermsOwnRange() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "“meeting,”" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(20, 10))
        tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(20, 10), "“meeting,”" as CFString)
        tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(21, 7),
                 rectValue(CGRect(x: 300, y: 90, width: 56, height: 16)))
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "meeting")
        #expect(bounds == ReadBounds(rect: DownRect(x: 300, y: 90, width: 56, height: 16), quality: .exact))
    }

    /// A selected range that no longer spans the text read is a selection that moved between the reads: no box, and the
    /// selection itself is kept.
    @Test func aRangeThatNoLongerSpansTheTextLocatesNothing() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "meeting" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(20, 9))
        tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(20, 7),
                 rectValue(CGRect(x: 300, y: 90, width: 56, height: 16)))
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "meeting")
        #expect(bounds == nil)
    }

    /// **The box is the captured text's, or there is none** (audit of 2026-10-10). A selected range of the same length is
    /// not the same text: *cat* captured, then *dog* at that range when the box is asked — an edit between the two reads —
    /// was boxed as *cat*. The captured range is kept and its text read back before its box is believed.
    @Test func aRangeWhoseTextChangedBetweenTheReadsLocatesNothing() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "cat" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(20, 3))
        tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(20, 3), "dog" as CFString)
        tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(20, 3),
                 rectValue(CGRect(x: 300, y: 90, width: 30, height: 16)))
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "cat")
        #expect(bounds == nil, "dog's box was given for cat")
    }

    /// **A view that answers only with its whole value is read back through that**, so it keeps its box — the same
    /// fallback its sentence is found by.
    @Test func aViewThatAnswersOnlyItsWholeValueIsReadBackThroughIt() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "cat" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(4, 3))
        tree.set(field, kAXValueAttribute, "The cat sat." as CFString)
        tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(4, 3),
                 rectValue(CGRect(x: 140, y: 200, width: 30, height: 20)))
        guard case .selected(_, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(bounds == ReadBounds(rect: DownRect(x: 140, y: 200, width: 30, height: 20), quality: .exact))
        tree.set(field, kAXValueAttribute, "The dog sat." as CFString)
        guard case .selected(_, let edited) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(edited == nil, "a value that no longer holds the selection was believed")
    }

    /// **And a selection that moved between the reads locates nothing**, even onto the same word: the range captured is
    /// the one boxed, never one read again later — which was the box of wherever the reader had gone.
    @Test func aSelectionThatMovedBetweenTheReadsLocatesNothing() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "cat" as CFString)
        tree.answer(field, kAXSelectedTextRangeAttribute, in: [rangeValue(20, 3), rangeValue(40, 3)])
        for location in [20, 40] {
            tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(location, 3), "cat" as CFString)
            tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(location, 3),
                     rectValue(CGRect(x: CGFloat(10 * location), y: 90, width: 30, height: 16)))
        }
        guard case .selected(_, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(bounds == nil, "the box of where the selection went was given for where it was: \(String(describing: bounds))")
    }

    /// **WebKit's markers too**: the box asked for is the captured markers', so its text is read back first — a page that
    /// changed under them locates nothing.
    @Test func markersWhoseTextChangedLocateNothing() {
        let tree = FakeAccessibility()
        let page = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "word", sentence: "A word here.")
        tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 40, height: 18))
        tree.answerSelectionText(on: page, in: ["word", "ward"])
        guard case .selected(_, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(bounds == nil, "the markers' box was believed over text that is no longer the selection's")
    }

    /// **WebKit: the selection's own markers, boxed** — exact where the term is the whole selection, `containing` where
    /// punctuation was trimmed from it, since the box then holds that too.
    @Test func theMarkerDialectBoxesTheSelection() {
        for (selected, quality) in [("word", WordBounds.Quality.exact), ("“word,”", .containing)] {
            let tree = FakeAccessibility()
            let page = tree.element(1)
            tree.set(tree.application, kAXFocusedUIElementAttribute, page)
            tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
            tree.scriptMarkers(on: page, selected: selected, sentence: "A \(selected) here.")
            tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 40, height: 18))
            guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
            #expect(selection.text == "word")
            #expect(bounds == ReadBounds(rect: DownRect(x: 80, y: 140, width: 40, height: 18), quality: quality), "\(selected)")
        }
    }

    /// **The term's own box where punctuation was trimmed from it** (D3, 2026-10-10): WebKit counts the page's text in
    /// UTF-16 from its start, so the term's markers are the selection's first index plus where the term sits in it — and
    /// the box of those is the word's, read back and held to the term before it is believed: exact. A selection whose
    /// whole box would centre the card's tail on punctuation (`“Q…”`, measured on the E2E Mac) is boxed by its word.
    @Test func aTrimmedSelectionIsBoxedByItsTermWhereWebKitCanSayWhereItIs() {
        let tree = FakeAccessibility()
        let page = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "“Q…”", sentence: "Then came “Q…” and more.")
        tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 42, height: 18))
        tree.scriptTermMarkers(on: page, selectionIndex: 10, at: 1, length: 1, text: "Q", CGRect(x: 87, y: 140, width: 12, height: 18))
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "Q")
        #expect(bounds == ReadBounds(rect: DownRect(x: 87, y: 140, width: 12, height: 18), quality: .exact))
    }

    /// **And `containing` where WebKit cannot say** — no index for the selection's start, or markers whose text is not the
    /// term: the selection's own box, as before, never a box guessed at.
    @Test func aTrimmedSelectionKeepsTheSelectionsBoxWhereItsTermCannotBeLocated() {
        for (index, text) in [(nil, "Q"), (10, "Q…")] as [(Int?, String)] {
            let tree = FakeAccessibility()
            let page = tree.element(1)
            tree.set(tree.application, kAXFocusedUIElementAttribute, page)
            tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
            tree.scriptMarkers(on: page, selected: "“Q…”", sentence: "Then came “Q…” and more.")
            tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 42, height: 18))
            if let index {
                tree.scriptTermMarkers(on: page, selectionIndex: index, at: 1, length: 1, text: text,
                                       CGRect(x: 87, y: 140, width: 12, height: 18))
            }
            guard case .selected(_, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
            #expect(bounds == ReadBounds(rect: DownRect(x: 80, y: 140, width: 42, height: 18), quality: .containing),
                    "index \(String(describing: index)), text \(text)")
        }
    }

    /// **A range from another process is checked before any sum of it** (audit of 2026-10-10): a selection at `Int.max`
    /// with punctuation trimmed from its front made `location + offset` trap, ending the app; one at a negative location
    /// asked for a box at a negative range, and believed it. Each locates nothing, and the selection itself stands.
    @Test(arguments: [CFRange(location: .max, length: 5), CFRange(location: .max - 1, length: 5),
                      CFRange(location: -5, length: 5), CFRange(location: -1, length: 5)])
    func aSelectedRangeThatCannotBeTheTextsLocatesNothingAndNeverTraps(range: CFRange) {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "“cat”" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(range.location, range.length))
        // Answered, as a hostile or broken app would, for the range a sum that wrapped or went negative would ask for.
        for location in [range.location &+ 1, range.location] {
            tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(location, range.length), "“cat”" as CFString)
            tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(location, 3),
                     rectValue(CGRect(x: 300, y: 90, width: 30, height: 16)))
        }
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "cat")
        #expect(bounds == nil, "a range at \(range.location) was believed")
    }

    /// **Where the word is is worth having, not worth the selection**: an app that answers no box, or an empty one, still
    /// hands over what was selected — with no box, so the card keeps the pointer rule.
    @Test func noBoxOrAnEmptyOneKeepsTheSelectionAndLocatesNothing() {
        for box in [nil, CGRect.zero] {
            let tree = FakeAccessibility()
            let field = tree.element(1)
            tree.set(tree.application, kAXFocusedUIElementAttribute, field)
            tree.set(field, kAXSelectedTextAttribute, "ephemeral" as CFString)
            tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(0, 9))
            tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(0, 9), "ephemeral" as CFString)
            if let box { tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(0, 9), rectValue(box)) }
            guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
            #expect(selection.text == "ephemeral")
            #expect(bounds == nil)
        }
    }

    private func rangeValue(_ location: Int, _ length: Int) -> AXValue {
        AccessibilitySession.rangeValue(CFRange(location: location, length: length))!
    }

    private func rectValue(_ rect: CGRect) -> AXValue {
        var box = rect
        return AXValueCreate(.cgRect, &box)!
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
    /// Answers that change between reads, as an app's do while the reader works: one per read, the last kept.
    private var sequences: [Key: [CFTypeRef]] = [:]

    func element(_ number: Int32) -> AXUIElement { AXUIElementCreateApplication(90_000 + number) }

    func set(_ element: AXUIElement, _ name: String, argument: CFTypeRef? = nil, _ value: CFTypeRef) {
        values[Key(element: element, name: name, argument: argument.map(Self.describe))] = value
    }

    /// `name` answers each of `answers` in turn, one per read, and then the last one for good.
    func answer(_ element: AXUIElement, _ name: String, argument: CFTypeRef? = nil, in answers: [CFTypeRef]) {
        sequences[Key(element: element, name: name, argument: argument.map(Self.describe))] = answers
    }

    /// The scripted selection's text, read through its markers, answering each of `texts` in turn.
    func answerSelectionText(on page: AXUIElement, in texts: [String]) {
        answer(page, "AXStringForTextMarkerRange", argument: AXTextMarkerRangeCreate(nil, marker(1), marker(2)),
               in: texts.map { $0 as CFString })
    }

    private func next(_ key: Key) -> CFTypeRef? {
        guard var answers = sequences[key], let first = answers.first else { return values[key] }
        if answers.count > 1 { answers.removeFirst(); sequences[key] = answers }
        return first
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

    /// WebKit's index dialect for a term inside the scripted selection: the selection's first index, a marker for each
    /// of the term's two ends, the range they make, the text that range reads back as, and its box.
    func scriptTermMarkers(on page: AXUIElement, selectionIndex: Int, at offset: Int, length: Int, text: String,
                           _ rect: CGRect) {
        set(page, "AXIndexForTextMarker", argument: marker(1), selectionIndex as CFNumber)
        let first = marker(6), last = marker(7)
        set(page, "AXTextMarkerForIndex", argument: (selectionIndex + offset) as CFNumber, first)
        set(page, "AXTextMarkerForIndex", argument: (selectionIndex + offset + length) as CFNumber, last)
        let range = AXTextMarkerRangeCreate(nil, first, last)
        set(page, "AXTextMarkerRangeForUnorderedTextMarkers", argument: [first, last] as CFArray, range)
        set(page, "AXStringForTextMarkerRange", argument: range, text as CFString)
        var box = rect
        set(page, "AXBoundsForTextMarkerRange", argument: range, AXValueCreate(.cgRect, &box)!)
    }

    /// The box WebKit gives the scripted selection's own markers.
    func scriptSelectionBox(on page: AXUIElement, _ rect: CGRect) {
        var box = rect
        set(page, "AXBoundsForTextMarkerRange", argument: AXTextMarkerRangeCreate(nil, marker(1), marker(2)),
            AXValueCreate(.cgRect, &box)!)
    }

    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        let key = Key(element: element, name: name, argument: nil)
        if let failure = failures[key] { throw failure }
        return next(key)
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        next(Key(element: element, name: name, argument: Self.describe(argument)))
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
        if type == CFArrayGetTypeID(), let items = argument as? [CFTypeRef] {
            return "array " + items.map(describe).joined(separator: " ")
        }
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
