import Foundation

// The half of the study day that reads the ledger. The `StudyDay` struct went to ReviewKit
// (ADR-0047) and this stayed with the SQL; a basename of its own, because `Tools/strings.sh` refuses
// two sources that share one.
extension Ledger {
    /// How many cards were introduced in the study day that began at `since`.
    ///
    /// **A first introduction is a card's first graded review**, which is the only event that turns
    /// a `new` card into a scheduled one. Practice cannot introduce anything — it never touches a
    /// card with no memory state — and a voided introduction is not one, so undoing a first review
    /// gives the allowance back without anything having to remember to.
    public func studiedDictionaries() throws -> [String] {
        var found: [String] = []
        try run("SELECT DISTINCT dictionary FROM study_notes ORDER BY dictionary", bind: []) {
            found.append(try $0.text(0))
        }
        return found
    }

    public func introductions(since: Date, dictionary: String?) throws -> Int {
        var bind: [SQLiteValue] = [.real(since.timeIntervalSince1970)]
        var scope = ""
        if let dictionary {
            scope = "AND n.dictionary = ?2"
            bind.append(.text(dictionary))
        }
        var count = 0
        try run("""
            SELECT COUNT(*) FROM review_events e
            JOIN study_cards c ON c.id = e.card_id
            JOIN study_notes n ON n.id = c.note_id
            WHERE e.reviewed_at >= ?1
              AND e.before_phase = 'new'
              AND e.kind = 'graded'
              AND e.voided_at IS NULL
              \(scope)
            """, bind: bind) { count = $0.integer(0) }
        return count
    }
}
