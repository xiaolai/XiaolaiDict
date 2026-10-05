import Foundation
import ReviewKit

/// **The ledger's own history, replayed** (review-module-plan §7.2, WI-9b). `Replay` is the
/// arithmetic; this is the read that feeds it, and `integrity()` is where its verdicts are reported.
///
/// **Not on the lookup path, and never to be put on it.** It reads every card and every event and
/// re-runs the scheduler over them — the cost of a recovery check, not of a lookup — and a broken
/// study system must still look words up (ADR-0034).
extension Ledger {
    /// Every card's verdict, keyed by card.
    ///
    /// **Read through the one decoder each table has**, so a row the schema cannot read throws
    /// `corruptRow` here exactly as it does everywhere else, rather than reaching the replay as a
    /// history one grade shorter. Events come in the order `reviews(ofCard:)` reads them,
    /// `(reviewed_at, rowid)`: the order they were written, and the reverse of the one undo walks.
    public func replayVerdicts() throws -> [UUID: Replay.Verdict] {
        var cards: [StudyCard] = []
        try run("SELECT \(Self.cardColumns("")) FROM study_cards", bind: []) { cards.append(try Self.card(from: $0)) }
        var history: [UUID: [ReviewEvent]] = [:]
        for event in try events(where: "ORDER BY card_id, reviewed_at, rowid", bind: []) {
            history[event.cardID, default: []].append(event)
        }
        // An event whose card is gone has no history to belong to; `integrity()` counts those as
        // orphaned review events, which is the check that owns them.
        var verdicts: [UUID: Replay.Verdict] = [:]
        for card in cards {
            verdicts[card.id] = Replay.verdict(of: card, events: history[card.id] ?? [])
        }
        return verdicts
    }

    /// The replay's verdicts as `integrity()` reports them: one line for each card the history does
    /// not account for, in card order. **A legacy grade is not a problem** — it reproduces, at an
    /// instant its stored value stands for — and is named by `replayVerdicts()` instead.
    func replayProblems() throws -> [String] {
        try replayVerdicts()
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .compactMap { card, verdict in
                switch verdict {
                case .consistent, .consistentAtLegacyPrecision:
                    return nil
                case .inconsistent(let event, let reason):
                    return "replay: card \(card.uuidString) inconsistent at "
                        + "\(event.map { "event \($0.uuidString)" } ?? "the card"): \(reason)"
                case .unreplayable(let obstacle):
                    return "replay: card \(card.uuidString) unreplayable: \(obstacle)"
                }
            }
    }
}
