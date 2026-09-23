import CoreGraphics
import Foundation
import XiaolaiDictCore
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

/// Removing a lookup the reader did not mean to make.
///
/// The card leaves the drawer at once and the ledger is not touched until the grace window runs
/// out, so undo is a cancellation rather than a restore — a `ReadingEntry` is not the whole row,
/// and putting one back would return a poorer record than the one it replaced.
@MainActor
struct HistoryRemovalTests {
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

    @Test func aRemovedCardLeavesTheDrawerAtOnce() {
        let model = model(["qqqq", "fine"])
        model.remove(entry("qqqq", id: 1))
        #expect(model.removing.contains(1))
        // Still in `days`, so the row keeps its place and the list does not jump while the
        // reader may be reaching back for it.
        #expect(model.days[0].entries.count == 2)
    }

    /// The ledger must not be asked until the reader is out of time.
    @Test func theLedgerIsNotToldWhileUndoIsStillOffered() {
        let model = model(["qqqq"])
        var deleted: [Int] = []
        model.delete = { deleted.append($0.id) }
        model.remove(entry("qqqq", id: 1))
        #expect(deleted.isEmpty, "the row was deleted before the reader could undo")
    }

    @Test func undoPutsTheCardBackAndNeverTouchesTheLedger() {
        let model = model(["qqqq"])
        var deleted: [Int] = []
        model.delete = { deleted.append($0.id) }
        model.remove(entry("qqqq", id: 1))
        model.keep(entry("qqqq", id: 1))
        #expect(model.removing.isEmpty)
        #expect(deleted.isEmpty)
    }

    /// Closing the drawer is the reader moving on, not changing their mind.
    @Test func closingTheDrawerFinishesWhatWasRemoved() {
        let model = model(["qqqq", "fine"])
        var deleted: [Int] = []
        model.delete = { deleted.append($0.id) }
        model.remove(entry("qqqq", id: 1))
        model.commitRemovals()
        #expect(deleted == [1])
        #expect(model.days[0].entries.map(\.lemma) == ["fine"])
    }

    /// A header over no cards reads as a drawer that is broken, not as an empty day.
    @Test func aDayWithNothingLeftInItGoesToo() {
        let model = model(["qqqq"])
        model.delete = { _ in }
        model.remove(entry("qqqq", id: 1))
        model.commitRemovals()
        #expect(model.days.isEmpty)
    }

    /// Two clicks on the same card is one removal, not two deletions.
    @Test func removingTwiceIsRemovingOnce() {
        let model = model(["qqqq"])
        var deleted: [Int] = []
        model.delete = { deleted.append($0.id) }
        model.remove(entry("qqqq", id: 1))
        model.remove(entry("qqqq", id: 1))
        model.commitRemovals()
        #expect(deleted == [1])
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
