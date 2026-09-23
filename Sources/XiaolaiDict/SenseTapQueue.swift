import XiaolaiDictCore

/// Which lookup a sense the reader tapped belongs to.
///
/// **The entry is interactive before its row exists.** The panel draws the entry as soon as the
/// dictionaries answer, and the lookup's ledger row is written only once the selector has decided —
/// seconds later, on the local model's rung. A tap in between belongs to a lookup the ledger has
/// never heard of, and hanging it off whatever was recorded last files a study item under the
/// previous word, silently.
///
/// So a tap carries the request that made the panel, and is held until *that* request's row lands.
/// The same rule the other way: a superseded lookup is still recorded — its entry was on screen —
/// and its row must not become what the next tap attaches to.
///
/// A value rather than three properties on the app delegate, because the ordering is the whole
/// point and cannot be seen from outside one.
struct SenseTapQueue {
    /// The newest recorded lookup: its request, and the row it became.
    private(set) var lastLookup: (request: Int, id: Int)?
    private var waiting: [(request: Int, encounter: SenseEncounter)] = []

    /// How many taps may wait. A reader can only tap what is on screen, so this is generous; the cap
    /// is there so a lookup that is never recorded cannot grow the list for ever.
    static let mostHeld = 32

    /// The row to write this tap to, or nil where there is none yet and it has been kept.
    mutating func tapped(_ encounter: SenseEncounter, request: Int) -> Int? {
        if let lastLookup, lastLookup.request == request { return lastLookup.id }
        waiting.append((request, encounter))
        if waiting.count > Self.mostHeld { waiting.removeFirst() }
        return nil
    }

    /// A lookup's row has landed. Answers with what was waiting for it, in the order it was tapped.
    mutating func recorded(request: Int, id: Int) -> [SenseEncounter] {
        // Newer only: a row that lands late must not become what the next tap attaches to.
        if lastLookup.map({ request >= $0.request }) ?? true { lastLookup = (request, id) }
        let mine = waiting.filter { $0.request == request }
        waiting.removeAll { $0.request == request }
        return mine.map(\.encounter)
    }

    /// What is still waiting, for tests and for reasoning about the cap.
    var heldCount: Int { waiting.count }
}
