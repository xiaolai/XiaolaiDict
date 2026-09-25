import ApplicationServices
import DictionaryModel
import Foundation
@testable import XiaolaiDict
@testable import XiaolaiDictUI
import XiaolaiDictCore
import Testing

/// The decisions the selection reader makes once Accessibility has answered: what the term is,
/// which text to read around it, whether the answers agree, and how far to trust the result.
struct SelectedTermTests {
    @Test(arguments: [
        ("“ephemeral,”", "ephemeral"), ("  spaced \n", "spaced"), ("(word)", "word"), ("[note]", "note"),
        ("etc.", "etc"), ("word...", "word"), ("word…", "word"), ("Really?!", "Really"), ("'quoted'", "quoted"),
        ("—dash—", "dash"), ("“学习”。", "学习"), ("¿qué?", "qué"),
        // Found by the verifier: a term with a stop inside kept the one that ended the sentence.
        (".NET.", ".NET"), ("example.com.", "example.com"),
    ])
    func wrappingAndEndingPunctuationComesOff(selection: String, term: String) {
        #expect(SelectedTerm(from: selection)?.text == term)
    }

    /// Found by audit: trimming every punctuation mark turned C# into C and .NET into NET.
    @Test(arguments: ["C#", ".NET", "U.S.", "e.g.", "Ph.D.", "a.m.", "don't", "word(s)", "-ish", "'tis", "rock-'n'-roll", "C++", "(a) or (b)"])
    func punctuationThatBelongsToTheTermStays(term: String) {
        #expect(SelectedTerm(from: term)?.text == term)
    }

    @Test(arguments: ["", "   ", "...", "“”", "()", "!?"])
    func aSelectionOfOnlyPunctuationHasNoTerm(selection: String) {
        #expect(SelectedTerm(from: selection) == nil)
    }

    /// The term's place in the selection, so its place in the sentence can be worked out.
    @Test func theTermKnowsWhereItSatInTheSelection() throws {
        let term = try #require(SelectedTerm(from: " “ephemeral,” "))
        #expect(term.range == NSRange(location: 2, length: 9))
    }
}

struct SelectionWindowTests {
    @Test func aWindowAroundASelection() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: 1_000, length: 5), documentLength: 5_000, radius: 400))
        #expect(window.location == 600)
        #expect(window.length == 805)
        #expect(window.selection == NSRange(location: 400, length: 5))
    }

    @Test func aWindowStopsAtTheDocumentsEdges() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: 10, length: 5), documentLength: 100, radius: 400))
        #expect(window.location == 0)
        #expect(window.length == 100)
        #expect(window.clipping(returnedLength: 100) == [])
    }

    /// Ranges come from another process. Negative, overflowing or past-the-end ones are refused,
    /// never used in arithmetic that traps.
    @Test(arguments: [
        CFRange(location: -1, length: 5), CFRange(location: 5, length: -1), CFRange(location: .max, length: 1),
        CFRange(location: 1, length: .max), CFRange(location: 90, length: 20),
    ])
    func anImpossibleRangeIsRefused(range: CFRange) {
        #expect(SelectionWindow(selection: range, documentLength: 100, radius: 400) == nil)
    }

    /// Without a reported length, a short answer cannot be told from a truncated one, so the end is
    /// never taken for the document's.
    @Test func anUnknownDocumentLengthStillMakesAWindow() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: 1_000, length: 5), documentLength: nil, radius: 400))
        #expect(window.length == 805)
        #expect(window.clipping(returnedLength: 500) == [.start, .end])
        #expect(window.clipping(returnedLength: 805) == [.start, .end])
    }

    /// Found by the verifier: an app answering with less than was asked for, when the document is
    /// known to go on, had its fragment taken for the document's end — and a cut sentence for a
    /// complete one.
    @Test func aShortAnswerFromALongerDocumentIsCut() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: 1_000, length: 5), documentLength: 5_000, radius: 400))
        #expect(window.clipping(returnedLength: 300) == [.start, .end])
        #expect(window.clipping(returnedLength: 805) == [.start, .end])
        let atEnd = try #require(SelectionWindow(selection: CFRange(location: 4_900, length: 5), documentLength: 5_000, radius: 400))
        #expect(atEnd.clipping(returnedLength: atEnd.length) == [.start])
    }

    /// The text read for the window must hold the selection where the range says, or the text, the
    /// range and the window describe different selections.
    @Test func theWindowMustHoldTheSelectedText() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: 4, length: 5), documentLength: 20, radius: 400))
        #expect(window.holds("quick", in: "The quick brown fox."))
        #expect(!window.holds("brown", in: "The quick brown fox."))
        #expect(!window.holds("quick", in: "The"))
    }
}

struct BreadthFirstTests {
    private let graph: [Int: [Int]] = [0: [1, 2], 1: [3, 0], 2: [3], 3: [4], 4: []]

    @Test func findsAMatch() {
        guard case .found(3) = breadthFirst(from: 0, limit: 10, children: { graph[$0] ?? [] }, matches: { $0 == 3 }) else {
            Issue.record("expected to find 3")
            return
        }
    }

    /// Cycles and shared children are visited once, so they cannot use up the limit.
    @Test func eachNodeIsVisitedOnce() {
        var visits: [Int] = []
        _ = breadthFirst(from: 0, limit: 10, children: { graph[$0] ?? [] }, matches: { visits.append($0); return false })
        #expect(visits == [0, 1, 2, 3, 4])
    }

    /// Running out of budget is not the same as finding nothing.
    @Test func runningOutOfBudgetIsReportedAsSuch() {
        guard case .limitReached = breadthFirst(from: 0, limit: 2, children: { graph[$0] ?? [] }, matches: { $0 == 4 }) else {
            Issue.record("expected the limit to be reported")
            return
        }
        guard case .absent = breadthFirst(from: 0, limit: 10, children: { graph[$0] ?? [] }, matches: { $0 == 9 }) else {
            Issue.record("expected absence")
            return
        }
    }
}

struct MarkerSentenceTests {
    @Test func theSelectionIsLocatedAtTheReportedOffset() throws {
        // "meeting" starts 16 units into the raw text; 14 into the trimmed sentence.
        let context = try #require(MarkerSentence.context(raw: "  We met at the meeting.  ", selected: "meeting", reportedOffset: 16))
        #expect(context.text == "We met at the meeting.")
        #expect(context.selection == NSRange(location: 14, length: 7))
        #expect(!context.mayBeCut)
    }

    /// Without a usable offset, a word that occurs once is placed; a repeated one is not guessed.
    @Test func withoutAnOffsetOnlyAUniqueOccurrenceIsPlaced() throws {
        let unique = try #require(MarkerSentence.context(raw: "A quick fox.", selected: "quick", reportedOffset: nil))
        #expect(unique.selection == NSRange(location: 2, length: 5))
        let repeated = try #require(MarkerSentence.context(raw: "The meeting ended after meeting.", selected: "meeting", reportedOffset: 99))
        #expect(repeated.selection == nil)
    }

    /// A sentence that does not contain the selection describes something else: the selection
    /// changed between the two reads.
    @Test func aSentenceWithoutTheSelectionIsDiscarded() {
        #expect(MarkerSentence.context(raw: "Another sentence entirely.", selected: "ephemeral", reportedOffset: 0) == nil)
    }
}

struct CaptureTests {
    private let app = FrontApp(pid: getpid(), name: "TextEdit", bundleID: "com.apple.TextEdit")
    private let host = AXUIElementCreateApplication(getpid())

    private func capture(_ text: String, context: SentenceContext?) -> SelectionReader.Capture {
        SelectionReader.Capture(text: text, context: context, source: .accessibilityTextRange, host: host)
    }

    @Test func aCompleteSentenceIsReportedAsComplete() throws {
        let context = SentenceContext(text: "An ephemeral beauty.", mayBeCut: false, selection: NSRange(location: 3, length: 9))
        guard case .selected(let selection) = SelectionReader.selection(from: capture("ephemeral", context: context), app: app, place: ReadingPlace()) else {
            Issue.record("expected a selection")
            return
        }
        #expect(selection.quality == .accessibility(.accessibilityTextRange, context: .complete))
        #expect(selection.rangeInSentence == NSRange(location: 3, length: 9))
    }

    /// Every capture says what its context amounts to: cut by the window, or missing altogether.
    @Test func aDegradedContextSaysSo() throws {
        let cut = SentenceContext(text: "rest of a long sentence", mayBeCut: true)
        guard case .selected(let clipped) = SelectionReader.selection(from: capture("long", context: cut), app: app, place: ReadingPlace()),
              case .selected(let bare) = SelectionReader.selection(from: capture("word", context: nil), app: app, place: ReadingPlace())
        else {
            Issue.record("expected selections")
            return
        }
        #expect(clipped.quality.context == .mayBeCut)
        #expect(bare.quality.context == .missing)
        #expect(bare.sentence == nil)
    }

    /// The term's range in the sentence accounts for punctuation trimmed off the selection.
    @Test func theRangeFollowsTheTrimmedTerm() throws {
        let context = SentenceContext(text: "He said “ephemeral,” twice.", mayBeCut: false, selection: NSRange(location: 8, length: 12))
        guard case .selected(let selection) = SelectionReader.selection(from: capture("“ephemeral,”", context: context), app: app, place: ReadingPlace()) else {
            Issue.record("expected a selection")
            return
        }
        #expect(selection.text == "ephemeral")
        let sentence = try #require(selection.sentence)
        #expect((sentence as NSString).substring(with: try #require(selection.rangeInSentence)) == "ephemeral")
    }

    @Test func aPassageIsRefused() {
        let passage = String(repeating: "word ", count: 20)
        guard case .nothing(let reason) = SelectionReader.selection(from: capture(passage, context: nil), app: app, place: ReadingPlace()) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("too long"))
    }

    /// Found by audit: every Accessibility error became "nothing selected". The ones that need a
    /// different answer for the reader are kept apart.
    @Test(arguments: [
        (AXError.success, AccessibilitySession.Answer.value),
        (.noValue, .absent), (.attributeUnsupported, .absent), (.failure, .absent),
        (.cannotComplete, .failed(.notResponding)), (.apiDisabled, .failed(.accessibilityDisabled)),
        (.invalidUIElement, .absent),
    ])
    func accessibilityStatusesAreClassified(status: AXError, answer: AccessibilitySession.Answer) {
        #expect(AccessibilitySession.answer(for: status) == answer)
    }

    @Test func anInvalidApplicationElementMeansTheAppIsGone() {
        #expect(AccessibilitySession.answer(for: .invalidUIElement, ofApplication: true) == .failed(.appUnavailable))
    }

    /// A locked screen answers kAXErrorFailure (-25200) for the app itself (screen-word spike,
    /// finding 11) — "is the screen locked?", not "nothing selected". Deeper in the tree the same
    /// status only means that element had nothing.
    @Test func aRefusalByTheAppItselfIsReported() {
        #expect(AccessibilitySession.answer(for: .failure, ofApplication: true) == .failed(.accessibilityRefused))
        #expect(AccessibilitySession.answer(for: .failure) == .absent)
    }

    /// macOS 27 renamed the list the permission is granted in; the message must name the one the
    /// reader will find. Found when a reader looked for "Accessibility" on macOS 27 and it was not there.
    @Test func thePermissionMessageNamesTheListOnThisMacOS() {
        #expect(PrivacySettings.accessibilityLocation(majorVersion: 26) == "System Settings → Privacy & Security → Accessibility")
        #expect(PrivacySettings.accessibilityLocation(majorVersion: 27)
            == "System Settings → Privacy & Security → Device Control and Data Access")
        #expect(SelectionReader.message(for: .accessibilityDisabled, app: "Safari").contains(PrivacySettings.accessibilityLocation))
    }

    @Test(arguments: [CaptureError.notResponding, .deadlineExceeded, .accessibilityDisabled, .appUnavailable, .accessibilityRefused, .cancelled])
    func eachFailureHasItsOwnMessage(error: CaptureError) {
        let others = [CaptureError.notResponding, .deadlineExceeded, .accessibilityDisabled, .appUnavailable, .accessibilityRefused, .cancelled]
            .filter { $0 != error }.map { SelectionReader.message(for: $0, app: "Safari") }
        #expect(!others.contains(SelectionReader.message(for: error, app: "Safari")))
    }
}
