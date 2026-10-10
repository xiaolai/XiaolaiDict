import AppKit
import Capture
import DictionaryModel
import SwiftUI
import Testing

@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **A pinned note's blank is the card's padding — above its first line and below its last** (reported by the owner
/// 2026-10-10, a note for “user” standing in far more white than the card it came from).
///
/// Two causes, each measured before it was fixed. **The title bar the scene hides kept its inset**: `.hiddenTitleBar`
/// hides the bar and SwiftUI still lays the content out below it, so the note's first line stood 32 pt (macOS 27's bar)
/// further down than its padding says — measured here, first ink 54 pt from the top of a window shaped as the scene's
/// against 22 pt in a borderless one. **And the window was a fixed 200 pt**, so a note shorter than that stood in the
/// difference below its last line — on the E2E Mac 47 pt above “user” and 51.5 pt below it at the standard size, against
/// the card's 15. The real window's blank is the `panel` E2E stage's to measure (`--note-report`): hosted here in a window
/// never put on screen, the note's window stayed at its opening 200 pt through ten turns of the run loop, and this
/// process may not put one on screen.
@MainActor struct PinnedNoteFitTests {
    private let user = PinnedNote(
        heading: "user", dictionary: DictionaryIdentity(name: "牛津英汉汉英词典", version: "1.1"),
        partOfSpeech: "noun", pronunciation: "ˈjuːzə", text: "使用者", standing: .proposed)

    /// A window shaped as SwiftUI makes one for `.hiddenTitleBar` — titled, its content under the bar, the bar clear and
    /// its title hidden; resizable, as a note is — or a borderless one, which reserves nothing.
    private func window(hidingItsTitleBar: Bool, at size: TextSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: hidingItsTitleBar
                ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
            backing: .buffered, defer: true)
        if hidingItsTitleBar {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        let notes = PinnedNoteController()
        let id = notes.pin(user, near: .zero)
        let hosted = NSHostingView(rootView: PinnedNoteSceneView(controller: notes, id: id)
            .environment(\.scale, Scale(size))
            .environment(\.colorScheme, .light)
            .background(Color.white))
        window.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        return window
    }

    /// The first row of dark ink from the top of the window's content, in points.
    private func firstInk(in window: NSWindow) throws -> CGFloat? {
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let perPoint = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                if colour.alphaComponent > 0.5, colour.brightnessComponent < 0.72 { return CGFloat(y) / perPoint }
            }
        }
        return nil
    }

    /// **The note's first line is as far from the top of its window as it would be with no title bar at all.** The
    /// first expectation is the positive control: the window shaped as the scene's really does reserve an inset for the
    /// bar, so a note that ignored nothing would be told apart — it was, by 32 pt, before the scene gave the inset up.
    @Test(arguments: [TextSize.standard, .huge])
    func aNoteRunsUnderTheTitleBarItsSceneHides(size: TextSize) throws {
        let titled = window(hidingItsTitleBar: true, at: size)
        let borderless = window(hidingItsTitleBar: false, at: size)
        #expect((titled.contentView?.safeAreaInsets.top ?? 0) > 0, "the scene's window shape reserves nothing, so this measures nothing")
        let underTheBar = try #require(try firstInk(in: titled), "nothing was drawn in the window shaped as the scene's")
        let withNoBar = try #require(try firstInk(in: borderless), "nothing was drawn in the borderless window")
        #expect(abs(underTheBar - withNoBar) <= 0.5,
                "at \(size) the note's first ink is \(underTheBar) pt down under a hidden title bar, \(withNoBar) pt with none")
    }

    /// **The fit is the card's, and it is on the note**: the window follows the words, and stops growing where the card
    /// does. A scan, because the fit runs only in a window that is on screen.
    @Test func theNoteIsFittedToItsWordsByTheCardsFit() throws {
        let view = try code("Sources/XiaolaiDictUI/PinnedNote.swift")
        #expect(view.contains(".fitsItsContent(upTo: scale.space.cardMaxHeight)"),
                "the note's window is not fitted to its words")
    }

    /// **No floor under the words.** A minimum height on the scene's content is a minimum the window cannot be fitted
    /// below: 140 pt stood a short note in white, as the fixed opening height did. The width keeps its floor.
    @Test func aNoteHasAWidthFloorAndNoHeightFloor() throws {
        let scene = try code("Sources/XiaolaiDict/PinnedNoteController.swift")
        #expect(scene.contains(".frame(minWidth: PinnedNoteController.narrowestNote)"), "a note has no width floor")
        #expect(!scene.contains("minHeight"), "a note's window has a height floor its words cannot fit below")
    }

    /// The source with comment lines removed, so a rule written out in a comment cannot satisfy a scan of the code.
    private func code(_ path: String) throws -> String {
        try String(contentsOf: AppModules.repository.appending(path: path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
