import AppKit
import Carbon.HIToolbox
@testable import XiaolaiDict
@testable import XiaolaiDictUI
import XiaolaiDictCore
import Testing

struct PanelPlacementTests {
    private let screen = UpRect(x: 0, y: 0, width: 1_440, height: 900)

    @Test func belowAndRightOfThePointer() {
        let frame = PanelPlacement.frame(for: NSSize(width: 400, height: 200), near: UpPoint(x: 100, y: 700), within: screen)
        #expect(frame.origin == NSPoint(x: 112, y: 476))
    }

    @Test func keptOnTheScreenNearAnEdge() {
        let frame = PanelPlacement.frame(for: NSSize(width: 400, height: 200), near: UpPoint(x: 1_430, y: 10), within: screen)
        #expect(screen.cg.insetBy(dx: 8, dy: 8).contains(frame))
    }

    /// Found by audit: a panel larger than the screen got an upper clamp below its lower one and was
    /// placed partly off screen. It is shrunk to fit first.
    @Test func aPanelLargerThanTheScreenIsShrunkOntoIt() {
        let small = UpRect(x: 0, y: 0, width: 600, height: 400)
        let frame = PanelPlacement.frame(for: NSSize(width: 760, height: 520), near: UpPoint(x: 300, y: 200), within: small)
        #expect(small.cg.insetBy(dx: 8, dy: 8).contains(frame))
        #expect(frame.size == NSSize(width: 584, height: 384))
    }

    // MARK: - Re-fitting a window the content has already resized

    /// The reported defect: a lookup near the bottom of the display grew when its other senses
    /// were opened and drew past the screen edge. The window is `.contentSize`, so it grows; the
    /// placement ran once, before the content existed.
    @Test func aWindowThatGrewDownwardIsPushedBackOn() {
        let grown = NSRect(x: 200, y: -180, width: 400, height: 600)
        let fitted = PanelPlacement.fitted(grown, within: screen)
        #expect(screen.cg.insetBy(dx: 8, dy: 8).contains(fitted))
        #expect(fitted.size == grown.size, "it fits, so nothing had to be given up")
    }

    /// **Every edge, not only the one that was reported.** Each case starts wholly or partly
    /// outside on one side; all four must come back inside, and none may be pushed out of the
    /// opposite side in the process.
    @Test func everyEdgeIsBroughtBackOnScreen() {
        let cases: [(String, NSRect)] = [
            ("below", NSRect(x: 200, y: -300, width: 400, height: 300)),
            ("above", NSRect(x: 200, y: 800, width: 400, height: 300)),
            ("left", NSRect(x: -380, y: 300, width: 400, height: 300)),
            ("right", NSRect(x: 1_400, y: 300, width: 400, height: 300)),
        ]
        for (edge, rect) in cases {
            let fitted = PanelPlacement.fitted(rect, within: screen)
            #expect(
                screen.cg.insetBy(dx: 8, dy: 8).contains(fitted),
                "a panel off the \(edge) edge was not brought back: \(fitted)")
        }
    }

    /// A window taller than the screen cannot be moved into it, so it is shrunk to the space there
    /// is and fills it.
    ///
    /// This deliberately does **not** assert which edge "survives" the shrink. A test that did was
    /// written and deleted: with the height reduced to exactly the screen's, the y clamp has a
    /// single legal value, so anchoring by the top and by the bottom give the same answer for every
    /// input — verified over 200,000 random rectangles. It would have passed against either
    /// implementation, which is not a check.
    @Test func aWindowTallerThanTheScreenIsShrunkToIt() {
        let tall = NSRect(x: 200, y: -600, width: 400, height: 1_400)
        let fitted = PanelPlacement.fitted(tall, within: screen)
        #expect(fitted.height == screen.cg.height - 16)
        #expect(screen.cg.insetBy(dx: 8, dy: 8).contains(fitted))
    }

    /// Both axes at once, which is the case a per-axis fix passes and a reader still sees broken.
    @Test func aWindowTooBigInBothAxesIsFittedInBoth() {
        let huge = NSRect(x: -100, y: -100, width: 2_000, height: 1_600)
        let fitted = PanelPlacement.fitted(huge, within: screen)
        #expect(screen.cg.insetBy(dx: 8, dy: 8).contains(fitted))
    }

    /// Idempotent: a frame already inside is not nudged. Otherwise every content update would
    /// creep the panel across the screen.
    @Test func aFrameAlreadyInsideIsLeftAlone() {
        let inside = NSRect(x: 300, y: 300, width: 400, height: 200)
        #expect(PanelPlacement.fitted(inside, within: screen) == inside)
        #expect(PanelPlacement.fitted(inside, within: screen) == PanelPlacement.fitted(PanelPlacement.fitted(inside, within: screen), within: screen))
    }

    /// Each kind of content has its own size; a lookup never gets a message's.
    @Test func eachKindHasItsOwnSizes() {
        #expect(PanelContent.Kind.lookup.defaultSize != PanelContent.Kind.message.defaultSize)
        for kind in [PanelContent.Kind.lookup, .message] {
            #expect(kind.minimumSize.width <= kind.defaultSize.width)
            #expect(kind.minimumSize.height <= kind.defaultSize.height)
        }
    }
}

@MainActor
struct PanelTicketTests {
    /// A newer request supersedes an older one: the older one's late result is dropped.
    @Test func aNewerRequestSupersedesAnOlderOne() {
        let panel = LookupPanelController()
        let older = panel.newRequest()
        let newer = panel.newRequest()
        #expect(!panel.isCurrent(older))
        #expect(panel.isCurrent(newer))
    }
}

/// Found by the verifier: a global monitor could not consume Escape — the app being read got it
/// too — and without Accessibility never heard it at all. Escape is now a hot key held only while
/// the panel shows.
@MainActor
struct EscapeKeyTests {
    @Test func escapeIsClaimedBareAndRoutedToThePanel() {
        let backend = FakeBackend()
        let center = HotkeyCenter(backend: backend)
        let escape = EscapeKey(hotkeys: center)
        var closed = false
        escape.claim { closed = true }
        #expect(backend.shortcuts == [Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)])
        #expect(center.route(EventHotKeyID(signature: HotkeyCenter.signature, id: backend.registered[0].id)) == noErr)
        #expect(closed)
    }

    /// Held only while the panel shows: released, Escape belongs to the app being read again.
    @Test func escapeIsReleasedWhenThePanelCloses() {
        let backend = FakeBackend()
        let center = HotkeyCenter(backend: backend)
        let escape = EscapeKey(hotkeys: center)
        escape.claim {}
        escape.claim {}  // a second show while open claims nothing more
        #expect(backend.registered.count == 1)
        escape.release()
        #expect(!escape.isHeld)
        #expect(backend.unregistered == 1)
        #expect(center.registrationCount == 0)
    }
}


/// **A card carries the lookup it is, and a tap belongs to that one.** The panel's own counter
/// moves when the *next* lookup starts — before its selection has been read, let alone drawn — so a
/// tap on the card still in front of the reader was being attributed to a lookup that had not
/// happened, and the ledger hung the sense off the wrong word.
@MainActor
struct PanelRequestIdentityTests {
    @Test func theContentKnowsWhichLookupItIs() {
        let presentation = LookupPresentation(
            request: 7, term: "hold", lemma: Lemma(text: "hold", basis: .tagger), source: nil,
            capture: .accessibility(.accessibilityTextRange, context: .complete))
        #expect(PanelContent.lookup(presentation).request == 7)
        // A message is not a lookup, so there is nothing for a tap to belong to.
        #expect(PanelContent.message(title: "no selection", detail: "…").request == nil)
    }

    /// The wire, read at its call site: nothing else can see which value the closure passes.
    @Test func theTapIsGivenTheCardsRequestAndNotTheCounter() throws {
        let panel = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDict/LookupPanel.swift")
        let text = try String(contentsOf: panel, encoding: .utf8)
        #expect(!text.isEmpty)
        #expect(text.contains("guard let request = content.request else { return }"))
        // **Every spelling of the counter, not one that was deleted.** This forbade
        // `controller.currentRequest`, a symbol removed in b3aac6d, so the only source text it
        // could match was text nobody can compile. Matching `controller.current` covers that name
        // and every other the counter could be exposed under — and the exposure is the defect's
        // first move: `current` is `private`, which in Swift is the declaring scope and not the
        // file, so a view in this same file cannot read it until somebody widens it. This is a
        // scan of source text, so it catches the widening and the read together.
        #expect(!text.contains("controller.current"),
                "a tap is attributed to whatever lookup the panel has moved on to")
    }
}

/// **One resize watch per panel, however many times its view is updated.** The window accessor's
/// closure runs on every update of the view it is attached to, and the panel's body reads the
/// model download's progress — so a 3 GB download registered a fresh observer a few hundred times,
/// each one outliving its window and firing for every resize afterwards.
///
/// What this can see is that one token is held and replaced. That the old one was *removed* is the
/// line beside it; no API reports what a notification centre is observing.
@MainActor
struct PanelResizeWatchTests {
    @Test func watchingAgainReplacesTheWatchRatherThanAddingOne() {
        let panel = LookupPanelController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(panel.resizeObserver == nil)
        panel.watchForResize(of: window)
        let first = try? #require(panel.resizeObserver)
        panel.watchForResize(of: window)
        let second = try? #require(panel.resizeObserver)
        #expect(first !== second, "the panel kept watching through its previous observer as well")

        // And the watch ends with the panel: registered still, it holds a closed window alive and
        // waits for a resize that cannot come.
        panel.show(
            .message(title: "anything", detail: "so that closing it is a real close"),
            near: UpPoint(.zero), for: panel.newRequest())
        panel.closed()
        #expect(panel.resizeObserver == nil, "the panel went on watching a window that had closed")
    }

    /// **The wire, not the value.** `PanelPlacement.fitted` is tested exhaustively above and was
    /// still reachable by nothing: the geometry was right and the window was never re-fitted,
    /// which is the whole shape of the reported defect. This asserts the observer exists and is
    /// removed with the panel — the two ways it silently stops working.
    @Test func theContentResizeWatchIsRegisteredAndReleasedWithThePanel() {
        let panel = LookupPanelController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(panel.fitObserver == nil)
        panel.watchForResize(of: window)
        #expect(panel.fitObserver != nil, "nothing would ever notice a resize the content caused")

        panel.show(
            .message(title: "anything", detail: "so that closing it is a real close"),
            near: UpPoint(.zero), for: panel.newRequest())
        panel.closed()
        #expect(panel.fitObserver == nil, "the observer outlived the window it watched")
    }

    /// A reader dragging the panel half off the screen is doing it on purpose, and snapping it back
    /// mid-drag would fight their hands. `inLiveResize` is the whole of that test, so it is worth
    /// one that fails if the guard is dropped.
    @Test func aWindowAlreadyOnScreenIsNotMoved() {
        let panel = LookupPanelController()
        guard let screen = NSScreen.main else { return }
        let inside = NSRect(
            x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 320, height: 240)
        let window = NSWindow(
            contentRect: inside, styleMask: [.borderless], backing: .buffered, defer: true)
        window.setFrame(inside, display: false)
        panel.keepWhollyOnScreen(window)
        #expect(window.frame == inside, "a panel that already fits must not be nudged")
    }
}
