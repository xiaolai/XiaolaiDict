import AppKit
import Carbon.HIToolbox
@testable import XiaolaiDict
import XiaolaiDictCore
import Testing
import WebKit

struct PanelPlacementTests {
    private let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

    @Test func belowAndRightOfThePointer() {
        let frame = PanelPlacement.frame(for: NSSize(width: 400, height: 200), near: NSPoint(x: 100, y: 700), within: screen)
        #expect(frame.origin == NSPoint(x: 112, y: 476))
    }

    @Test func keptOnTheScreenNearAnEdge() {
        let frame = PanelPlacement.frame(for: NSSize(width: 400, height: 200), near: NSPoint(x: 1_430, y: 10), within: screen)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
    }

    /// Found by audit: a panel larger than the screen got an upper clamp below its lower one and was
    /// placed partly off screen. It is shrunk to fit first.
    @Test func aPanelLargerThanTheScreenIsShrunkOntoIt() {
        let small = NSRect(x: 0, y: 0, width: 600, height: 400)
        let frame = PanelPlacement.frame(for: NSSize(width: 760, height: 520), near: NSPoint(x: 300, y: 200), within: small)
        #expect(small.insetBy(dx: 8, dy: 8).contains(frame))
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
