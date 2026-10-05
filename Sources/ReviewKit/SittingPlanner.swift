import Foundation

/// **What a sitting is planned from: every card of every askable note, and today's introductions —
/// one read.**
///
/// Readiness is the ledger's question and is answered there, in SQL, before anything reaches this
/// type (ADR-0035: SQL may not judge what Swift defines, and the reverse holds too). What is left is
/// about an instant — due, hidden, paused — so nothing is cut by it in advance: the sitting asks it
/// about now, and the reminder about a fire time hours or days away (review-module-plan §5.1).
public struct SittingCandidates: Sendable, Equatable {
    /// Every card of a note the ledger calls askable, whether or not it is due, hidden or paused.
    public let cards: [StudyCard]
    /// First graded reviews since the start of the planner's study day — the allowance spent so far.
    public let introducedToday: Int

    public init(cards: [StudyCard], introducedToday: Int) {
        self.cards = cards
        self.introducedToday = introducedToday
    }
}

/// A Review sitting: the cards to ask, in order, and the counts the surface reports beside them.
/// **Planned together from one candidate set**, so the end of a batch cannot say "18 more due" about
/// a set the batch was not drawn from.
public struct SittingPlan: Sendable, Equatable {
    public let batch: [StudyCard]
    public let counts: QueueCounts

    public init(batch: [StudyCard], counts: QueueCounts) {
        self.batch = batch
        self.counts = counts
    }
}

/// The order a Selected sitting asks its cards in (review-module-plan §8.1).
public enum SittingOrder: Sendable, Equatable {
    /// As the reader saw them listed when they chose them.
    case asListed
    /// By a key seeded with the sitting's own instant, in whole seconds: one instant always gives one
    /// order, and two sittings over one selection a second apart give two. A listed order asked again
    /// and again becomes a cue of its own, which is the reason Review shuffles at all (R6).
    case shuffled
}

/// **What a Selected sitting is planned from: the reader's selection, beside the one read a Review
/// sitting is planned from.**
///
/// The selection's cards are found *in* `queue` — every card of every askable note in the sitting's
/// scope — so readiness is still the ledger's SQL and never a second spelling here, and the end of the
/// sitting can say how much of the queue is still due from the read the batch was drawn from.
public struct SelectedCandidates: Sendable, Equatable {
    /// The notes the reader chose, in the order they were listed, each once.
    public let selection: [UUID]
    /// `SittingCandidates`, exactly as a Review sitting reads them.
    public let queue: SittingCandidates
    /// Chosen notes saved under a study dictionary other than the sitting's. **Not a readiness
    /// verdict**: study state belongs to one dictionary, and these are counted apart because their
    /// remedy is switching the study dictionary, not anything done to the note.
    public let elsewhere: Set<UUID>

    public init(selection: [UUID], queue: SittingCandidates, elsewhere: Set<UUID> = []) {
        var seen = Set<UUID>()
        self.selection = selection.filter { seen.insert($0).inserted }
        self.queue = queue
        self.elsewhere = elsewhere
    }
}

/// One card of a Selected sitting and **the event a grade of it writes, decided when it was drawn and
/// never again** (R4): `.graded` for a card that is due — a new one within the allowance included —
/// and `.practice` for one reviewed before and not due yet. All-practice would leave due cards due;
/// all-graded would review ahead, which the scheduler has no rule for.
public struct SelectedCard: Sendable, Equatable {
    public let card: StudyCard
    public let mode: ReviewEvent.Kind

    public init(card: StudyCard, mode: ReviewEvent.Kind) {
        self.card = card
        self.mode = mode
    }
}

/// **What a Selected sitting left out of the reader's selection, by reason** — never dropped silently.
/// Each count but `siblings` is of chosen notes, so with the batch and the held-back count they account
/// for the whole selection once each.
public struct SittingExclusions: Sendable, Equatable {
    /// Notes the ledger will not ask: unconfirmed, without an answer of their own, without a reading
    /// left, archived — whatever its askable predicate refuses.
    public let notAskable: Int
    /// Notes saved under another study dictionary.
    public let otherDictionary: Int
    /// Notes whose every card is paused, or put off past the sitting's instant.
    public let pausedOrHidden: Int
    /// Cards beyond the one a sitting asks of a note it does ask (R08). **Cards, not notes.**
    public let siblings: Int

    public init(notAskable: Int = 0, otherDictionary: Int = 0, pausedOrHidden: Int = 0, siblings: Int = 0) {
        self.notAskable = notAskable
        self.otherDictionary = otherDictionary
        self.pausedOrHidden = pausedOrHidden
        self.siblings = siblings
    }

    public static let none = SittingExclusions()
}

/// A Selected sitting: its cards in order, each with its mode, and what it left out.
public struct SelectedSittingPlan: Sendable, Equatable {
    public let batch: [SelectedCard]
    /// Chosen notes whose new card today's allowance holds back. **Never practice**: a card with no
    /// memory state has nothing for practice to leave unchanged (`ReviewError.notYetReviewed`).
    public let heldBack: Int
    public let excluded: SittingExclusions
    /// The queue's due work this sitting will not grade, as the batch was drawn — what its end says is
    /// still due, so it never claims "all done" over a backlog (ADR-0032).
    public let stillDue: Int

    public init(batch: [SelectedCard], heldBack: Int, excluded: SittingExclusions, stillDue: Int) {
        self.batch = batch
        self.heldBack = heldBack
        self.excluded = excluded
        self.stillDue = stillDue
    }
}

/// **Which cards a Review sitting asks, in what order, and how many a sitting would hold at any
/// instant** (review-module-plan §5.1, §8.1, R6).
///
/// Pure: a frozen study day, an instant, a batch size and the daily allowance, over candidates the
/// ledger read once. The rules:
///
/// - **Due now** — not paused, not hidden, `due` reached — judged by `StudyCard.isDue(at:)` at the
///   **stored** instant, as the SQL queue binds it and as `grade` asks (`ReviewInstant`).
/// - **Learning and relearning, then review, then new; inside a phase the oldest study day of `due`
///   first** — the SQL queue's order (`Ledger.dueCards`) at the granularity of a study day.
/// - **Inside one study day, a shuffle seeded by the sitting's study day.** Due is graded-at plus
///   whole days, so cards answered in a row come due in a row, and asking them in that order again
///   makes the sequence a cue. The SQL queue broke this tie by card id; nothing else changes.
/// - **One card per note** (R08), the one the order puts first.
/// - **New cards within today's allowance**: the base, plus any one-day increase, less today's
///   introductions (ADR-0037). The rest are held back, counted and never lost.
public struct SittingPlanner: Sendable, Equatable {
    /// Frozen into the sitting: the day boundary must not move under a reader who travels.
    public let studyDay: StudyDay
    /// The sitting's instant, **as stored** — the instant every comparison below is made at.
    public let now: Date
    public let batchSize: Int
    /// First introductions a study day allows (ADR-0037's base).
    public let newCardsPerDay: Int
    /// Extra introductions for today only, on top of the base: the reader's one-day increase
    /// (review-module-plan WI-5, `OneDayIncrease`). Today's alone — a later day's allowance, in the
    /// predicted count and the forecast, is the base.
    public let increaseToday: Int

    public init(studyDay: StudyDay, now: Date, batchSize: Int, newCardsPerDay: Int, increaseToday: Int = 0) {
        self.studyDay = studyDay
        self.now = ReviewInstant.stored(now)
        self.batchSize = batchSize
        self.newCardsPerDay = newCardsPerDay
        self.increaseToday = increaseToday
    }

    /// The start of the sitting's study day — where today's introductions are counted from, so the
    /// caller reads them from the same boundary this plans with.
    public var today: Date { studyDay.start(containing: now) }

    // MARK: - The sitting

    /// The ordered batch and its counts, both from `candidates`, both judged at `now`.
    public func reviewSitting(from candidates: SittingCandidates) -> SittingPlan {
        let due = candidates.cards.filter { $0.isDue(at: now) }
        let left = Self.newCardsLeft(allowance: allowanceToday, introduced: candidates.introducedToday)
        let room = max(0, batchSize)
        var batch: [StudyCard] = []
        var asked = Set<UUID>()
        var introduced = 0
        for card in ordered(due) where batch.count < room {
            // **The note is spent by its first card in the order**, even when that card is a new one
            // the allowance refuses: its sibling is new too, since new cards sort last, and asking the
            // note through another card would be the same question twice (R08).
            guard asked.insert(card.noteID).inserted else { continue }
            if card.scheduled.phase == .new {
                guard introduced < left else { continue }
                introduced += 1
            }
            batch.append(card)
        }
        return SittingPlan(batch: batch, counts: Self.counted(due, newCardsLeft: left))
    }

    // MARK: - The predicted count

    /// **How many cards a sitting drawn at `instant` would hold** (review-module-plan §5.1): one per
    /// note; cards due at that instant and not paused or hidden at it; new ones within that study
    /// day's allowance — today's what is left of it, any other day's the base, since introductions
    /// are counted for today alone and a later day has none yet; and no more than a batch.
    ///
    /// Exact at `now`, where it is the size of the batch `reviewSitting(from:)` draws. Later it is a
    /// prediction over the ledger as it stands, and every write re-plans.
    public func askableCount(at instant: Date, in candidates: SittingCandidates) -> Int {
        let at = ReviewInstant.stored(instant)
        let left = studyDay.start(containing: at) == today
            ? Self.newCardsLeft(allowance: allowanceToday, introduced: candidates.introducedToday)
            : max(0, newCardsPerDay)
        var reviewing = Set<UUID>(), introducing = Set<UUID>()
        for card in candidates.cards where card.isDue(at: at) {
            if card.scheduled.phase == .new {
                introducing.insert(card.noteID)
            } else {
                reviewing.insert(card.noteID)
            }
        }
        // A note with a card in progress is asked through that card; only notes with nothing but new
        // cards due spend the allowance — as the order does it.
        let fresh = introducing.subtracting(reviewing).count
        return min(max(0, batchSize), reviewing.count + min(fresh, left))
    }

    // MARK: - A Selected sitting

    /// **A sitting over exactly the notes the reader chose** (review-module-plan §8.2, R4, WI-3b),
    /// filtered before anything is shown and counted by reason, in this order for each chosen note:
    ///
    /// - **Askable** — a note with no card in `queue` is one the ledger's predicate refused, or one
    ///   saved under another study dictionary (`elsewhere`). Readiness is never judged here.
    /// - **Not paused and not put off** at the sitting's stored instant, as the commit asks it.
    /// - **One card per note** (R08): a due card before one that is not, then the queue's own order.
    /// - **New cards within today's allowance**, taken in the sitting's order. A new card past it is
    ///   never asked and never practised; its note is held back, unless it has a card that is not new,
    ///   which is then asked instead.
    /// - **The mode, frozen here**: due — a new card included — is `.graded`; reviewed and not due is
    ///   `.practice`, which moves nothing.
    ///
    /// **No batch size.** The reader chose how many; a Selected sitting asks all of them.
    public func selectedSitting(from candidates: SelectedCandidates, order: SittingOrder) -> SelectedSittingPlan {
        let byNote = Dictionary(grouping: candidates.queue.cards, by: \.noteID)
        let left = Self.newCardsLeft(allowance: allowanceToday, introduced: candidates.queue.introducedToday)
        var batch: [SelectedCard] = []
        var introduced = 0, heldBack = 0
        var notAskable = 0, otherDictionary = 0, pausedOrHidden = 0, siblings = 0
        for note in arranged(candidates.selection, order) {
            guard let cards = byNote[note] else {
                if candidates.elsewhere.contains(note) { otherDictionary += 1 } else { notAskable += 1 }
                continue
            }
            let free = cards.filter { !$0.isPaused && !$0.isHidden(at: now) }
            guard !free.isEmpty else {
                pausedOrHidden += 1
                continue
            }
            // **A new card the allowance refuses is not asked, and is never practised** — it has no
            // memory state to leave unchanged. A reviewed card of the same note still may be: it is
            // not new, and holding the note back would say "a new meaning" of one already reviewed.
            let allowed = introduced < left ? free : free.filter { $0.scheduled.phase != .new }
            guard let card = firstToAsk(allowed) else {
                heldBack += 1
                continue
            }
            if card.scheduled.phase == .new { introduced += 1 }
            siblings += free.count - 1
            batch.append(SelectedCard(card: card, mode: card.isDue(at: now) ? .graded : .practice))
        }
        // **What of the queue this sitting leaves due**: the queue's own count, from the read the batch
        // was drawn from, less the cards it grades. Each graded card is counted there once — due now,
        // and a new one within the allowance this sitting spends from the same allowance.
        let queue = Self.counted(candidates.queue.cards.filter { $0.isDue(at: now) }, newCardsLeft: left)
        let graded = batch.count { $0.mode == .graded }
        return SelectedSittingPlan(
            batch: batch, heldBack: heldBack,
            excluded: SittingExclusions(notAskable: notAskable, otherDictionary: otherDictionary,
                                        pausedOrHidden: pausedOrHidden, siblings: siblings),
            stillDue: max(0, queue.due - graded))
    }

    /// The selection in the sitting's order. A shuffle is keyed by FNV-1a over the sitting's instant and
    /// each note, as Review's is over its study day and each card — never by a per-process random.
    private func arranged(_ selection: [UUID], _ order: SittingOrder) -> [UUID] {
        switch order {
        case .asListed:
            return selection
        case .shuffled:
            let seed = Self.seed(at: now)
            return selection.map { (note: $0, key: Self.shuffleKey(seed: seed, card: $0)) }
                .sorted { $0.key != $1.key ? $0.key < $1.key : $0.note.uuidString < $1.note.uuidString }
                .map(\.note)
        }
    }

    /// Which of a note's free cards a Selected sitting asks: **a due one before one that is not**, so a
    /// note with work waiting is reviewed rather than practised; then the queue's order — phase, due,
    /// and the card id where nothing else decides.
    private func firstToAsk(_ cards: [StudyCard]) -> StudyCard? {
        cards.min { one, other in
            let oneDue = one.isDue(at: now), otherDue = other.isDue(at: now)
            if oneDue != otherDue { return oneDue }
            let oneRank = Self.rank(of: one.scheduled.phase), otherRank = Self.rank(of: other.scheduled.phase)
            if oneRank != otherRank { return oneRank < otherRank }
            if one.scheduled.due != other.scheduled.due {
                guard let first = one.scheduled.due else { return false }
                guard let second = other.scheduled.due else { return true }
                return first < second
            }
            return one.id.uuidString < other.id.uuidString
        }
    }

    // MARK: - Counts

    /// What a surface reports about the queue at `instant`: askable now with the allowance applied,
    /// and new cards the allowance holds back. **Cards, not notes**: a note's second card is still due
    /// when the first is asked, and the next batch can have it.
    public static func counts(of cards: [StudyCard], at instant: Date, newCardsLeft: Int) -> QueueCounts {
        let at = ReviewInstant.stored(instant)
        return counted(cards.filter { $0.isDue(at: at) }, newCardsLeft: newCardsLeft)
    }

    /// **The allowance left: never negative, and `.max` is unlimited** — the shape every test below
    /// the wire passes (ADR-0037).
    public static func newCardsLeft(allowance: Int, introduced: Int) -> Int {
        max(0, allowance) - min(max(0, allowance), max(0, introduced))
    }

    private static func counted(_ due: [StudyCard], newCardsLeft: Int) -> QueueCounts {
        let fresh = due.count { $0.scheduled.phase == .new }
        let allowed = min(fresh, max(0, newCardsLeft))
        return QueueCounts(due: due.count - fresh + allowed, heldBack: fresh - allowed)
    }

    /// Today's allowance: the base and the one-day increase.
    var allowanceToday: Int {
        Self.allowance(newCardsPerDay: newCardsPerDay, increaseToday: increaseToday)
    }

    /// **A study day's allowance: the base plus that day's one-day increase**, saturating rather than
    /// trapping when either is `.max`, and never negative. Public for the callers that count the queue
    /// without planning a sitting — the Library's badge, the instrument — so the allowance they count
    /// against is this one, spelled once.
    public static func allowance(newCardsPerDay: Int, increaseToday: Int) -> Int {
        let (sum, overflowed) = max(0, newCardsPerDay).addingReportingOverflow(max(0, increaseToday))
        return overflowed ? .max : sum
    }

    // MARK: - Order

    private func ordered(_ cards: [StudyCard]) -> [StudyCard] {
        let seed = Self.seed(forDayStarting: today)
        // Keys computed once per card, not once per comparison: the study day of `due` is calendar
        // arithmetic, and a comparator would repeat it n log n times.
        let keyed = cards.map { card in
            (card: card, phase: Self.rank(of: card.scheduled.phase),
             day: card.scheduled.due.map(studyDay.start(containing:)),
             shuffle: Self.shuffleKey(seed: seed, card: card.id), id: card.id.uuidString)
        }
        return keyed.sorted { one, other in
            if one.phase != other.phase { return one.phase < other.phase }
            if one.day != other.day {
                // **No due last**, as SQL's `due IS NULL` sorts it: within a phase it is a card
                // nothing has scheduled.
                guard let first = one.day else { return false }
                guard let second = other.day else { return true }
                return first < second
            }
            if one.shuffle != other.shuffle { return one.shuffle < other.shuffle }
            return one.id < other.id
        }.map { $0.card }
    }

    /// The SQL queue's phase rank: learning and relearning together, then review, then new.
    private static func rank(of phase: SchedulePhase) -> Int {
        switch phase {
        case .learning, .relearning: 0
        case .review: 1
        case .new: 2
        }
    }

    /// **The seed is the study day itself**: its start, in whole seconds since 1970. Every sitting on
    /// one study day, in any process, gets the same order, and the next study day another one.
    static func seed(forDayStarting start: Date) -> UInt64 {
        seed(at: start)
    }

    /// An instant in whole seconds since 1970, as a seed. A Selected sitting seeds its shuffle with
    /// its own instant rather than its study day's start, so asking for a shuffle twice is two orders.
    ///
    /// An instant no `Int64` of seconds holds — a planner can be handed any `Date` — seeds with its
    /// `Double`'s bit pattern instead of trapping; every instant a clock gives is unchanged.
    static func seed(at instant: Date) -> UInt64 {
        let seconds = instant.timeIntervalSince1970.rounded(.down)
        guard let whole = Int64(exactly: seconds) else { return seconds.bitPattern }
        return UInt64(bitPattern: whole)
    }

    /// **FNV-1a 64 over the seed's eight little-endian bytes and then the card's sixteen.**
    ///
    /// Never `Hasher`: it is seeded per process, so the order would change at every launch and no
    /// one could reproduce a sitting. The seed goes first so a different day perturbs every byte
    /// that follows; measured over 30 cards and 60 consecutive days, the orders of neighbouring days
    /// correlate at a Kendall τ of 0.01 on average.
    static func shuffleKey(seed: UInt64, card: UUID) -> UInt64 {
        var hash = fnvOffsetBasis
        withUnsafeBytes(of: seed.littleEndian) { bytes in
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* fnvPrime }
        }
        withUnsafeBytes(of: card.uuid) { bytes in
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* fnvPrime }
        }
        return hash
    }

    private static let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvPrime: UInt64 = 0x100_0000_01b3
}
