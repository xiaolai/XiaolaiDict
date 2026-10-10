import AppKit
import Testing

@testable import XiaolaiDict

/// **Putting a note away brings no window of this app in front of the reader's** (reported by the owner 2026-10-10).
///
/// Reproduced on the E2E Mac by `--note-report`: Settings open behind TextEdit, one note on screen, a click on the note
/// — which makes this app active, the note key, and leaves Settings where it was — then a real click on its unpin
/// control. The note closed and AppKit made the window left behind it key: Settings, ordered in front of TextEdit,
/// key and main. So before a note closes, the activation the click gave this app goes back to the app whose window is
/// in front of every ordinary window of this one — and stays where it is when that window is this app's own.
struct PinnedNoteClosingTests {
    private let ours: pid_t = 100
    private let textEdit: pid_t = 200
    private let floating = PinnedNoteClosing.floatingLayer

    /// The reported case: the reader's app in front of Settings, this app active from the click on the note.
    @Test func activationGoesBackToTheAppWhoseWindowIsInFront() {
        let listed = [
            PinnedNoteClosing.Listed(owner: ours, layer: floating),   // the note itself, floating over everything
            PinnedNoteClosing.Listed(owner: textEdit, layer: 0),
            PinnedNoteClosing.Listed(owner: ours, layer: 0),          // Settings, behind
        ]
        #expect(PinnedNoteClosing.handBack(among: listed, ours: ours, isActive: true) == textEdit)
    }

    /// **A reader working in this app's own window keeps it.** Settings in front: closing a note must not send them away.
    @Test func aWindowOfThisAppInFrontKeepsTheActivation() {
        let listed = [
            PinnedNoteClosing.Listed(owner: ours, layer: floating),
            PinnedNoteClosing.Listed(owner: ours, layer: 0),
            PinnedNoteClosing.Listed(owner: textEdit, layer: 0),
        ]
        #expect(PinnedNoteClosing.handBack(among: listed, ours: ours, isActive: true) == nil)
    }

    /// Nothing to give back where this app is not active, and nothing to give it to where no ordinary window is listed.
    @Test func nothingIsHandedBackWithoutActivationOrAnotherWindow() {
        let behind = [PinnedNoteClosing.Listed(owner: textEdit, layer: 0), PinnedNoteClosing.Listed(owner: ours, layer: 0)]
        #expect(PinnedNoteClosing.handBack(among: behind, ours: ours, isActive: false) == nil)
        #expect(PinnedNoteClosing.handBack(among: [PinnedNoteClosing.Listed(owner: ours, layer: floating)], ours: ours,
                                           isActive: true) == nil)
    }

    /// **Wired**: the note's one way to put itself away — its button, Command-W, Escape and its menu all call it — goes
    /// through the controller, which decides, rather than straight to the window's dismissal.
    @Test func everyWayANoteIsPutAwayGoesThroughTheHandBack() throws {
        let scene = try String(contentsOf: AppModules.repository.appending(path: "Sources/XiaolaiDict/PinnedNoteController.swift"),
                               encoding: .utf8)
        #expect(scene.contains("PinnedNoteView(note: note) { controller.unpin(id) { dismiss() } }"),
                "a note is put away without handing the activation back")
    }
}
