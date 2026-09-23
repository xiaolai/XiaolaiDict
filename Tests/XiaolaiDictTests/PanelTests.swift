import AppKit
import Carbon.HIToolbox
@testable import XiaolaiDict
@testable import XiaolaiDictUI
import XiaolaiDictCore
import Testing
import WebKit

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

struct EntryNavigationTests {
    private let document = EntryNavigationPolicy.documentURL

    /// Only XiaolaiDict's own load of the document, in the main frame, and only while it is expected.
    @Test func onlyTheExpectedLoadIsAllowed() {
        #expect(EntryNavigationPolicy.allows(url: document, isMainFrame: true, expectingLoad: true))
        #expect(!EntryNavigationPolicy.allows(url: document, isMainFrame: true, expectingLoad: false))
        #expect(!EntryNavigationPolicy.allows(url: document, isMainFrame: false, expectingLoad: true))
        #expect(!EntryNavigationPolicy.allows(url: URL(string: "https://example.com/"), isMainFrame: true, expectingLoad: true))
        #expect(!EntryNavigationPolicy.allows(url: URL(string: "x-dictionary:r:run"), isMainFrame: true, expectingLoad: true))
    }

    /// The resource blocker must compile, or every entry would be refused its display.
    @Test @MainActor func theResourceBlockerCompiles() async throws {
        _ = try await EntryContentRules.compiled()
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
}
