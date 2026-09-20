import CoreGraphics
import Foundation
import XiaolaiDictCore
import Testing

@testable import XiaolaiDict

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
