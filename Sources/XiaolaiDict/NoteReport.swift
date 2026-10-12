import AppKit
import ApplicationServices
import Capture
import CaptureModel
import DictionaryModel
import MacCapture
import XiaolaiDictBase
import XiaolaiDictUI

/// **What a pinned note's window is, how much blank it leaves above and below its words, and what a click on it does to
/// the reader's other windows** — `--note-report`, for two defects the owner reported inspecting a running build on
/// 2026-10-10.
///
/// - **The blank.** A pinned note for *user* stood in far more white above its heading and below its provenance than
///   the card it was pinned from. The note is pinned through `PinnedNoteController.pin` — the door the card's pin button
///   reaches — in the real `WindowGroup` scene, and its blank is read **through Accessibility**, as VoiceOver and the
///   harness's own helpers read a window: the compositor's frame against the frames of the static texts in it. What
///   the layout meant to do is not asked; what it did is.
/// - **What a click costs.** With Settings open and another app's window in front of it, the owner clicked a note's
///   unpin button and Settings jumped to the front. So Settings is opened as the reader opens it, the other app is put
///   in front of it, and a real click — the pointer moved there first, as a hand moves it — is posted on the note's
///   words and then on its unpin control. After each, the compositor's front-to-back list says whether Settings came
///   forward. The lookup panel is clicked the same way, because a panel is the other surface that floats over the
///   reader's work and the same mechanism could reach it.
///
/// Every number is a reading; the verdicts are the `panel` stage's. **A non-zero exit means a measurement could not be
/// made**, never that the app misbehaved. Compiled out of a release, as `--panel-report` is: it posts clicks.
@MainActor
enum NoteReport {
    static func run(in app: XiaolaiDictApp) async -> CommandStatus {
#if XIAOLAIDICT_CAPTURE_INSTRUMENTS
        guard await WindowActions.shared.ready() else {
            _ = Instrument.write(["problem": "the window actions never arrived, so nothing could open"])
            return .failure
        }
        guard let bounded = try? await withDeadline(budget, { await measure(in: app) }) else {
            _ = Instrument.write(["problem": "the note report exceeded its own \(budget) budget"])
            return .failure
        }
        return bounded
#else
        // Unreachable: `Instruments.run(.note)` refuses it in a release before a scene starts.
        _ = app
        return .usage
#endif
    }
}

#if XIAOLAIDICT_CAPTURE_INSTRUMENTS
extension NoteReport {
    /// The whole report's own bound. An instrument sets its own deadline; the reader's budget is not the measurement's.
    static let budget: Duration = .seconds(100)
    /// How long a window is given to be listed by the compositor.
    static let appearance: Duration = .seconds(10)
    /// How long a click is given to be delivered and acted on — and the window a consequence of it is watched for.
    static let delivery: Duration = .seconds(2)
    /// How long the pointer rests on a control before it is pressed. The unpin control is revealed under the pointer,
    /// over the view layer's hover motion (a tenth of a second and a little); a hand rests longer than that.
    static let reveal: Duration = .milliseconds(500)
    /// How long the pointer rests on a word before the button goes down — a hand's arrival, not a teleport.
    static let arrival: Duration = .milliseconds(250)
    /// How far outside a note the pointer starts from when it comes onto it.
    static let approach: CGFloat = 24
    /// How long a note's frame must hold still to count as settled, and the longest it is given.
    static let steady: Duration = .seconds(1)
    static let settling: Duration = .seconds(15)
    /// How often a frame is read while it is watched.
    static let sampling: Duration = .milliseconds(100)
    /// The app the reader is reading in, put in front of Settings: TextEdit, which the harness keeps open on its fixture.
    static let otherApp = "com.apple.TextEdit"
    /// Where across the screen each note is pinned, as a share of its usable width — apart, so neither covers the other.
    static let pinnedAcross: [CGFloat] = [0.05, 0.55]
    /// How far below the top of the usable screen the pointer stands when a note is pinned beside it.
    static let pinnedBelowTop: CGFloat = 80

    /// **The note the owner reported**, as the screenshot shows it — a Chinese–English entry's guess — and **one whose
    /// words wrap**, so a note several lines tall is measured too. Both are copies, as every note is (decision D3), so
    /// what they say is the whole of them; the second is this file's own words, not a dictionary's.
    static func notes() -> [PinnedNote] {
        [
            .measured(heading: "user",
                      dictionary: DictionaryIdentity(name: "牛津英汉汉英词典", version: "1.1"),
                      partOfSpeech: "noun", pronunciation: "ˈjuːzə", text: "使用者", standing: .proposed),
            .measured(heading: "sticky",
                      dictionary: DictionaryIdentity(name: "XiaolaiDict note report", version: "1"),
                      partOfSpeech: "adjective", pronunciation: nil,
                      text: "made of or covered in something that holds fast to whatever touches it, so that a note "
                          + "pressed to a page stays where it was put until someone lifts it away",
                      standing: .confirmed),
        ]
    }

    private static func measure(in app: XiaolaiDictApp) async -> CommandStatus {
        // The primary display, whose top is where every global coordinate starts, so a note pinned near its top has the
        // room below it to grow to its words.
        guard let screen = NSScreen.screens.first else {
            _ = Instrument.write(["problem": "no display to pin a note on"])
            return .failure
        }
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: otherApp).first else {
            _ = Instrument.write(["problem": "\(otherApp) is not running, so there is no app for Settings to be behind"])
            return .failure
        }
        var report: [String: Any] = ["textSize": app.appearance.textSize.rawValue, "otherApp": otherApp]

        // Settings, opened as the reader opens it, so it is a window the app treats as chosen.
        app.showSettings()
        guard await Instrument.settle(until: appearance, { Instrument.isOnScreen(app.settingsWindow) }),
              let settings = app.settingsWindow
        else {
            report["problem"] = "Settings was never listed by the compositor"
            _ = Instrument.write(report)
            return .failure
        }

        // The notes, pinned through the controller the card's pin button reaches.
        var measured: [[String: Any]] = []
        var shown: [NSWindow] = []
        let visible = screen.visibleFrame
        let primary = screen.frame.height
        // **Where the screen's usable area is, y down**, so the stage can hold a note to being on it.
        report["visible"] = PlacementReport.box(UpRect(visible).flipped(aboutPrimaryHeight: primary).cg)
        let pinned = app.panelController.notes
        for (index, (note, pointer)) in zip(notes(), pointers(on: visible)).enumerated() {
            let id = pinned.pin(note, near: pointer)
            guard await Instrument.settle(until: appearance, { Instrument.isOnScreen(pinned.window(of: id)) }),
                  let window = pinned.window(of: id)
            else {
                measured.append(["heading": note.heading, "appeared": false])
                continue
            }
            shown.append(window)
            var described = await describe(note, in: window)
            // **Where it was pinned, y down, and how many notes were open before it** — what the stage places it from.
            let down = pointer.flipped(aboutPrimaryHeight: primary).cg
            described["pinnedAt"] = ["x": down.x, "y": down.y]
            described["openBefore"] = index
            measured.append(described)
        }
        report["notes"] = measured
        guard let clicked = shown.first else {
            report["problem"] = "no note was listed by the compositor"
            _ = Instrument.write(report)
            return .failure
        }
        // **One note left**, as a reader with one sticky has: a second note on screen is a window that can take the
        // keyboard when the first closes, and would stand between the close and Settings.
        for other in shown.dropFirst() {
            _ = PlacementReport.press(endingWith: String(localized: ActionSymbol.unpinNote.title), inWindowTitled: other.title)
            _ = await Instrument.settle(until: delivery) { !Instrument.isOnScreen(other) }
        }
        report["notesLeftForTheClicks"] = shown.filter { Instrument.isOnScreen($0) }.count

        report["order"] = await clicks(on: clicked, settings: settings, other: other)
        report["panel"] = await panelClick(in: app, settings: settings, other: other)
        report["bothUnpinned"] = await unpinEach(pinned, at: pointers(on: visible))
        // **Two notes pinned at one point, the older one put away first while the newer stands over it** (2026-10-11):
        // the cascade's step must leave the older note's unpin control uncovered — mid-screen, and in the screen's
        // bottom-right corner, where clamping each note to the edge had put both at one place.
        let middle = UpPoint(NSPoint(x: visible.midX, y: visible.midY))
        report["stackedUnpinned"] = await unpinEach(pinned, at: [middle, middle])
        let corner = UpPoint(NSPoint(x: visible.maxX - PinnedNoteController.screenMargin,
                                     y: visible.minY + PinnedNoteController.screenMargin))
        report["stackedAtTheEdgeUnpinned"] = await unpinEach(pinned, at: [corner, corner])
        guard Instrument.write(report) else { return .failure }
        return .success
    }

    /// Where each note is pinned: near the top of the usable screen, apart across it.
    private static func pointers(on visible: NSRect) -> [UpPoint] {
        pinnedAcross.map { UpPoint(NSPoint(x: visible.minX + visible.width * $0, y: visible.maxY - pinnedBelowTop)) }
    }

    // MARK: - Two notes, each put away by a real click

    /// **Both notes on screen again, and each put away by a real click on its own unpin control, first the first** — the
    /// click reported not to reach the first note's control while a second was on screen (2026-10-10). Before each click,
    /// what the compositor draws frontmost at the point and what Accessibility finds there, so a click that lands on
    /// another window is told from one the control ignored.
    private static func unpinEach(_ pinned: PinnedNoteController, at pointers: [UpPoint]) async -> [[String: Any]] {
        var windows: [(heading: String, window: NSWindow)] = []
        for (note, pointer) in zip(notes(), pointers) {
            let id = pinned.pin(note, near: pointer)
            if await Instrument.settle(until: appearance, { Instrument.isOnScreen(pinned.window(of: id)) }),
               let window = pinned.window(of: id) {
                windows.append((note.heading, window))
            }
        }
        var results: [[String: Any]] = []
        for (heading, window) in windows {
            var result: [String: Any] = ["heading": heading, "notesOnScreen": windows.filter { Instrument.isOnScreen($0.window) }.count]
            guard let frame = (await PlacementReport.watch({ PlacementReport.listedFrame(of: window) }, steady: steady,
                                                           budget: settling, every: sampling)).frame,
                  let control = elements(in: frame).unpin
            else {
                result["problem"] = "the note's window or its unpin control could not be found"
                results.append(result)
                continue
            }
            let at = CGPoint(x: control.midX, y: control.midY)
            result["window"] = PlacementReport.box(frame)
            result["at"] = ["x": at.x, "y": at.y]
            result["frontmostAtThePoint"] = frontmost(at: at, mine: window, among: windows.map(\.window))
            result["hit"] = hit(at: at)
            _ = Instrument.postMouse(.mouseMoved, at: CGPoint(x: frame.minX - approach, y: frame.midY))
            try? await Task.sleep(for: arrival)
            // Onto the note's middle first and rested there, as `order` does and a hand does: the control is revealed under
            // the pointer, and a pointer teleported from outside straight onto it can arrive before the note has seen it enter.
            _ = Instrument.postMouse(.mouseMoved, at: CGPoint(x: frame.midX, y: frame.midY))
            try? await Task.sleep(for: reveal)
            result["posted"] = await click(at: at, resting: reveal)
            result["closed"] = await Instrument.settle(until: delivery) { !Instrument.isOnScreen(window) }
            results.append(result)
        }
        // Nothing left behind for the next run: a note a click did not reach is put away as VoiceOver would.
        for (_, window) in windows where Instrument.isOnScreen(window) {
            _ = PlacementReport.press(endingWith: String(localized: ActionSymbol.unpinNote.title), inWindowTitled: window.title)
            _ = await Instrument.settle(until: delivery) { !Instrument.isOnScreen(window) }
        }
        return results
    }

    /// **The window the compositor draws frontmost at `point`** (global, y down): `this note`, `another note`, or the owner
    /// and level of whatever else it is.
    private static func frontmost(at point: CGPoint, mine: NSWindow, among notes: [NSWindow]) -> String {
        let listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        // **Drawn, not merely listed**: the Dock's whole-display window some Macs have draws nothing (`SystemOverlaySurface`).
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &activeDisplays, &displayCount)
        let displays = activeDisplays.map { CGDisplayBounds($0) }
        guard let entry = listed.first(where: { entry in
            guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            let transparent = SystemOverlaySurface.isOne(
                owner: entry[kCGWindowOwnerName as String] as? String,
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                bounds: rect, displays: displays)
            return rect.contains(point) && !transparent
        }) else { return "nothing" }
        let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue
        if number == mine.windowNumber { return "this note" }
        if notes.contains(where: { $0.windowNumber == number }) { return "another note" }
        let owner = (entry[kCGWindowOwnerName as String] as? String) ?? "an unnamed owner"
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        return "\(owner), level \(layer)"
    }

    // MARK: - The blank

    /// One note's window and the frames of what is written in it — **all global and y down**, the compositor's frame and
    /// Accessibility's, so the stage subtracts one from the other in one space.
    private static func describe(_ note: PinnedNote, in window: NSWindow) async -> [String: Any] {
        let watched = await PlacementReport.watch({ PlacementReport.listedFrame(of: window) }, steady: steady,
                                                  budget: settling, every: sampling)
        var described: [String: Any] = [
            "heading": note.heading,
            "appeared": true,
            // What this window is: whether it can take the keyboard, and whether a click on it may activate the app.
            "class": window.className,
            "isPanel": window is NSPanel,
            "nonactivatingPanel": window.styleMask.contains(.nonactivatingPanel),
            "styleMask": window.styleMask.rawValue,
            "level": window.level.rawValue,
            "canBecomeKey": window.canBecomeKey,
            "canBecomeMain": window.canBecomeMain,
            "resizableByHand": window.isResizable,
            // What the title bar the scene hides still takes from the content: AppKit's own numbers, so a blank at the
            // top can be told from a window that is merely too tall.
            "safeAreaTop": window.contentView?.safeAreaInsets.top ?? -1,
            "contentLayoutHeight": window.contentLayoutRect.height,
            "frameHeight": window.frame.height,
        ]
        guard let frame = watched.frame else {
            described["settled"] = false
            described["problem"] = "the note's window never held still within \(settling)"
            return described
        }
        described["settled"] = true
        described["window"] = PlacementReport.box(frame)
        // Where the fit must stop growing — the bottom of the screen's usable area, y down — so a note whose words outrun
        // the room left below it can be told from one that was never fitted.
        if let screen = window.screen, let primary = NSScreen.screens.first?.frame.height {
            described["visibleBottom"] = primary - screen.visibleFrame.minY
        }
        let read = elements(in: frame)
        described["texts"] = read.texts
        // **Whether the unpin control is there for VoiceOver with no pointer over the note** — the rule the control's
        // comment states (`PinnedNoteView.unpinControl`), read here rather than believed.
        described["unpinListedAtRest"] = read.unpin != nil
        described["buttonsAtRest"] = read.buttons
        if let problem = read.problem { described["problem"] = problem }
        return described
    }

    /// **Every static text in the window drawn at `drawn`, and its unpin control, as Accessibility reports them** — y down,
    /// global. The window is found by where the compositor draws it, never by its title, which is the headword. Asked of
    /// this process on the main actor, where HIServices serves it in-process on the calling thread (ADR-0042).
    private static func elements(in drawn: CGRect) -> Read {
        let application = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(application, 2)
        guard let windows = value(application, kAXWindowsAttribute) as? [AXUIElement] else {
            return Read(problem: "Accessibility listed no windows for this process")
        }
        let atFrame = windows.first { candidate in
            guard let seen = frame(of: candidate) else { return false }
            return abs(seen.minX - drawn.minX) <= PlacementReport.slack && abs(seen.minY - drawn.minY) <= PlacementReport.slack
                && abs(seen.width - drawn.width) <= PlacementReport.slack
                && abs(seen.height - drawn.height) <= PlacementReport.slack
        }
        guard let window = atFrame else {
            return Read(problem: "Accessibility listed no window where the compositor draws the note, \(drawn)")
        }
        let unpinName = String(localized: ActionSymbol.unpinNote.title)
        var read = Read()
        var queue = [window]
        var head = 0
        while head < queue.count, head < 4_000 {
            let node = queue[head]
            head += 1
            let role = value(node, kAXRoleAttribute) as? String
            if role == kAXStaticTextRole, let rect = frame(of: node) {
                let said = value(node, kAXValueAttribute) as? String ?? value(node, kAXDescriptionAttribute) as? String ?? ""
                read.texts.append(["text": said, "frame": PlacementReport.box(rect)])
            }
            if read.tree.count < 80 {
                let said = [kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                            kAXHelpAttribute, kAXIdentifierAttribute]
                    .compactMap { value(node, $0) as? String }.filter { !$0.isEmpty }.joined(separator: "|")
                read.tree.append("\(role ?? "?") \(said.prefix(40))")
            }
            if role == kAXButtonRole {
                let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .compactMap { value(node, $0) as? String }.filter { !$0.isEmpty }
                read.buttons.append(names.joined(separator: " / "))
                if names.contains(unpinName) { read.unpin = frame(of: node) }
            }
            queue += value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        if read.texts.isEmpty { read.problem = "Accessibility listed no text in the note" }
        return read
    }

    /// What Accessibility listed in a note: its lines, every button by the names it answers to, and the unpin control.
    private struct Read {
        var texts: [[String: Any]] = []
        var buttons: [String] = []
        var tree: [String] = []
        var unpin: CGRect?
        var problem: String?
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success ? out : nil
    }

    /// An element's frame, global and y down, or nil where it has none — or one JSON cannot hold.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        // swiftlint:disable:next force_cast
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        let rect = CGRect(origin: origin, size: extent)
        guard rect.width > 0, rect.height > 0,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        return rect
    }

    // MARK: - What a click costs

    /// **Settings behind another app, then a click on the note's words, then one on its unpin control** — and after each,
    /// whether Settings came forward. The order the owner clicked in: the unpin control is revealed under the pointer,
    /// so a note is clicked before it is put away.
    private static func clicks(on note: NSWindow, settings: NSWindow, other: NSRunningApplication) async -> [String: Any] {
        var order: [String: Any] = ["measured": false]
        guard await putInFront(other, over: settings) else {
            order["problem"] = "\(otherApp) could not be put in front of Settings: \(snapshot(settings: settings, other: other))"
            return order
        }
        order["before"] = snapshot(settings: settings, other: other)

        // A click on the note's words, where nothing is pressed: what a click on the note itself costs.
        guard let noteFrame = PlacementReport.listedFrame(of: note) else {
            order["problem"] = "the note was no longer listed by the compositor"
            return order
        }
        let read = elements(in: noteFrame)
        // The note's corner with no pointer over it, to tell what the pointer reveals there.
        let atRest = await corner(of: noteFrame)
        // The lowest line wholly inside the window — the provenance where it fits, which is neither a control nor
        // selectable. **Never a line past the window's edge**: one scrolled out of it is drawn nowhere, and a click
        // aimed at it lands on whatever app is beneath.
        let frames = read.texts.compactMap { ($0["frame"] as? [String: Double]).map(rect) }.filter { noteFrame.contains($0) }
        guard let words = frames.max(by: { $0.maxY < $1.maxY }) else {
            order["problem"] = "no line of the note lies inside its window to click: \(read.problem ?? "no frame")"
            return order
        }
        let wordsAt = CGPoint(x: words.midX, y: words.midY)
        let bodyPosted = await click(at: wordsAt, resting: arrival)
        _ = await Instrument.settle(until: delivery) { settingsInFront(settings, other: other) == true }
        order["bodyClick"] = snapshot(settings: settings, other: other).merging([
            "posted": bodyPosted, "at": ["x": wordsAt.x, "y": wordsAt.y],
            "noteStillShown": Instrument.isOnScreen(note),
        ]) { $1 }

        // Then the unpin control, as the owner reached it: a note already clicked, Settings still behind the other app.
        order["beforeUnpin"] = snapshot(settings: settings, other: other)
        // The pointer comes onto the note from outside it, as a hand arrives there, and rests: the control is revealed
        // under it. From outside, because a pointer already inside since the click enters nothing.
        _ = Instrument.postMouse(.mouseMoved, at: CGPoint(x: noteFrame.minX - approach, y: noteFrame.midY))
        try? await Task.sleep(for: arrival)
        _ = Instrument.postMouse(.mouseMoved, at: CGPoint(x: noteFrame.midX, y: noteFrame.midY))
        try? await Task.sleep(for: reveal)
        let listed = elements(in: noteFrame)
        order["buttonsUnderThePointer"] = listed.buttons
        // **Where the control is: as Accessibility lists it, or where it was drawn.** Measured 2026-10-10 on the E2E Mac:
        // with the pointer over the note and the app active, Accessibility listed no button in it at all — so the
        // control is found by what the pointer revealed on the screen, the pixels in the note's corner that are dark
        // under the pointer and were not before it came.
        var drawn: CGRect?
        if let atRest, let underThePointer = await corner(of: noteFrame) {
            drawn = revealed(from: atRest, to: underThePointer)
        }
        order["unpinFoundBy"] = listed.unpin != nil ? "accessibility" : (drawn != nil ? "pixels" : "nothing")
        guard let control = listed.unpin ?? drawn else {
            order["problem"] = "the note's unpin control was neither listed nor drawn with the pointer over the note: "
                + "Accessibility listed the buttons \(listed.buttons)"
            return order
        }
        order["unpinControl"] = PlacementReport.box(control)
        let unpinAt = CGPoint(x: control.midX, y: control.midY)
        guard noteFrame.contains(unpinAt) else {
            order["problem"] = "the unpin control is listed outside the note's window, at \(control)"
            return order
        }
        order["hitAtTheControl"] = hit(at: unpinAt)
        let unpinPosted = await click(at: unpinAt, resting: reveal)
        let closed = await Instrument.settle(until: delivery) { !Instrument.isOnScreen(note) }
        _ = await Instrument.settle(until: delivery) { settingsInFront(settings, other: other) == true }
        order["unpin"] = snapshot(settings: settings, other: other).merging([
            "posted": unpinPosted, "at": ["x": unpinAt.x, "y": unpinAt.y], "noteClosed": closed,
        ]) { $1 }
        // Where the click did not put it away, the control pressed as VoiceOver presses it: whether the control's action
        // works, apart from whether a click reaches it.
        if !closed {
            order["pressedByAccessibility"] = PlacementReport.press(endingWith: String(localized: ActionSymbol.unpinNote.title),
                                                                    inWindowTitled: note.title)
            let pressedAway = await Instrument.settle(until: delivery) { !Instrument.isOnScreen(note) }
            _ = await Instrument.settle(until: delivery) { settingsInFront(settings, other: other) == true }
            order["unpinPressed"] = snapshot(settings: settings, other: other).merging(["noteClosed": pressedAway]) { $1 }
        }
        order["measured"] = true
        return order
    }

    /// **The lookup panel, clicked the same way** — the other surface that floats over the reader's work, and so the
    /// other place the same mechanism could reach. Its card is filled through the hover door, as `--panel-report`'s is,
    /// into this run's own ledger.
    private static func panelClick(in app: XiaolaiDictApp, settings: NSWindow,
                                   other: NSRunningApplication) async -> [String: Any] {
        var probe: [String: Any] = ["measured": false]
        guard await putInFront(other, over: settings) else {
            probe["problem"] = "\(otherApp) could not be put in front of Settings: \(snapshot(settings: settings, other: other))"
            return probe
        }
        let range = (PanelReport.sentence as NSString).range(of: PanelReport.term)
        let selection = Selection(
            text: PanelReport.term, sentence: PanelReport.sentence,
            rangeInSentence: range.location == NSNotFound ? nil : range,
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            place: ReadingPlace(bundleID: otherApp, name: "TextEdit"))
        app.lookUpHovered(selection, at: UpPoint(NSEvent.mouseLocation))
        guard await Instrument.settle(until: PanelReport.appearance, {
            Instrument.isOnScreen(app.panelController.window) && app.panelModel.content?.hasAnswered == true
        }), let panel = app.panelController.window,
              let shown = (await PlacementReport.watch({ PlacementReport.listedFrame(of: panel) }, steady: steady,
                                                        budget: settling, every: sampling)).frame
        else {
            probe["problem"] = "the lookup panel was never listed, answered and still"
            return probe
        }
        probe["before"] = snapshot(settings: settings, other: other)
        let center = CGPoint(x: shown.midX, y: shown.midY)
        let posted = await click(at: center, resting: arrival)
        _ = await Instrument.settle(until: delivery) { settingsInFront(settings, other: other) == true }
        probe["afterClick"] = snapshot(settings: settings, other: other).merging([
            "posted": posted, "at": ["x": center.x, "y": center.y],
            "panelStillShown": Instrument.isOnScreen(app.panelController.window),
        ]) { $1 }
        probe["measured"] = true
        app.panelController.close()
        return probe
    }

    /// **The other app in front of Settings**, by LaunchServices — what `open -a` does, and no Apple event of this
    /// process's own — then waited for until the compositor says so.
    private static func putInFront(_ other: NSRunningApplication, over settings: NSWindow) async -> Bool {
        if settingsInFront(settings, other: other) == false, frontmost() == otherApp { return true }
        guard let url = other.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return await Instrument.settle(until: delivery) {
            settingsInFront(settings, other: other) == false && frontmost() == otherApp
        }
    }

    /// **A note's top trailing corner as drawn** — where its unpin control appears once revealed — read off the screen:
    /// which of its pixels are dark, row by row, and where the corner is (global, y down). Nil where it could not be
    /// captured.
    private struct Corner {
        let region: CGRect
        let width: Int
        let height: Int
        let dark: [Bool]
    }
    /// The corner's size: room for the control and its padding at every text size, and short of the heading.
    private static let cornerSize = CGSize(width: 96, height: 110)
    /// Darker than this share of white is ink, against a note's paper.
    private static let inkBelow: CGFloat = 0.75

    private static func corner(of note: CGRect) async -> Corner? {
        guard let primary = NSScreen.screens.first?.frame.height,
              let screen = NSScreen.screens.first(where: {
                  UpRect($0.frame).flipped(aboutPrimaryHeight: primary).cg.contains(CGPoint(x: note.midX, y: note.midY))
              }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let region = CGRect(x: note.maxX - cornerSize.width, y: note.minY, width: cornerSize.width, height: cornerSize.height)
        let top = primary - screen.frame.maxY
        let source = CGRect(x: region.minX - screen.frame.minX, y: region.minY - top, width: region.width, height: region.height)
        let pixels = CGSize(width: region.width * screen.backingScaleFactor, height: region.height * screen.backingScaleFactor)
        guard let image = try? await withDeadline(.seconds(30), {
            try await Instrument.screenImage(of: source, size: pixels, onDisplay: number.uint32Value)
        }) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        var dark: [Bool] = []
        dark.reserveCapacity(bitmap.pixelsWide * bitmap.pixelsHigh)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                dark.append(colour.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 < inkBelow } ?? false)
            }
        }
        return Corner(region: region, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, dark: dark)
    }

    /// **What appeared between two readings of the corner**: the box round the pixels dark in the second and not the
    /// first — global, y down — or nil where nothing did.
    private static func revealed(from before: Corner, to after: Corner) -> CGRect? {
        guard before.width == after.width, before.height == after.height, after.width > 0 else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<after.height {
            for x in 0..<after.width where after.dark[y * after.width + x] && !before.dark[y * after.width + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let perPoint = CGFloat(after.width) / after.region.width
        return CGRect(x: after.region.minX + CGFloat(minX) / perPoint, y: after.region.minY + CGFloat(minY) / perPoint,
                      width: CGFloat(maxX - minX + 1) / perPoint, height: CGFloat(maxY - minY + 1) / perPoint)
    }

    /// The pointer moved to `point` — global, y down — left there for `resting`, then a press held as a finger holds
    /// one, and a release.
    private static func click(at point: CGPoint, resting: Duration) async -> Bool {
        guard Instrument.postMouse(.mouseMoved, at: point) else { return false }
        try? await Task.sleep(for: resting)
        guard Instrument.postMouse(.leftMouseDown, at: point) else { return false }
        try? await Task.sleep(for: held)
        return Instrument.postMouse(.leftMouseUp, at: point)
    }

    /// How long the button is held down in a click.
    static let held: Duration = .milliseconds(100)

    /// **What Accessibility says is at `point`** (global, y down) in this process — the role and names of the element a
    /// click there would reach — asked on the main actor (ADR-0042).
    private static func hit(at point: CGPoint) -> String {
        let application = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(application, 2)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element) == .success,
              let element else { return "nothing" }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { value(element, $0) as? String }.filter { !$0.isEmpty }
        return names.joined(separator: " | ")
    }

    /// **Whether Settings is in front of the other app's frontmost window**, by the compositor's own front-to-back list —
    /// nil where either is not listed, which is not an answer either way.
    private static func settingsInFront(_ settings: NSWindow, other: NSRunningApplication) -> Bool? {
        let listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let ours = listed.firstIndex { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == settings.windowNumber }
        let theirs = listed.firstIndex {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == other.processIdentifier
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        guard let ours, let theirs else { return nil }
        return ours < theirs
    }

    /// Where the reader's attention is: who is in front, whether this app is active, which of its windows has the
    /// keyboard, and whether Settings is in front of the other app.
    private static func snapshot(settings: NSWindow, other: NSRunningApplication) -> [String: Any] {
        [
            "frontmost": frontmost(),
            "appIsActive": NSApplication.shared.isActive,
            "settingsInFront": settingsInFront(settings, other: other).map { $0 as Any } ?? NSNull(),
            "settingsIsKey": settings.isKeyWindow,
            "settingsIsMain": settings.isMainWindow,
            // Settings, or another window by its level — a note and the panel float (3), Settings and the Library do not.
            "keyWindow": NSApplication.shared.keyWindow.map { $0 === settings ? "Settings" : "level \($0.level.rawValue)" }
                ?? "none",
        ]
    }

    private static func frontmost() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier ?? app?.localizedName ?? "none"
    }

    private static func rect(_ box: [String: Double]) -> CGRect {
        CGRect(x: box["x"] ?? 0, y: box["y"] ?? 0, width: box["width"] ?? 0, height: box["height"] ?? 0)
    }
}
#endif
