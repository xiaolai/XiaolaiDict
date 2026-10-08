import AppKit
import Foundation
import ReviewKit
import StudyPresentation
import SwiftUI
import Testing
@testable import XiaolaiDictUI

/// **A held key answers a review card once.**
///
/// A SwiftUI keyboard shortcut presses its button on every keyDown it is handed, and a key held down
/// is a stream of them: one press, then autorepeats. Measured on the E2E Mac 2026-10-04 by the
/// `review` stage: holding `2` for 1.5 s — 31 repeats, every one delivered flagged as a repeat —
/// graded **six** cards, the one on screen and every card after it in the batch, each as Remembered.
/// The disabled-while-committing guard covers only the few milliseconds of the write; the next card is
/// drawn and enabled long before the next repeat arrives.
///
/// So the review controls refuse a repeat, and this is the rule they ask. Only the key's own press
/// counts; a click, and a fresh press of the same key, are answers.
@MainActor
struct ReviewKeyRepeatTests {
    private func key(_ characters: String, repeating: Bool, type: NSEvent.EventType = .keyDown) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: repeating, keyCode: 19)
    }

    @Test func anAutorepeatOfAHeldKeyIsRefused() throws {
        let repeated = try #require(key("2", repeating: true))
        #expect(ReviewView.isHeldKeyRepeat(repeated))
    }

    /// **The positive control**: the press that started the hold is an answer, or the rule above would
    /// pass by refusing every key.
    @Test func thePressThatStartsAHoldIsAnAnswer() throws {
        let pressed = try #require(key("2", repeating: false))
        #expect(!ReviewView.isHeldKeyRepeat(pressed))
    }

    @Test func aClickIsAnAnswer() throws {
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!ReviewView.isHeldKeyRepeat(click))
    }

    /// No event at all — an action reached some other way, VoiceOver's press — is not a held key.
    @Test func noEventIsNotAHeldKey() {
        #expect(!ReviewView.isHeldKeyRepeat(nil))
    }

    // MARK: - The guard, where the controls meet it

    /// **Through the function every control calls** (WI-8). The tests above ask the predicate, and
    /// would stay green with the guard taken out of the path a press takes: `press` is that path, so
    /// a repeat that reaches `act` from it is the defect itself. The press that started the hold does
    /// reach it, with the showing it was made on.
    ///
    /// **What this cannot see: where the showing comes from.** It hands `press` the right card itself,
    /// and the real path gets it from the action SwiftUI kept for the shortcut — which was the last
    /// card's (WI-8 follow-up). The tests under "Through SwiftUI's own shortcuts" press the key.
    @Test func aHeldKeyRepeatReachesNoAction() throws {
        let showing = UUID()
        let repeated: NSEvent = try #require(key("2", repeating: true))
        let pressed: NSEvent = try #require(key("2", repeating: false))
        var acted: [ReviewAction] = [], on: [UUID?] = []
        ReviewView.press(.grade(.good), on: showing, event: repeated) { acted.append($0); on.append($1) }
        #expect(acted.isEmpty, "the autorepeat of a held key answered")
        ReviewView.press(.grade(.good), on: showing, event: pressed) { acted.append($0); on.append($1) }
        #expect(acted == [.grade(.good)], "the press that started the hold was refused")
        #expect(on == [showing], "the answer did not name the card it was given on")
    }

    // MARK: - Through SwiftUI's own shortcuts

    /// A question, as the model publishes one: its own showing, everything else the same as the last.
    private func question(_ word: String, at position: Int, revealed: Bool = false) -> ReviewPresentation.Question {
        ReviewPresentation.Question(showing: UUID(), word: word, sentence: nil, source: "", position: position,
                                    batchSize: 3,
                                    answer: revealed ? ReviewPresentation.Answer(text: "QZX", dictionary: nil) : nil)
    }

    /// The card as the Review pane draws it, reading the pressing key from the harness.
    private func card(_ question: ReviewPresentation.Question, into acted: Acted,
                      _ pressing: @escaping @MainActor @Sendable () -> NSEvent?) -> some View {
        ReviewView(state: ReviewPresentation(stage: .asking(question))) { acted.calls.append(($0, $1)) }
            .environment(\.pressingEvent, pressing)
    }

    @MainActor private final class Acted {
        var calls: [(action: ReviewAction, showing: UUID?)] = []
    }

    /// **A key on a card drawn after another names the card drawn, not the one before it** (WI-8
    /// follow-up, measured on the E2E Mac 2026-10-05). The cards are drawn as the model draws them when
    /// a write and the next card's read both land inside one update: the same buttons, enabled
    /// throughout, only the question different. SwiftUI kept each shortcut's action from the first card,
    /// so every key on the second named the first — and the model, rightly, refused an answer about a
    /// card the sitting had left. `aHeldKeyRepeatReachesNoAction` hands `press` the showing itself and
    /// could not see this; here the key goes through SwiftUI, as the reader's does.
    @Test func aKeyOnACardDrawnAfterAnotherNamesTheCardDrawn() throws {
        let acted = Acted()
        let first = question("tenacious", at: 1)
        let keys = KeyboardHarness { card(first, into: acted, $0) }
        defer { keys.close() }
        try keys.press(.two)
        // **The positive control**: the harness reaches the shortcut at all, and names the card.
        #expect(acted.calls.map(\.action) == [.grade(.good)], "the key reached no action: \(acted.calls)")
        #expect(acted.calls.map(\.showing) == [first.showing])

        for (key, action) in [(HarnessKey.one, ReviewAction.grade(.again)), (.two, .grade(.good)),
                              (.s, .skip), (.t, .postpone), (.space, .reveal)] {
            acted.calls = []
            let next = question("lucid", at: 2)
            keys.show { card(next, into: acted, $0) }
            try keys.press(key)
            #expect(acted.calls.map(\.action) == [action], "\(key.characters) reached \(acted.calls.map(\.action))")
            #expect(acted.calls.map(\.showing) == [next.showing],
                    "\(key.characters) on the card drawn named the one before it")
        }

        // Open in Dictionary exists only once the meaning shows, so it is drawn on a revealed card first:
        // a button that appears with its card is registered with it, and would prove nothing.
        keys.show { card(question("frank", at: 3, revealed: true), into: acted, $0) }
        acted.calls = []
        let shown = question("candid", at: 3, revealed: true)
        keys.show { card(shown, into: acted, $0) }
        try keys.press(.e)
        #expect(acted.calls.map(\.action) == [.explore])
        #expect(acted.calls.map(\.showing) == [shown.showing], "E on the card drawn named the one before it")
    }

    /// **A held key answers the card it was pressed on, once** — the E2E stage's claim, in the same
    /// order: a card drawn after another, the press that starts the hold, the next card drawn while
    /// the key is still down, and the autorepeats landing on it. Every one of them is refused but the
    /// first, and the first names the card it was pressed on.
    @Test func aHeldKeyOnACardDrawnAfterAnotherAnswersThatCardOnce() throws {
        let acted = Acted()
        let keys = KeyboardHarness { card(question("tenacious", at: 1), into: acted, $0) }
        defer { keys.close() }
        let held = question("lucid", at: 2)
        keys.show { card(held, into: acted, $0) }
        try keys.press(.two)
        keys.show { card(question("frugal", at: 3), into: acted, $0) }
        try keys.repeats(.two, count: 5)
        #expect(acted.calls.map(\.action) == [.grade(.good)],
                "a held 2 reached \(acted.calls.count) action(s): \(acted.calls.map(\.action))")
        #expect(acted.calls.map(\.showing) == [held.showing], "the held key answered a card it was not pressed on")
    }

    /// **Every control on the asked card goes through that function**, with the question it was drawn
    /// for: a control that called `act` itself would skip the guard and name no card, and the test above
    /// could not see it. Read from the source, because a SwiftUI button cannot be pressed from a test.
    @Test func everyControlOnTheCardGoesThroughTheGuard() throws {
        let view = try source("Sources/XiaolaiDictUI/ReviewView.swift")
        let start = try #require(view.range(of: "private func controls("))
        let end = try #require(view.range(of: "private func answer(", range: start.upperBound..<view.endIndex))
        let controls = String(view[start.upperBound..<end.lowerBound])
        let buttons = controls.components(separatedBy: "IconButton(").count - 1
        let routed = controls.matches(of: /\{\s*answer\(\.[a-zA-Z]+(?:\(\.[a-zA-Z]+\))?, on: question\)\s*\}/).count
        #expect(buttons == 6, "show, open, forgot, remembered, skip and not today: \(buttons)")
        #expect(routed == buttons, "\(buttons - routed) control(s) do not answer through the guard")
        #expect(!controls.contains("act("), "a control on the card calls act itself")
        let press = try #require(view.range(of: "static func press(", range: end.upperBound..<view.endIndex))
        #expect(view[end.lowerBound..<press.lowerBound]
                    .contains("Self.press(action, on: question?.showing, event: pressingEvent(), act: act)"),
                "answer does not hand the pressing event to the guard")
        // **And in the app the pressing event is the application's current one**: the tests above hand
        // the card their own key, so this default is the one thing they cannot reach.
        #expect(view.contains("static let defaultValue: @MainActor @Sendable () -> NSEvent? = { NSApplication.shared.currentEvent }"),
                "the pressing event is not the application's current event by default")
        #expect(EnvironmentValues().pressingEvent() === NSApplication.shared.currentEvent)
    }

    /// The repository's source, with every line that is only a comment removed.
    private func source(_ path: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repository.appending(path: path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
