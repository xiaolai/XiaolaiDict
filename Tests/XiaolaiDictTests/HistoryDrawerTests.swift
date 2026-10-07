import AppKit
import Capture
import CaptureModel
import CoreGraphics
import DictionaryModel
import Foundation
@testable import StudyKit
import Testing

@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// The drawer's own wiring. The geometry, the day grouping and the pile arithmetic are tested
/// where they live; what is left here is the part that can only go wrong in the controller.
@MainActor
struct HistoryDrawerTests {
    private let wide = ScreenMetrics(
        frame: UpRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: UpRect(x: 0, y: 0, width: 2560, height: 1410))
    private let neighbour = ScreenMetrics(
        frame: UpRect(x: 2560, y: 0, width: 2560, height: 1440),
        visibleFrame: UpRect(x: 2560, y: 0, width: 2560, height: 1410))

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Mutable so a test can unplug a display between calls.
    private final class Displays: @unchecked Sendable {
        var screens: [ScreenMetrics] = []
        var pointer = UpPoint(x: 100, y: 100)
    }

    private func entry(_ lemma: String, _ when: Date) -> ReadingEntry {
        ReadingEntry(
            id: 1, lemma: lemma, surface: lemma, sentence: "A sentence.", sentenceRange: nil,
            place: ReadingPlace(name: "TextEdit"), at: when, result: .found,
            quality: .accessibility(.accessibilityTextRange, context: .complete))
    }

    private func controller(
        displays: Displays, pointer: UpPoint = UpPoint(x: 100, y: 100),
        reading: @escaping @Sendable () -> HistoryReading = { .entries([]) }
    ) -> HistoryDrawerController {
        HistoryDrawerController(
            hotkeys: HotkeyCenter(backend: FakeBackend()),
            screens: { displays.screens },
            pointer: { pointer },
            clock: { self.now },
            load: { reading() })
    }

    @Test func aClosedDrawerHasNothingOnScreen() {
        let displays = Displays()
        displays.screens = [wide]
        #expect(!controller(displays: displays).isVisible)
    }

    @Test func openingLaysTheDrawerOutOnTheDisplayThePointerIsOn() {
        let displays = Displays()
        displays.screens = [wide, neighbour]
        let drawer = controller(displays: displays, pointer: UpPoint(x: 3000, y: 700))
        drawer.show()

        #expect(drawer.isVisible)
        let geometry = drawer.model.geometry
        #expect(geometry != nil)
        #expect(geometry.map { neighbour.frame.cg.union($0.windowRect.cg) == neighbour.frame.cg } == true)
    }

    @Test func aWindowAttachedAfterOpeningUsesTheDockedFrame() throws {
        let displays = Displays()
        displays.screens = [wide, neighbour]
        let drawer = controller(displays: displays, pointer: UpPoint(x: 3000, y: 700))
        drawer.show()
        let window = NSWindow(contentRect: CGRect(x: 500, y: 300, width: 428, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: true)
        drawer.attach(window)
        #expect(window.frame == drawer.placement)
        #expect(window.frame.maxX == neighbour.frame.cg.maxX)
    }

    @Test func anotherWindowAttachmentDoesNotRetainTheFirstWindowsPosition() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        drawer.show()
        for x in [100.0, 900.0] {
            let window = NSWindow(contentRect: CGRect(x: x, y: 200, width: 428, height: 900),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            drawer.attach(window)
            #expect(window.frame == drawer.placement)
        }
    }

    @Test func reopeningRepositionsARetainedHiddenWindow() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        let window = NSWindow(contentRect: CGRect(x: 500, y: 300, width: 428, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: true)
        drawer.show()
        drawer.attach(window)
        drawer.hide()
        window.setFrameOrigin(CGPoint(x: 500, y: 300))
        #expect(!window.isVisible)
        drawer.show()
        #expect(window.frame == drawer.placement)
    }

    /// With no display there is nothing to dock to. The drawer stays shut rather than being placed
    /// at the origin of a screen that is not there.
    @Test func withNoDisplayTheDrawerDoesNotOpen() {
        let drawer = controller(displays: Displays())
        drawer.show()
        #expect(!drawer.isVisible)
        #expect(drawer.model.geometry == nil)
    }

    @Test func openingAnAlreadyOpenDrawerChangesNothing() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        drawer.show()
        let first = drawer.model.geometry
        drawer.show()
        #expect(drawer.model.geometry == first)
    }

    /// The first read can still be waiting when the reader clicks again. Count the work,
    /// preserve the same pending task and keep the reader's open-session state.
    @Test func repeatedShowingPreservesTheOpenSession() async {
        let displays = Displays()
        displays.screens = [wide, neighbour]
        let backend = FakeBackend()
        let read = PendingRead()
        let drawer = HistoryDrawerController(
            hotkeys: HotkeyCenter(backend: backend), screens: { displays.screens },
            pointer: { displays.pointer }, clock: { now }, load: { await read.value() })
        defer { drawer.hide() }
        drawer.show()
        await read.started()
        let firstRead = drawer.reload
        let placement = drawer.placement
        let geometry = drawer.model.geometry
        let registrations = backend.registered.count
        drawer.model.revealed = true
        drawer.model.expandedDays = ["yesterday"]
        displays.pointer = UpPoint(x: 3000, y: 700)
        for _ in 0..<8 { drawer.show() }
        #expect(drawer.isVisible)
        #expect(read.calls == 1, "repeated opening started another ledger read")
        #expect(firstRead?.isCancelled == false, "repeated opening cancelled the first read")
        #expect(drawer.model.isLoading)
        #expect(drawer.model.revealed, "repeated opening reset the reveal animation")
        #expect(drawer.model.expandedDays == ["yesterday"])
        #expect(drawer.placement == placement)
        #expect(drawer.model.geometry == geometry)
        #expect(backend.registered.count == registrations, "repeated opening claimed Escape again")
        read.finish(.entries([entry("fine", now)]))
        await firstRead?.value
        drawer.show()
        #expect(read.calls == 1)
        #expect(!drawer.model.isLoading)
        #expect(drawer.model.totalEntries == 1)
    }

    @MainActor private final class PendingRead {
        private(set) var calls = 0
        private var waiting: CheckedContinuation<HistoryReading, Never>?
        private var observer: CheckedContinuation<Void, Never>?

        func value() async -> HistoryReading {
            calls += 1
            return await withCheckedContinuation { continuation in
                waiting = continuation
                observer?.resume()
                observer = nil
            }
        }

        func started() async {
            if calls > 0 { return }
            await withCheckedContinuation { observer = $0 }
        }

        func finish(_ answer: HistoryReading) {
            waiting?.resume(returning: answer)
            waiting = nil
        }
    }

    /// Assert the real monitor delegates to the same decision the point fixtures exercise.
    @Test func theLiveOutsideClickMonitorUsesTheTestedDecision() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repository.appending(path:
            "Sources/XiaolaiDict/HistoryDrawer.swift"), encoding: .utf8)
        let code = source.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.joined(separator: "\n")
        let monitor = try #require(code.range(of: "NSEvent.addGlobalMonitorForEvents("))
        let end = try #require(code.range(of: "private func removeClickAway()", range:
            monitor.upperBound..<code.endIndex))
        let body = code[monitor.lowerBound..<end.lowerBound]
        #expect(body.contains("clickedOutside(at: NSEvent.mouseLocation)"),
                "the live outside-click monitor bypasses the tested screen-point decision")
    }

    @Test func outsideClicksInsideTheOwnedButtonLeaveTheDrawerOpen() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        defer { drawer.hide() }
        let frame = CGRect(x: -240, y: 1420, width: 28, height: 20)
        drawer.statusItemFrame = { frame }
        drawer.show()
        for point in [CGPoint(x: frame.minX + 0.1, y: frame.minY + 0.1),
                      CGPoint(x: frame.midX, y: frame.midY),
                      CGPoint(x: frame.maxX - 0.1, y: frame.maxY - 0.1)] {
            drawer.clickedOutside(at: point)
            #expect(drawer.isVisible, "a point inside the owned button dismissed the drawer: \(point)")
            #expect(drawer.isEscapeClaimed)
        }
    }

    @Test func outsideClicksJustBeyondEveryButtonEdgeDismiss() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        defer { drawer.hide() }
        let frame = CGRect(x: 100, y: 1420, width: 28, height: 20)
        drawer.statusItemFrame = { frame }
        for point in [CGPoint(x: frame.minX - 0.1, y: frame.midY),
                      CGPoint(x: frame.maxX + 0.1, y: frame.midY),
                      CGPoint(x: frame.midX, y: frame.minY - 0.1),
                      CGPoint(x: frame.midX, y: frame.maxY + 0.1)] {
            drawer.show()
            drawer.clickedOutside(at: point)
            #expect(!drawer.isVisible, "a point just outside the button was excluded: \(point)")
            #expect(!drawer.isEscapeClaimed, "outside dismissal did not release Escape")
        }
    }

    @Test func outsideClickExclusionReadsTheCurrentRectangleEachTime() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        defer { drawer.hide() }
        let rectangle = ButtonRectangle()
        rectangle.frame = CGRect(x: 100, y: 1420, width: 28, height: 20)
        drawer.statusItemFrame = { rectangle.read() }
        drawer.show()
        drawer.clickedOutside(at: CGPoint(x: 114, y: 1430))
        #expect(drawer.isVisible)
        rectangle.frame = CGRect(x: -200, y: -40, width: 28, height: 20)
        drawer.clickedOutside(at: CGPoint(x: -186, y: -30))
        #expect(drawer.isVisible, "the changed button rectangle was ignored")
        drawer.clickedOutside(at: CGPoint(x: 114, y: 1430))
        #expect(!drawer.isVisible, "the stale button rectangle still excludes clicks")
        #expect(rectangle.reads == 3, "the button rectangle was cached instead of requested")
    }

    @MainActor private final class ButtonRectangle {
        var frame: CGRect?
        var reads = 0
        func read() -> CGRect? { reads += 1; return frame }
    }

    @Test func outsideClicksDismissWhenTheButtonRectangleIsMissing() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        defer { drawer.hide() }
        drawer.show()
        drawer.clickedOutside(at: CGPoint(x: 114, y: 1430))
        #expect(!drawer.isVisible, "a missing provider swallowed an outside click")
        drawer.statusItemFrame = { nil }
        drawer.show()
        drawer.clickedOutside(at: CGPoint(x: 114, y: 1430))
        #expect(!drawer.isVisible, "a nil rectangle swallowed an outside click")
        #expect(!drawer.isEscapeClaimed)
    }

    @Test func hidingReleasesEscapeAndReopeningClaimsItAgain() {
        let displays = Displays()
        displays.screens = [wide]
        let backend = FakeBackend()
        let drawer = HistoryDrawerController(hotkeys: HotkeyCenter(backend: backend),
            screens: { displays.screens }, pointer: { UpPoint(x: 100, y: 100) },
            load: { .entries([]) })
        defer { drawer.hide() }
        drawer.show()
        #expect(drawer.isEscapeClaimed)
        #expect(backend.registered.count == 1)
        drawer.hide()
        #expect(!drawer.isEscapeClaimed)
        #expect(backend.unregistered == 1)
        drawer.show()
        #expect(drawer.isEscapeClaimed)
        #expect(backend.registered.count == 2)
    }

    @Test func emptyHistoryRemainsAnOpenDrawerWithoutAReadProblem() async {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        defer { drawer.hide() }
        drawer.show()
        await drawer.reload?.value
        #expect(drawer.isVisible)
        #expect(drawer.model.days.isEmpty)
        #expect(drawer.model.problem == nil)
        #expect(!drawer.model.isLoading)
    }

    @Test func closingAClosedDrawerIsHarmless() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        drawer.hide()
        #expect(!drawer.isVisible)
    }

    @Test func toggleOpensThenCloses() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        drawer.toggle()
        #expect(drawer.isVisible)
        drawer.toggle()
        #expect(!drawer.isVisible)
    }

    // MARK: - Leaving for the Library, and clicks in this app's own windows

    /// The controller is what closes the panel when a card asks for the Library.
    @Test func showInLibraryHidesTheDrawer() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        var shown: [Int] = []
        drawer.model.showInLibrary = { shown.append($0.id) }
        drawer.show()
        drawer.model.openInLibrary(entry("fine", now))
        #expect(shown == [1])
        #expect(!drawer.isVisible, "the drawer stayed open over the Library it had just opened")
        #expect(!drawer.isEscapeClaimed)
    }

    /// **A click in another of this app's windows closes it; a click in the drawer does not.** The
    /// global monitor never fires for the app's own windows, so the drawer stayed open over the
    /// Library and Settings.
    @Test func aClickInAnotherOfTheAppsWindowsClosesTheDrawer() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        defer { drawer.hide() }
        let own = NSWindow(contentRect: CGRect(x: 500, y: 300, width: 428, height: 900),
                           styleMask: .borderless, backing: .buffered, defer: true)
        let library = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                               styleMask: .titled, backing: .buffered, defer: true)
        drawer.show()
        drawer.attach(own)

        drawer.clickedInApp(window: own, at: CGPoint(x: 600, y: 400))
        #expect(drawer.isVisible, "a click inside the drawer closed it")

        drawer.clickedInApp(window: library, at: CGPoint(x: 100, y: 100))
        #expect(!drawer.isVisible, "a click in the app's own Library left the drawer open")
    }

    /// The status item's window is this app's too, and its click belongs to its own action.
    @Test func aClickOnTheStatusItemIsStillItsOwn() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        defer { drawer.hide() }
        let frame = CGRect(x: 100, y: 1420, width: 28, height: 20)
        drawer.statusItemFrame = { frame }
        drawer.show()
        drawer.clickedInApp(window: nil, at: CGPoint(x: frame.midX, y: frame.midY))
        #expect(drawer.isVisible, "the status item's own click dismissed the drawer under it")
    }

    /// The live monitor for this app's own windows asks the decision tested above.
    @Test func theLiveInAppClickMonitorUsesTheTestedDecision() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repository.appending(path:
            "Sources/XiaolaiDict/HistoryDrawer.swift"), encoding: .utf8)
        let monitor = try #require(source.range(of: "NSEvent.addLocalMonitorForEvents("))
        let end = try #require(source.range(of: "private func removeClickAway()", range:
            monitor.upperBound..<source.endIndex))
        let body = source[monitor.lowerBound..<end.lowerBound]
        #expect(body.contains("clickedInApp(window: event.window, at: NSEvent.mouseLocation)"))
        #expect(body.contains("return event"), "the monitor swallowed the click it was watching")
    }

    // MARK: - Width

    /// **The drawer's width follows the reader's text**, and is asked for when it opens. It was a
    /// fixed 380 pt while the padding inside it grew with the text.
    @Test func theDrawerIsAsWideAsTheReadersTextSizeAsks() throws {
        let displays = Displays()
        displays.screens = [wide]
        // A box, because the controller asks again on each opening and the answer changes between.
        @MainActor final class Chosen { var size = TextSize.standard }
        let chosen = Chosen()
        let drawer = HistoryDrawerController(
            textSize: { chosen.size }, hotkeys: HotkeyCenter(backend: FakeBackend()),
            screens: { displays.screens }, pointer: { UpPoint(x: 100, y: 100) },
            load: { .entries([]) })
        defer { drawer.hide() }
        drawer.show()
        let standard = try #require(drawer.model.geometry).contentSize.width
        #expect(standard == DrawerMetrics.thickness(for: .standard))
        drawer.hide()
        chosen.size = .large
        drawer.show()
        let large = try #require(drawer.model.geometry).contentSize.width
        #expect(large == DrawerMetrics.thickness(for: .large))
        #expect(large > standard, "the drawer did not widen for larger text")
    }

    /// Wider with the text, and never so wide that the smallest display it runs on is mostly
    /// drawer: at every size it leaves more than half of a 1280 pt display.
    @Test func atEverySizeTheDrawerLeavesMostOfASmallDisplay() {
        let small: CGFloat = 1280
        var last: CGFloat = 0
        for size in TextSize.allCases {
            let width = DrawerMetrics.thickness(for: size)
            #expect(width >= last, "\(size) is narrower than the size below it")
            #expect(width <= small - width, "\(size): \(width) pt is over half of a \(small) pt display")
            // Room for a card's row of six 28 pt actions inside the list's and the card's padding.
            let column = width - Scale(size).space.padAcross * 4
            #expect(column >= Token.Target.minimum * 6, "\(size): \(column) pt cannot hold the actions")
            last = width
        }
        #expect(DrawerMetrics.thickness(for: .huge) == Token.Drawer.maxWidth, "the cap is not what stops it")
        #expect(DrawerMetrics.thickness(for: .standard) < Token.Drawer.maxWidth)
    }

    // MARK: - Contents

    @Test func whatTheLedgerReturnsBecomesDays() async {
        let displays = Displays()
        displays.screens = [wide]
        let entries = [entry("fine", now), entry("hold", now.addingTimeInterval(-86400))]
        let drawer = controller(displays: displays, reading: { .entries(entries) })
        drawer.show()
        await drawer.reload?.value

        #expect(drawer.model.days.count == 2)
        #expect(drawer.model.problem == nil)
        #expect(drawer.model.totalEntries == 2)
    }

    /// An empty drawer and a broken one must not look the same.
    @Test func aLedgerThatCannotBeReadSaysSoRatherThanLookingEmpty() async {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays, reading: { .unavailable("disk is full") })
        drawer.show()
        await drawer.reload?.value

        #expect(drawer.model.problem == "disk is full")
        #expect(drawer.model.days.isEmpty)
    }

    @Test func readingStopsBeingAdvertisedOnceItArrives() async {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        drawer.show()
        await drawer.reload?.value
        #expect(!drawer.model.isLoading)
    }

    // MARK: - Displays

    /// The drawer was open on a display that has just been unplugged.
    @Test func unpluggingTheDisplayTheDrawerIsOnClosesIt() {
        let displays = Displays()
        displays.screens = [wide, neighbour]
        let drawer = controller(displays: displays, pointer: UpPoint(x: 3000, y: 700))
        drawer.show()
        #expect(drawer.isVisible)

        displays.screens = [wide]
        drawer.screensChanged()
        #expect(!drawer.isVisible)
    }

    /// The same display rearranged is not a display that went away.
    @Test func rearrangingDisplaysKeepsTheDrawerOpen() {
        let displays = Displays()
        displays.screens = [wide, neighbour]
        let drawer = controller(displays: displays, pointer: UpPoint(x: 3000, y: 700))
        drawer.show()

        displays.screens = [neighbour, wide]
        drawer.screensChanged()
        #expect(drawer.isVisible)
    }

    @Test func aScreenChangeWhileClosedIsIgnored() {
        let displays = Displays()
        displays.screens = [wide]
        let drawer = controller(displays: displays)
        displays.screens = []
        drawer.screensChanged()
        #expect(!drawer.isVisible)
    }
}

/// What the panel's model counts, what it lets a card do, and what discarding a reading asks of
/// the ledger.
///
/// Discarding is reversible and goes through the ledger, with a receipt that Undo spends —
/// `HistoryDrawerUndoTests` has the undo. The six-second "Removed … Undo" row that used to be
/// tested here is deleted with its code: the shipped app could never reach it.
@MainActor
struct HistoryDrawerModelTests {
    private func entry(_ lemma: String, id: Int) -> ReadingEntry {
        ReadingEntry(
            id: id, lemma: lemma, surface: lemma, sentence: "A sentence.", sentenceRange: nil,
            place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: .found,
            quality: .accessibility(.accessibilityTextRange, context: .complete))
    }

    private func model(_ lemmas: [String]) -> HistoryDrawerModel {
        let model = HistoryDrawerModel()
        model.days = [ReadingDay(
            id: "d", date: .distantPast, label: .today,
            entries: lemmas.enumerated().map { entry($1, id: $0 + 1) })]
        return model
    }

    /// **The header says words, so it must count words.** It read `totalEntries`, which is one per
    /// lookup — and a reader meets the same word more than once. Measured on a real ledger
    /// 2026-09-30: 102 cards over 8 days, 74 words, and 19 cards repeating a word already shown
    /// that day in the same sentence. Yesterday alone was 9 cards for 4 words.
    @Test func theHeaderCountsWordsAndTheCardsCountLookups() {
        let model = model(["delirium", "delirium", "delirium", "malleable", "malleable", "vanish"])
        #expect(model.totalEntries == 6, "a card is a lookup, and there were six")
        #expect(model.distinctWords == 3, "the header promised words and gave \(model.distinctWords)")
    }

    /// **Three numbers, and the order between them can never break.** A card stands for one lookup
    /// or several, so lookups can never be fewer than cards; and a card holds one word, so words
    /// can never be more than cards. `--history-report` publishes all three and the drawer stage
    /// checks the ordering, because a collapse that invented a card would look right on screen.
    @Test func theThreeCountsCannotContradictEachOther() {
        // Stated rather than collapsed: `ReadingHistory.days` is where the folding is tested, and
        // this is about the three counts agreeing whatever the drawer was handed.
        func card(_ lemma: String, id: Int, repeats: [Int] = []) -> ReadingEntry {
            ReadingEntry(
                id: id, lemma: lemma, surface: lemma, sentence: "A sentence.", sentenceRange: nil,
                place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: .found,
                quality: .accessibility(.accessibilityTextRange, context: .complete),
                repeats: repeats)
        }
        let model = HistoryDrawerModel()
        model.days = [ReadingDay(
            id: "d", date: .distantPast, label: .today,
            entries: [card("delirium", id: 1, repeats: [2]), card("malleable", id: 3),
                      card("vanish", id: 4)])]
        #expect(model.totalEntries == 3, "cards")
        #expect(model.totalLookups == 4, "the lookups those cards stand for")
        #expect(model.distinctWords == 3, "words")
        #expect(model.totalLookups >= model.totalEntries)
        #expect(model.distinctWords <= model.totalEntries)
        // What the day's badge draws, and the days add up to what the header draws.
        #expect(model.days[0].lookups == 4)
        #expect(model.days.reduce(0) { $0 + $1.lookups } == model.totalLookups)
    }

    /// One lemma in two languages is two words — the pair a study note is keyed by.
    @Test func thewordCountSeparatesLanguages() {
        func word(_ language: String, id: Int) -> ReadingEntry {
            ReadingEntry(
                id: id, lemma: "gift", surface: "gift", sentence: "A sentence.", sentenceRange: nil,
                place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: .found,
                quality: .accessibility(.accessibilityTextRange, context: .complete),
                language: language)
        }
        let model = HistoryDrawerModel()
        model.days = [ReadingDay(
            id: "d", date: .distantPast, label: .today,
            entries: [word("en", id: 1), word("de", id: 2)])]
        #expect(model.totalEntries == 2)
        #expect(model.distinctWords == 2, "English gift and German Gift were counted as one word")
    }

    /// Counted over the days the drawer is showing, not over the ledger: a filtered drawer's
    /// header has to describe the drawer in front of the reader.
    @Test func theWordCountFollowsWhatTheDrawerIsShowing() {
        let model = model(["fine", "fine"])
        #expect(model.distinctWords == 1)
        model.days = []
        #expect(model.distinctWords == 0, "an empty drawer still claimed words")
    }

    /// A word met on two days is one word. The count is over the whole drawer, not per day.
    @Test func thesameWordOnTwoDaysIsStillOneWord() {
        let model = HistoryDrawerModel()
        model.days = [
            ReadingDay(id: "a", date: .distantPast, label: .today, entries: [entry("hive", id: 1)]),
            ReadingDay(id: "b", date: .distantPast, label: .yesterday, entries: [entry("hive", id: 2)]),
        ]
        #expect(model.totalEntries == 2)
        #expect(model.distinctWords == 1)
    }

    // MARK: - Discarding

    /// **The six-second removal is gone, not waiting.** With no `discard` wired the model used to
    /// hide the card, start a timer and delete the lookup when it ran out — an undo on a clock,
    /// reachable only from previews and from the tests that stood here. Nothing is wired, so
    /// nothing happens: the card stays, and no receipt appears for an Undo to spend.
    @Test func withNoLedgerToAskDiscardingDoesNothing() async {
        let model = model(["qqqq", "fine"])
        model.remove(entry("qqqq", id: 1))
        await Task.yield()
        #expect(model.days[0].entries.count == 2)
        #expect(model.discardedReceipt == nil)
        #expect(model.problem == nil)
    }

    /// Two clicks on the same card are one discard: the second arrives while the ledger is still
    /// answering the first.
    @Test func discardingTwiceAsksTheLedgerOnce() async throws {
        let model = model(["qqqq"])
        var asked = 0
        let (release, releasing) = AsyncStream<Void>.makeStream()
        model.discard = { _ in
            asked += 1
            for await _ in release { break }
            return DispositionResult(operation: UUID(), affected: 1, skipped: 0)
        }
        model.remove(entry("qqqq", id: 1))
        model.remove(entry("qqqq", id: 1))
        for _ in 0..<500 where asked == 0 { try await Task.sleep(for: .milliseconds(10)) }
        releasing.yield()
        for _ in 0..<500 where model.discardedReceipt == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(asked == 1, "the ledger was asked \(asked) times for one card")
        #expect(model.discardedReceipt?.affected == 1)
    }

    // MARK: - What a card can do

    /// A card offers only what is wired. A preview's model, with no ledger behind it, used to
    /// offer a Discard that ran the timer above.
    @Test func aCardOffersOnlyWhatIsWired() {
        let model = model(["fine"])
        let bare = model.actions(for: entry("fine", id: 1))
        #expect(bare.discard == nil && bare.save == nil && bare.showInLibrary == nil && bare.restore == nil)

        model.discard = { _ in DispositionResult(operation: UUID(), affected: 1, skipped: 0) }
        model.keepForLearning = { _ in }
        model.showInLibrary = { _ in }
        let wired = model.actions(for: entry("fine", id: 1))
        #expect(wired.discard != nil && wired.save != nil && wired.showInLibrary != nil)
        #expect(wired.restore == nil, "nothing in the panel is discarded, so nothing is restored there")
    }

    /// **Show in Library puts the panel away.** It floats, and left open it covered the right edge
    /// of the window it had just opened — toolbar and all.
    @Test func showingAReadingInTheLibraryDismissesThePanel() {
        let model = model(["fine"])
        var shown: [Int] = []
        var dismissed = 0
        model.showInLibrary = { shown.append($0.id) }
        model.dismiss = { dismissed += 1 }
        model.actions(for: entry("fine", id: 1)).showInLibrary?()
        #expect(shown == [1])
        #expect(dismissed == 1, "the panel stayed open over the Library")
    }

    /// With nothing to open the Library, there is nothing to close the panel for.
    @Test func withNoLibraryToShowThePanelStays() {
        let model = model(["fine"])
        var dismissed = 0
        model.dismiss = { dismissed += 1 }
        model.openInLibrary(entry("fine", id: 1))
        #expect(dismissed == 0)
    }

    // MARK: - Piles

    /// **One card is not a pile.** Tuesday held a single reading, said "Show All" over it, and put
    /// its buttons under the pile's click target.
    @Test func aDayOfOneCardIsNotAPile() {
        let model = HistoryDrawerModel()
        func day(_ label: DayLabel, _ count: Int) -> ReadingDay {
            ReadingDay(id: "\(label)-\(count)", date: .distantPast, label: label,
                       entries: (1...count).map { entry("word\($0)", id: $0) })
        }
        #expect(!model.showsAsPile(day(.yesterday, 1)), "a single card was piled")
        #expect(model.showsAsPile(day(.yesterday, 2)))
        #expect(model.showsAsPile(day(.weekday, 5)))
        // Today is listed however many it holds: it is what the reader came to read.
        #expect(!model.showsAsPile(day(.today, 1)))
        #expect(!model.showsAsPile(day(.today, 9)))
    }
}

/// What a history card says at the end of its line, and why there is one place that decides it.
@MainActor
struct CardBadgeTests {
    private static func entry(sense: SenseNote?, abstention: Abstention? = nil) -> ReadingEntry {
        ReadingEntry(
            id: 1, lemma: "charge", surface: "charge", sentence: "The police will charge him with fraud.",
            sentenceRange: nil, place: ReadingPlace(), at: .now, result: .found, quality: nil,
            sense: sense, senseAbstention: abstention)
    }

    private static let entryLevel = SenseNote(
        dictionary: "NOAD", block: nil, ordinal: nil, outOf: 12, gloss: nil, chosenBy: nil)

    /// **A refusal is not hidden behind a sense count.** A lookup that recorded the entry and no
    /// sense still has a note — its badge says "12 senses" — so the refusal has to be asked about
    /// first, or the reader is never told the model declined.
    @Test func aRefusalIsSaidRatherThanTheEntrysSenseCount() throws {
        let badge = try #require(CardBadge(of: Self.entry(sense: Self.entryLevel, abstention: .refused)))
        #expect(badge.text == "declined")
        #expect(!badge.isConfirmed)
        #expect(badge.explanation == Abstention.refused.reason)
    }

    /// **And the same for a model that answered "I cannot tell".** `.undecided` is the same shape as
    /// a refusal — something a model said about this sentence — and it was the same bug a second
    /// time: the card reported how many senses the entry has and dropped what the model decided.
    @Test func aModelThatSettledNothingIsSaidRatherThanTheEntrysSenseCount() throws {
        let badge = try #require(CardBadge(of: Self.entry(sense: Self.entryLevel, abstention: .undecided)))
        #expect(badge.text == "undecided")
        #expect(!badge.isConfirmed)
        #expect(badge.explanation == Abstention.undecided.reason)
        #expect(badge.text != Self.entryLevel.badge)

        // A tap outranks it, as it outranks a refusal.
        let tapped = SenseNote(
            dictionary: "NOAD", block: 1, ordinal: 4, outOf: 12, gloss: nil, chosenBy: .reader)
        #expect(CardBadge(of: Self.entry(sense: tapped, abstention: .undecided))?.text == tapped.badge)
    }

    /// Every other abstention leaves the card as it was: "no model here" is not a fact about this
    /// sentence, and the entry's own badge is what there is to say.
    @Test func otherAbstentionsLeaveTheEntrysBadgeAlone() throws {
        for why in [Abstention.unavailable, .noContext, .tooClose, .nothingFits, .noCandidates] {
            let badge = try #require(CardBadge(of: Self.entry(sense: Self.entryLevel, abstention: why)))
            #expect(badge.text == Self.entryLevel.badge, "\(why) changed the badge")
        }
    }

    /// **A tap outranks the refusal that came before it.** The model declined, the reader then
    /// chose a sense themselves, and both are on the row — a card still saying "declined" would be
    /// telling the reader their own answer was never given.
    @Test func aSenseTheReaderSettledOutranksAnEarlierRefusal() throws {
        let tapped = SenseNote(
            dictionary: "NOAD", block: 1, ordinal: 4, outOf: 12, gloss: "a price asked", chosenBy: .reader)
        let badge = try #require(CardBadge(of: Self.entry(sense: tapped, abstention: .refused)))
        #expect(badge.text == tapped.badge)
        #expect(badge.isConfirmed)
        // A sense the *model* proposed is a hypothesis, and does not outrank the refusal.
        let proposed = SenseNote(
            dictionary: "NOAD", block: 1, ordinal: 4, outOf: 12, gloss: "a price asked", chosenBy: .model)
        #expect(CardBadge(of: Self.entry(sense: proposed, abstention: .refused))?.text == "declined")
    }

    /// A sense the reader tapped is a fact; a card with nothing recorded has no badge at all.
    @Test func aRecordedSenseKeepsItsOwnBadgeAndNothingRecordedHasNone() throws {
        let tapped = SenseNote(
            dictionary: "NOAD", block: 1, ordinal: 4, outOf: 12, gloss: "a price asked",
            chosenBy: .reader)
        let badge = try #require(CardBadge(of: Self.entry(sense: tapped)))
        #expect(badge.text == tapped.badge)
        #expect(badge.isConfirmed)
        #expect(CardBadge(of: Self.entry(sense: nil)) == nil)
        #expect(CardBadge(of: Self.entry(sense: nil, abstention: .unavailable)) == nil)
    }
}
