import Foundation

/// **A card's history, re-run against the real scheduler** (review-module-plan §7.2, WI-9b).
///
/// The ledger keeps every grade with the complete state either side of it, so a history can be
/// checked rather than trusted: the first live grade starts from a card never reviewed, each later
/// one starts where the one before it left the card, the scheduler reproduces what each says it did,
/// and the card holds where the last one ended. A history that passes is one a merge (stage 2) can
/// build on; one that does not is a card whose schedule nobody can account for.
///
/// **Compared in the storage domain**, as the ledger holds it: phases as their raw strings, the two
/// numbers, and every instant encoded as seconds since 1970 (`StoredSchedule`). Decoding a stored
/// value and encoding it again gives it back exactly, so nothing is lost getting there — the
/// subtraction of the reference date's offset is exact for every value from 1985 to 2106.
///
/// **The instant is a set, not a value.** One stored `reviewed_at` stands for every reference-date
/// instant whose encoding is that value, and a grade written before WI-9a was scheduled with the
/// in-memory instant the reader's clock gave — one of that set, and not always the one the ledger
/// reads back. So each grade is re-run at its preimages (`preimages(of:)`), the decoded one first:
/// that one reproducing it is exact; only another doing so is a legacy grade, named in the verdict;
/// none doing so is not a genuine grade, because a genuine instant is always in the set.
///
/// **Pure**: plain values in, a verdict out — no ledger, no storage, no text. The caller supplies a
/// card's events in the order the ledger keeps them, `(reviewed_at, rowid)`, which is the order they
/// were written: at one instant Good-then-Again and Again-then-Good are different cards.
public enum Replay {
    /// What re-running one card's history found.
    public enum Verdict: Sendable, Equatable {
        /// Every live grade reproduces at the instant the ledger reads back, the chain is unbroken,
        /// every practice attempt moved nothing, and the card holds where the history ends.
        case consistent
        /// As `consistent`, except that these grades reproduce only at another instant their
        /// stored value stands for: they were scheduled with the reader's in-memory instant, before
        /// WI-9a. That one of those instants was the reader's is checked; which one is unknowable.
        case consistentAtLegacyPrecision(events: [UUID])
        /// The history does not account for the card. `event` is where it stops making sense — nil
        /// only for a card that holds a schedule with no live grade behind it at all.
        case inconsistent(event: UUID?, reason: Inconsistency)
        /// This build cannot re-run the history. **Never consistent**: nothing was shown to be
        /// wrong, and nothing was shown to be right.
        case unreplayable(Obstacle)
    }

    public enum Inconsistency: Sendable, Equatable, CaseIterable {
        /// A live grade does not start where the one before it left the card — or, the first one,
        /// from a card never reviewed. Two live first grades of one card are this.
        case startsElsewhere
        /// No instant the stored `reviewed_at` stands for makes the scheduler produce what the grade
        /// says it did.
        case notReproduced
        /// A practice attempt whose `before` and `after` differ. Practice is inert, and that is the
        /// one thing asked of it: it is outside the chain.
        case practiceMoved
        /// The card does not hold the state the last live grade left — or, with none, is not new.
        case cardIsElsewhere
        /// An event of another card, handed to this card's replay.
        case anotherCardsEvent
    }

    public enum Obstacle: Sendable, Equatable {
        /// A scheduler version this build does not carry, on the card or on a live grade. Replaying
        /// it with today's rules would answer, and wrongly.
        case unknownSchedulerVersion(String)
        /// A grade the decoded instant does not reproduce, whose stored instant stands for more
        /// instants than the search enumerates — only instants before 2^17 s after 2001-01-01, or a
        /// value outside 1985–2106.
        case instantBeyondTheSearch(event: UUID)
    }

    /// What re-running one graded event found.
    enum Transition: Sendable, Equatable {
        /// The decoded instant reproduces it: scheduled with the instant the ledger reads back.
        case exact
        /// Only another preimage of its stored instant reproduces it.
        case atLegacyPrecision
        /// No preimage does: at each, the scheduler computes something else or refuses.
        case notReproduced
        /// The decoded instant does not reproduce it, and the stored instant stands for more instants
        /// than the search enumerates.
        case beyondTheSearch
    }

    /// The instants one stored value stands for.
    enum Preimages: Sendable, Equatable {
        /// All of them, the decoded instant first, then outward from it.
        case found([Date])
        /// More than `preimageLimit`, or a value whose decoded instant is not one of them.
        case beyondTheSearch
    }

    /// **How many preimages the search enumerates before it gives up.** The set has 1–3 members for
    /// 2018–2035 and 3–5 for 2009–2017, but grows without bound towards 2001-01-01, where the
    /// reference date's resolution is finest: 8,193 at 2001-01-02 and over a million at its first
    /// second.
    ///
    /// **6,145 makes the set complete for every stored value whose decoded instant is 2^17 s after the
    /// reference date (2001-01-02T12:24:32Z) or later** — so for every instant from 2^17 s less half the
    /// stored value's step on. Every such set has at most 4,097 members but one: the stored value of
    /// 2^17 s itself, which sits where the instants' step halves and stands for 4,096 instants below
    /// it, 2,048 above and itself (WI-8; a limit of 4,097 refused the very instant the claim started
    /// from). It costs at most that many scheduler runs, and only for a grade the decoded instant does
    /// not reproduce: an exact grade needs no search at all (`transition(of:using:)`).
    static let preimageLimit = 6_145

    /// Every reference-date instant whose encoding is `stored`, **the decoded one first**.
    ///
    /// The set is contiguous, because adding the offset is monotone, and it contains the decoded
    /// instant for every value from 1985 to 2106 (the subtraction is exact there). So the search
    /// walks outward from that instant until each side leaves the set. Where the decoded instant is
    /// not in it, the search is outside its model and says so rather than guess.
    static func preimages(of stored: Double) -> Preimages {
        // No instant a clock gives is stored as NaN or infinity.
        guard stored.isFinite else { return .found([]) }
        func standsFor(_ seconds: Double) -> Bool {
            ReviewInstant.encoded(Date(timeIntervalSinceReferenceDate: seconds)) == stored
        }
        let decoded = ReviewInstant.decoded(stored).timeIntervalSinceReferenceDate
        guard standsFor(decoded) else { return .beyondTheSearch }
        var found = [decoded]
        for step in [{ (seconds: Double) in seconds.nextDown }, { (seconds: Double) in seconds.nextUp }] {
            var candidate = step(decoded)
            while standsFor(candidate) {
                guard found.count < preimageLimit else { return .beyondTheSearch }
                found.append(candidate)
                candidate = step(candidate)
            }
        }
        return .found(found.map(Date.init(timeIntervalSinceReferenceDate:)))
    }

    /// Re-runs one graded event at the preimages of its stored instant.
    ///
    /// `event` is as the ledger reads it back; `scheduler` is the one its version and retention name.
    /// A preimage the scheduler refuses — a clock that ran backwards, an invalid state — reproduces
    /// nothing, exactly as one that computes something else.
    ///
    /// **The decoded instant is tried before the set is enumerated**, so whether a grade is exact never
    /// depends on how many other instants its stored value stands for: a grade written since WI-9a at
    /// any instant the decoding is exact for is `.exact`. Only a grade the decoded instant does not
    /// reproduce needs the search, and only that one can be beyond it.
    static func transition(of event: ReviewEvent, using scheduler: MemoryScheduler) -> Transition {
        let stored = ReviewInstant.encoded(event.reviewedAt)
        let recorded = StoredSchedule(event.after)
        func reproduces(at instant: Date) -> Bool {
            guard let replayed = try? scheduler.review(event.before, grade: event.grade, now: instant) else {
                return false
            }
            return StoredSchedule(replayed) == recorded
        }
        // No instant a clock gives is stored as NaN or infinity, so none reproduces one.
        guard stored.isFinite else { return .notReproduced }
        let decoded = ReviewInstant.decoded(stored)
        // Outside the decoding's exact range the decoded instant is not one the value stands for, and
        // reproducing there would prove nothing about the grade.
        guard ReviewInstant.encoded(decoded) == stored else { return .beyondTheSearch }
        if reproduces(at: decoded) { return .exact }
        guard case .found(let instants) = preimages(of: stored) else { return .beyondTheSearch }
        return instants.dropFirst().contains(where: reproduces(at:)) ? .atLegacyPrecision : .notReproduced
    }

    /// One card's history, re-run. `events` are the card's, in the ledger's order, voided ones
    /// included: a voided event is something the reader took back, and is no part of the chain.
    ///
    /// **The first problem in the history's order decides the verdict**, so the event named is where
    /// the history stops accounting for the card, not merely one place it does not.
    public static func verdict(of card: StudyCard, events: [ReviewEvent]) -> Verdict {
        guard card.schedulerVersion == MemoryScheduler.version else {
            return .unreplayable(.unknownSchedulerVersion(card.schedulerVersion))
        }
        var reached = StoredSchedule(ScheduledCard())
        var last: UUID?
        var legacy: [UUID] = []
        for event in events where !event.isVoid {
            guard event.cardID == card.id else {
                return .inconsistent(event: event.id, reason: .anotherCardsEvent)
            }
            switch event.kind {
            case .practice:
                // Outside the chain: it may record any state, and must record that it moved none.
                guard StoredSchedule(event.before) == StoredSchedule(event.after) else {
                    return .inconsistent(event: event.id, reason: .practiceMoved)
                }
            case .graded:
                // **The one configuration this build rebuilds is the default**, whose identity is
                // `MemoryScheduler.version`: a grade by another cap or other weights records an
                // identity of its own (`MemoryScheduler.identity`) and stops here, unreplayable,
                // rather than reaching a scheduler that would schedule it differently and call it
                // a forgery.
                guard event.schedulerVersion == MemoryScheduler.version else {
                    return .unreplayable(.unknownSchedulerVersion(event.schedulerVersion))
                }
                guard StoredSchedule(event.before) == reached else {
                    return .inconsistent(event: event.id, reason: .startsElsewhere)
                }
                // The retention the grade was scheduled for, which a scheduler built today need not
                // share. One the scheduler refuses could not have produced this grade.
                guard let scheduler = try? MemoryScheduler(retention: event.retention) else {
                    return .inconsistent(event: event.id, reason: .notReproduced)
                }
                switch transition(of: event, using: scheduler) {
                case .exact: break
                case .atLegacyPrecision: legacy.append(event.id)
                case .notReproduced: return .inconsistent(event: event.id, reason: .notReproduced)
                case .beyondTheSearch: return .unreplayable(.instantBeyondTheSearch(event: event.id))
                }
                reached = StoredSchedule(event.after)
                last = event.id
            }
        }
        guard StoredSchedule(card.scheduled) == reached else {
            return .inconsistent(event: last, reason: .cardIsElsewhere)
        }
        return legacy.isEmpty ? .consistent : .consistentAtLegacyPrecision(events: legacy)
    }
}

/// **A schedule as the ledger's columns hold it**: the phase's raw string, stability and difficulty,
/// and each instant as seconds since 1970. What a replay compares, because it is what the ledger has.
struct StoredSchedule: Equatable {
    let phase: String
    let stability: Double?
    let difficulty: Double?
    let lastReview: Double?
    let due: Double?

    init(_ scheduled: ScheduledCard) {
        phase = scheduled.phase.rawValue
        stability = scheduled.state?.stability
        difficulty = scheduled.state?.difficulty
        lastReview = scheduled.lastReview.map(ReviewInstant.encoded)
        due = scheduled.due.map(ReviewInstant.encoded)
    }
}
