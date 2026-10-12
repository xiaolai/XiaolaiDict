import AppKit
import DictionaryModel
import SwiftUI
import Testing
import XiaolaiDictCore
@testable import XiaolaiDictUI

/// **The card's two disclosures belong to the entry they were opened on** (plan-card-refinements D2, 2026-10-10:
/// "Translations and notes" stays its own closed disclosure below "N other meanings", reset by the entry's identity).
///
/// Driven as a reader drives them: the real `LookupCardView` in a window, pressed with mouse events, and replaced in
/// place by another entry's card as the panel replaces it when the reader switches dictionary — the same view
/// re-rendered, so SwiftUI keeps its state unless something resets it.
///
/// **Measured, not assumed, 2026-10-10**: in a test process SwiftUI builds no Accessibility tree for a hosting view —
/// none of its children, on screen or off, by the modern or the legacy API — so nothing can be pressed by name. A mouse
/// press sent to the window (`sendEvent`, never the application's queue: `KeyboardHarness` says why) reaches the button
/// only while the window is ordered in; one never ordered in received seventeen presses and changed nothing. So the
/// window is ordered in far off every display. A control is found by pressing up from the card's bottom edge until a
/// press changes the card's height — the lowest control that does anything — and an open disclosure is told from a
/// closed one by which way that press moves the height.
@MainActor
struct CardDisclosureTests {
    private static let rich = SenseDisplay(
        translations: [.init(text: "公平的", indicator: "(just)"), .init(text: "公正的", indicator: nil)],
        indicators: [], englishDefinition: "treating people equally", notes: ["［作表語］"])

    /// Keyed by position, as most dictionaries' senses are — so two entries' keys repeat, as they do across dictionaries.
    private static func sense(_ ordinal: Int, _ label: String, display: SenseDisplay?) -> DictionarySense {
        DictionarySense(path: SensePath(block: 1, ordinal: ordinal), key: "fair.1.\(ordinal)", keyKind: .position,
                        definition: label, text: "\(label) — an example", display: display)
    }

    /// An entry of `fair`, headed the same however it is told apart: by its dictionary and its id — the entry's identity
    /// (`PanelSelection.identity`) — and by nothing a reader sees. With `displays` false its senses say nothing beyond
    /// their labels, so the card offers no details.
    private static func entry(_ id: String, dictionary: String = "牛津英汉汉英词典", displays: Bool = true) -> DictionaryEntry {
        let senses = [Self.sense(1, "公平的", display: displays ? rich : nil),
                      Self.sense(2, "美好的", display: displays ? rich : nil)]
        let document = EntryDocument(isStyled: true, entryID: id, homograph: nil,
                                     blocks: [SenseBlock(number: 1, partOfSpeech: "adjective", senses: senses)])
        return DictionaryEntry(dictionary: DictionaryIdentity(name: dictionary, identifier: dictionary), headword: "fair",
                               lookedUp: "fair", html: "<p/>", document: document)
    }

    /// The card for `entry`: leading with its first sense where `chosen`, and otherwise undecided — the card that opens
    /// its other meanings itself.
    private static func card(_ entry: DictionaryEntry, chosen: Bool = true) -> LookupCard {
        let mark: SenseMark? = chosen ? .chosen(key: "fair.1.1", by: .reader) : nil
        return LookupCard(presentation: EntryPresentation(entry: entry, mark: mark, met: []), term: "fair",
                          sentence: "It was a fair price.", mark: mark)
    }

    // MARK: - The host

    /// A window holding the card at its own height, ordered in off every display, re-rendered with a new card as the
    /// panel re-renders it.
    @MainActor
    final class Host {
        let window: NSWindow
        let host: NSHostingView<AnyView>

        init(_ card: LookupCard) {
            window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 396, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: Self.view(card))
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            render()
        }

        /// Put away at the end of the test that made it.
        func close() { window.orderOut(nil) }

        private static func view(_ card: LookupCard) -> AnyView {
            AnyView(LookupCardView(card: card).environment(\.scale, Scale.standard).frame(width: 396))
        }

        /// The same view given another card — another entry — as the panel gives it one.
        func show(_ card: LookupCard) {
            host.rootView = Self.view(card)
            render()
        }

        /// The card's height as it lays out now.
        var height: CGFloat { host.fittingSize.height }

        /// Brings the view up to date, lets what it scheduled for after the update run, and fits the window to it.
        func render() {
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date())
            }
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }

        /// One press — down and up — `top` points below the card's top edge, near its leading edge, where every row on
        /// the card starts.
        func press(atTop top: CGFloat) throws {
            let inWindow = host.convert(NSPoint(x: Scale.standard.space.pad.leading + 12, y: top), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
                render()
            }
        }

        /// **Presses the lowest control that does anything**, pressing up from the card's bottom edge a few points at a
        /// time, and answers how the press changed the card's height: more where a closed disclosure opened, less where
        /// an open one closed. Throws where no press changed anything — no disclosure, or presses that do not arrive.
        @discardableResult
        func pressLowestDisclosure() throws -> CGFloat {
            let before = height
            for top in stride(from: before - 1, to: 0, by: -2) {
                try press(atTop: top)
                if height != before { return height - before }
            }
            throw Undelivered(height: before)
        }

        struct Undelivered: Error, CustomStringConvertible {
            let height: CGFloat
            var description: String { "no press anywhere on the \(height)-point card changed it" }
        }
    }

    // MARK: - The details

    /// **The positive control: a press reaches the details and opens them**, and a second press closes them — so the
    /// sign of a press's change is a reading of the disclosure's state, and the presses arrive.
    @Test func aPressOpensTheDetailsAndASecondClosesThem() throws {
        let host = Host(Self.card(Self.entry("e1")))
        defer { host.close() }
        #expect(try host.pressLowestDisclosure() > 0, "the details were open on arrival")
        #expect(try host.pressLowestDisclosure() < 0, "the details did not close")
    }

    /// **The decision's test: another entry with identical display data comes up closed.** A reset that watched the
    /// details saw no change, and the second entry inherited the first's open disclosure.
    @Test func anotherEntryWithIdenticalDetailsComesUpClosed() throws {
        let first = Self.card(Self.entry("e1")), second = Self.card(Self.entry("e2"))
        #expect(first.details == second.details && first.heading == second.heading,
                "the fixture must be two entries a reader cannot tell apart by what they show")
        let host = Host(first)
        defer { host.close() }
        #expect(try host.pressLowestDisclosure() > 0)
        host.show(second)
        #expect(try host.pressLowestDisclosure() > 0, "the second entry came up with the first's details open")
    }

    /// **The same word in another dictionary**, the switch the reader makes from the card's own list.
    @Test func theSameWordInAnotherDictionaryComesUpClosed() throws {
        let host = Host(Self.card(Self.entry("e1")))
        defer { host.close() }
        #expect(try host.pressLowestDisclosure() > 0)
        host.show(Self.card(Self.entry("e1", dictionary: "牛津粵英雙語詞典")))
        #expect(try host.pressLowestDisclosure() > 0, "the other dictionary's card came up with its details open")
    }

    /// **Away and back**: an entry with no details in between — where the disclosure is not drawn, so nothing it carries
    /// can reset it — and the first entry again comes up closed. A new showing of an entry is a new arrival.
    @Test func anEntryLeftAndComeBackToComesUpClosed() throws {
        let entry = Self.entry("e1")
        let host = Host(Self.card(entry))
        defer { host.close() }
        #expect(try host.pressLowestDisclosure() > 0)
        host.show(Self.card(Self.entry("e9", displays: false)))
        host.show(Self.card(entry))
        #expect(try host.pressLowestDisclosure() > 0, "the entry came back with its details still open")
    }

    /// **The same entry drawn again keeps what the reader opened** — the sense mark arriving late is the same entry's
    /// card, and closing the details under the reader then would take back their press.
    @Test func theSameEntryDrawnAgainKeepsItsDetailsOpen() throws {
        let entry = Self.entry("e1")
        let host = Host(Self.card(entry, chosen: false))
        defer { host.close() }
        #expect(try host.pressLowestDisclosure() > 0)
        host.show(Self.card(entry, chosen: true))
        #expect(try host.pressLowestDisclosure() < 0, "the late sense mark closed the details the reader opened")
    }

    // MARK: - The other meanings

    /// **Opening the other meanings by itself leaves the details closed** — the card opens that list wherever it cannot
    /// name the meaning (every auxiliary dictionary's card), and the details must not come with it (D5). The list's own
    /// state is read on the same card without details, where it is the lowest disclosure.
    @Test func theOtherMeaningsOpeningThemselvesLeaveTheDetailsClosed() throws {
        let undecided = Self.card(Self.entry("e1"), chosen: false)
        #expect(undecided.opensAlternatives, "the fixture must be a card that opens its other meanings")
        let withoutDetails = Host(Self.card(Self.entry("e1", displays: false), chosen: false))
        defer { withoutDetails.close() }
        #expect(try withoutDetails.pressLowestDisclosure() < 0, "the other meanings did not open themselves")
        let host = Host(undecided)
        defer { host.close() }
        #expect(try host.pressLowestDisclosure() > 0, "the details opened with the other meanings")
    }

    /// **The other meanings follow the entry too** — the second instance of the same defect: their reset was keyed by
    /// the heading, which two entries of one word share, so closing the list on one left it closed on the next, against
    /// the rule that a card which cannot name the meaning opens it.
    @Test func anotherUndecidedEntryOpensItsOtherMeaningsAgain() throws {
        let host = Host(Self.card(Self.entry("e1", displays: false), chosen: false))
        defer { host.close() }
        #expect(try host.pressLowestDisclosure() < 0, "the fixture's list was not open to be closed")
        host.show(Self.card(Self.entry("e2", displays: false), chosen: false))
        #expect(try host.pressLowestDisclosure() < 0, "the next entry came up with the last one's list closed")
    }
}
