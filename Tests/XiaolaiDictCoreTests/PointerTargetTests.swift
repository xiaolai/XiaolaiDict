import CoreGraphics
import Testing
@testable import XiaolaiDictCore

/// **Which window a capture reads**, decided once per hover over the compositor's list.
struct PointerTargetTests {
    private static let point = CGPoint(x: 100, y: 100)
    private static let ours: Int32 = 1
    private static let full = CGRect(x: 0, y: 0, width: 800, height: 600)

    private static func window(_ pid: Int32, _ id: UInt32, layer: Int = 0, alpha: Double = 1, bounds: CGRect = full) -> ListedWindow {
        ListedWindow(pid: pid, bounds: bounds, windowID: id, layer: layer, alpha: alpha)
    }

    private static func choose(_ windows: [ListedWindow], owner: Int32?) -> PointerTarget.Capture {
        PointerTarget(point: point, windows: windows, accessibilityOwner: owner).captureWindow(excludingProcess: ours)
    }

    /// **The capture reads the app Accessibility named**, even where another app's ordinary
    /// window comes first among layer 0. Red if the owner is ignored — which is the old rule.
    @Test func theNamedAppsWindowIsReadNotTheFirstOrdinaryOne() {
        let editor = Self.window(20, 200)
        let other = Self.window(30, 300)
        #expect(Self.choose([other, editor], owner: 20) == .window(editor, obscuredBy: other))
    }

    /// At any level: the named app's sheet or panel is its window too.
    @Test func theNamedAppsPanelCounts() {
        let panel = Self.window(20, 201, layer: 3)
        let document = Self.window(20, 200)
        #expect(Self.choose([panel, document], owner: 20) == .window(panel, obscuredBy: nil))
    }

    /// The named app has no window at the point: nothing is read, rather than another app's.
    @Test func aNamedAppWithNoWindowThereReadsNothing() {
        #expect(Self.choose([Self.window(30, 300)], owner: 20) == .ownerHasNoWindow(20))
    }

    /// With no owner, the old rule: the frontmost ordinary window that is not ours.
    @Test func withoutAnOwnerTheFrontmostOrdinaryWindowNotOursIsRead() {
        let menu = Self.window(40, 400, layer: 25)
        let mine = Self.window(Self.ours, 100)
        let terminal = Self.window(50, 500)
        #expect(Self.choose([menu, mine, terminal], owner: nil) == .window(terminal, obscuredBy: menu))
    }

    /// An invisible window owns no pixel, and a window elsewhere does not contain the point.
    @Test func invisibleAndDistantWindowsAreSkipped() {
        let ghost = Self.window(60, 600, alpha: 0)
        let away = Self.window(70, 700, bounds: CGRect(x: 500, y: 500, width: 10, height: 10))
        let terminal = Self.window(50, 500)
        #expect(Self.choose([ghost, away, terminal], owner: nil) == .window(terminal, obscuredBy: nil))
        #expect(Self.choose([ghost, away], owner: nil) == .noWindow)
    }

    /// `listed` keeps the window's number, level and opacity — the facts the choice reads.
    @Test func theListKeepsIdentityLevelAndOpacity() {
        let listed = PointerWindow.listed([[
            kCGWindowOwnerPID as String: Int32(9),
            kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 3, height: 4).dictionaryRepresentation,
            kCGWindowNumber as String: UInt32(77),
            kCGWindowLayer as String: 8,
            kCGWindowAlpha as String: 0.5,
        ]])
        #expect(listed == [ListedWindow(pid: 9, bounds: CGRect(x: 1, y: 2, width: 3, height: 4), windowID: 77, layer: 8, alpha: 0.5)])
    }
}

/// **One rule for whether hover may read an app**, asked at all three places that check.
struct CaptureAuthorizationTests {
    @Test func anExcludedAppIsRefused() {
        let policy = HoverPolicy.shipped
        let manager = HoverPolicy.defaultExcludedApps.first ?? ""
        #expect(CaptureAuthorization.refusal(bundleID: manager, policy: policy) == .excludedApp)
        #expect(CaptureAuthorization.refusal(bundleID: "com.apple.TextEdit", policy: policy) == nil)
    }

    /// An owner nobody can name is not refused by this rule; the capture refuses it on its own.
    @Test func anUnnamedOwnerIsLeftToTheCapture() {
        #expect(CaptureAuthorization.refusal(bundleID: nil, policy: .shipped) == nil)
    }
}

/// **Site exclusions, enforced** (WI-7): three answers about a site, one rule.
struct SiteExclusionTests {
    private static let strict = HoverPolicy(
        modifier: .option, excludedApps: [], excludedHosts: ["example.com"], settleMilliseconds: 0)

    @Test func aKnownExcludedHostIsRefusedAndItsNeighbourIsNot() {
        #expect(CaptureAuthorization.refusal(host: .known("Docs.Example.com."), policy: Self.strict) == .excludedSite)
        #expect(CaptureAuthorization.refusal(host: .known("example.org"), policy: Self.strict) == nil)
    }

    /// Text that is not a page has no site to exclude.
    @Test func textThatIsNotAPageIsNotRefused() {
        #expect(CaptureAuthorization.refusal(host: .notWebContent, policy: Self.strict) == nil)
    }

    /// **Fail closed.** A page that cannot be named might be one of the reader's sites — refused
    /// while the list has anything in it, and only then. Red if `unreadable` is read as harmless.
    @Test func anUnnamedPageIsRefusedOnlyWhileTheListHasSomething() {
        #expect(CaptureAuthorization.refusal(host: .unreadable, policy: Self.strict) == .excludedSite)
        #expect(CaptureAuthorization.refusal(host: .unreadable, policy: .shipped) == nil)
    }
}

/// What a typed site becomes.
struct SiteHostTests {
    /// **A pasted address is reduced to its host**, and nonsense is refused. Red if the address is
    /// stored whole — it could never match a page's host.
    @Test func aPastedAddressBecomesItsHost() {
        #expect(HoverPolicy.siteHost(fromTyped: "https://Docs.Example.com/page?q=1") == "docs.example.com")
        #expect(HoverPolicy.siteHost(fromTyped: " example.com. ") == "example.com")
        #expect(HoverPolicy.siteHost(fromTyped: "not a site") == nil)
        #expect(HoverPolicy.siteHost(fromTyped: "") == nil)
    }
}
