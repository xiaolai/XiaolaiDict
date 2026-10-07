import Capture
import Foundation
import StudyKit
import XiaolaiDictCore
import Observation
import SwiftUI

/// What the drawer is showing, and how much of it is fanned open.
@Observable
@MainActor
public final class HistoryDrawerModel {
    /// Nil until the drawer has been laid out for a display. The root view draws nothing rather
    /// than guessing a size — a sentinel rect would reach AppKit as a window nobody can see.
    public var geometry: DrawerGeometry?
    /// Drives the slide. **The window never moves while this animates.**
    public var revealed = false
    public var days: [ReadingDay] = []
    /// Day ids whose pile is fanned open. Today is never in here; it is never piled.
    public var expandedDays: Set<String> = []
    /// Set while the ledger is being read, so the drawer can say so instead of looking empty.
    public var isLoading = false
    /// A ledger that could not be read. Shown, never swallowed — an empty drawer and a broken one
    /// must not look the same.
    public var problem: String?

    public var discard: (@MainActor (ReadingEntry) async throws -> DispositionResult)?
    public var undoDiscard: (@MainActor (UUID) async throws -> DispositionResult)?
    public var keepForLearning: (@MainActor (ReadingEntry) -> Void)?
    public var showInLibrary: (@MainActor (ReadingEntry) -> Void)?
    /// Closes the panel. Set by the controller that shows it; nil in previews and tests of the
    /// contents alone.
    public var dismiss: (@MainActor () -> Void)?
    public private(set) var discardedReceipt: DispositionResult?

    public init() {}

    public func undoLastDiscard() {
        guard let receipt = discardedReceipt, let undoDiscard else { return }
        Task {
            do {
                let result = try await undoDiscard(receipt.operation)
                if result.skipped > 0 {
                    problem = String(localized: "Some readings changed after they were discarded and were left as they are.")
                }
                // **Only this undo's receipt.** A discard made while the ledger was answering has
                // installed its own, and clearing that one leaves its readings with no way back.
                if discardedReceipt?.operation == receipt.operation { discardedReceipt = nil }
            } catch { problem = error.localizedDescription }
        }
    }

    private var discarding: Set<Int> = []

    /// Discards a reading — reversibly, through the ledger, with a receipt that Undo spends.
    ///
    /// **There is no second path.** Until 2026-10-02 a model with no `discard` wired fell back to
    /// a six-second "Removed … Undo" row that deleted the lookup when the time ran out: an undo
    /// on a timer, which the shipped app could never reach because it always wires `discard`.
    /// It lived on in previews and nine tests. Without a ledger to ask there is nothing to
    /// discard from, so this does nothing.
    public func remove(_ entry: ReadingEntry) {
        guard let discard, discarding.insert(entry.id).inserted else { return }
        Task {
            defer { discarding.remove(entry.id) }
            do {
                let receipt = try await discard(entry)
                if receipt.affected > 0 { discardedReceipt = receipt }
            } catch { problem = error.localizedDescription }
        }
    }

    /// Opens the reading in the Library **and puts the panel away**. The Library is a window the
    /// reader is about to work in, and the panel floats: left open it covered the right edge of
    /// the window it had just opened, toolbar and all (measured 2026-10-01).
    public func openInLibrary(_ entry: ReadingEntry) {
        guard let showInLibrary else { return }
        showInLibrary(entry)
        dismiss?()
    }

    /// Whether a day is drawn as a pile. **One card is not a pile**: it offered "Show All" over a
    /// single card, and its buttons sat under the pile's own click target, so the reader paid a
    /// click that revealed nothing in order to use them.
    public func showsAsPile(_ day: ReadingDay) -> Bool {
        day.isPiled && day.entries.count > 1
    }

    public var totalEntries: Int { days.reduce(0) { $0 + $1.entries.count } }

    /// How many **lookups** the cards stand for — always at least `totalEntries`, and more wherever
    /// a reading was met again. Three numbers describe this drawer and they are all different:
    /// cards, the lookups behind them, and the words. Reported by `--history-report` so a stage can
    /// compare them. On screen the header and each day count **this** — readings — so a day's
    /// cards add up to its count by their "×N", and the days to the header.
    public var totalLookups: Int {
        days.reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.times } }
    }

    /// How many **words** the history holds, which is not how many cards it draws.
    ///
    /// A card is one lookup, and a reader meets the same word more than once: measured on a real
    /// ledger 2026-09-30, 102 cards over 8 days carried 74 words, and 19 of those cards repeated a
    /// word already shown that day in the same sentence. The header said "102 words" — it was
    /// reading `totalEntries`, whose own name says what it counts. Since 2026-10-02 the header
    /// says readings and counts `totalLookups`, the unit the day counts beside it are in; this is
    /// reported by `--history-report` and shown nowhere.
    ///
    /// Counted over `days` rather than over the ledger, so a filtered drawer's header describes the
    /// drawer the reader is looking at. Lemmas, because that is what the ledger keys a word by;
    /// `surface` would count `vanish` and `vanished` as two.
    public var distinctWords: Int {
        // **Lemma *and* language**, the pair a study note is keyed by. English `gift` and German
        // `Gift` are two words with two ledger identities, and the drawer filters by script — which
        // both of those pass. Counting lemmas alone made them one.
        struct Word: Hashable { let lemma: String; let language: String? }
        return Set(days.lazy.flatMap(\.entries).map { Word(lemma: $0.lemma, language: $0.language) }).count
    }

    public func isExpanded(_ day: ReadingDay) -> Bool { expandedDays.contains(day.id) }

    public func setExpanded(_ expanded: Bool, for day: ReadingDay) {
        if expanded { expandedDays.insert(day.id) } else { expandedDays.remove(day.id) }
    }
}

/// How wide the Reading History panel is for a reader's text size. **Public**, because the
/// controller that docks it lives in the app target and has to lay the window out before any view
/// exists to read the scale from.
public enum DrawerMetrics {
    public static func thickness(for size: TextSize) -> CGFloat { Scale(size).space.drawerWidth }
}

/// **The one animation that owns the panel's arrival and departure.**
///
/// There were two. The controller wrapped `revealed` in a spring, and the view that drew it
/// carried `.animation(.easeOut(0.16), value: revealed)` — and an implicit animation on a view
/// replaces the transaction's for that view, so the springs the controller's comments described
/// were never what played, and the close's `completion:` belonged to an animation that was not
/// the one running. The view's is gone; this is the only definition.
///
/// With Reduce Motion the panel does not travel at all — the view holds it in place — and this
/// becomes the short fade its opacity takes.
public enum DrawerMotion {
    public static func open(reduceMotion: Bool) -> Animation {
        MotionPreference.animation(
            .spring(response: Token.Motion.drawerOpenResponse, dampingFraction: Token.Motion.drawerOpenDamping),
            reduceMotion: reduceMotion)
    }

    public static func close(reduceMotion: Bool) -> Animation {
        MotionPreference.animation(
            .spring(response: Token.Motion.drawerCloseResponse, dampingFraction: Token.Motion.drawerCloseDamping),
            reduceMotion: reduceMotion)
    }
}
