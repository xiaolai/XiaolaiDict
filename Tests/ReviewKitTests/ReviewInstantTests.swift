import Foundation
import Testing
import ReviewKit

/// **The instant a review is scheduled with is the instant that is stored** (plan §7.1, WI-9a).
///
/// `Date` keeps seconds since 2001 and the ledger keeps seconds since 1970, so storing an instant
/// adds 978,307,200 and reading it back subtracts it — and the addition drops a fractional bit for
/// 2018–2035 dates. `ReviewInstant.stored` is the instant a reader of the ledger will see. These
/// are its two properties: applying it again changes nothing, and it never changes what is stored.
struct ReviewInstantTests {
    /// SplitMix64, seeded, so a failure names an instant that can be found again.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 2001 through 2100, as seconds since the reference date.
    private static let span: Range<TimeInterval> = 0..<3_155_760_000

    @Test func storedIsIdempotentAndNeverChangesWhatIsStored() {
        var generator = Seeded(state: 20_261_004)
        var moved = 0
        for _ in 0..<100_000 {
            let instant = Date(timeIntervalSinceReferenceDate: .random(in: Self.span, using: &generator))
            let stored = ReviewInstant.stored(instant)
            #expect(ReviewInstant.stored(stored) == stored,
                    "not idempotent at \(instant.timeIntervalSinceReferenceDate)")
            #expect(ReviewInstant.encoded(stored) == ReviewInstant.encoded(instant),
                    "canonicalising changed the stored value at \(instant.timeIntervalSinceReferenceDate)")
            #expect(ReviewInstant.decoded(ReviewInstant.encoded(instant)) == stored,
                    "stored is not what the ledger reads back at \(instant.timeIntervalSinceReferenceDate)")
            if stored != instant { moved += 1 }
        }
        // **A positive control.** Idempotency is trivially true of the identity, so the samples must
        // include instants storage does move, or the loop above could not tell the two apart.
        #expect(moved > 0, "no sampled instant changes in storage, so nothing above was tested")
    }

    /// The counterexample the rule exists for: a day short in memory, a whole day once stored.
    @Test func theDayBoundaryCounterexampleLandsOnTheDay() {
        let previous = Date(timeIntervalSinceReferenceDate: 800_879_356.388_499_7)
        let inMemory = Date(timeIntervalSinceReferenceDate: 800_965_756.388_499_6)
        let day: TimeInterval = 86_400
        #expect(ReviewInstant.stored(previous) == previous, "a stored instant is its own canonical form")
        #expect(inMemory.timeIntervalSince(previous) < day)
        #expect(ReviewInstant.stored(inMemory) != inMemory)
        #expect(ReviewInstant.stored(inMemory).timeIntervalSince(previous) == day)
    }
}
