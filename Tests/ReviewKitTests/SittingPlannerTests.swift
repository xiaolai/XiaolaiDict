import Foundation
@testable import ReviewKit
import Testing

/// **A Review sitting, planned from one candidate set** (review-module-plan §5.1, §8.1, WI-2).
///
/// The planner is handed every card of every askable note — readiness is the ledger's question and
/// is never asked again here — and answers three things from that one set: the ordered batch, the
/// counts the surface reports beside it, and how many cards a sitting would hold at any instant.
struct SittingPlannerTests {
    // MARK: - Fixture

    private func utc() throws -> TimeZone { try #require(TimeZone(identifier: "UTC")) }

    /// 2027-01-`day` at `hour`:`minute` UTC. Whole seconds, so each is its own stored form.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try utc()
        return try #require(calendar.date(from: DateComponents(
            year: 2027, month: 1, day: day, hour: hour, minute: minute)))
    }

    private func planner(at now: Date, batch: Int = 10, perDay: Int = 5,
                         increase: Int = 0) throws -> SittingPlanner {
        SittingPlanner(studyDay: StudyDay(timeZone: try utc(), cutoffHour: 4), now: now,
                       batchSize: batch, newCardsPerDay: perDay, increaseToday: increase)
    }

    private func card(id: UUID = UUID(), note: UUID = UUID(), _ phase: SchedulePhase = .review,
                      due: Date?, lastReview: Date? = nil, paused: Bool = false,
                      hiddenUntil: Date? = nil) -> StudyCard {
        StudyCard(id: id, noteID: note, scheduled: ScheduledCard(
                      state: phase == .new ? nil : MemoryState(stability: 10, difficulty: 5),
                      phase: phase, lastReview: lastReview, due: phase == .new ? nil : due),
                  isPaused: paused, hiddenUntil: hiddenUntil, createdAt: .distantPast)
    }

    private func newCard(note: UUID = UUID(), hiddenUntil: Date? = nil) -> StudyCard {
        card(note: note, .new, due: nil, hiddenUntil: hiddenUntil)
    }

    /// Six cards with fixed ids, so an order can be pinned. Generated once (Python's `random`,
    /// seed 20261004) and written down; nothing below derives them.
    private static let six = [
        ("A", "4D82C616-C12B-42E7-8DDC-E92C2CB31A1D"), ("B", "30D2E06E-85ED-4B46-8640-ABA06491D4CE"),
        ("C", "ABE25052-B4A7-48F0-BE46-6AE1D3EFBBAC"), ("D", "F20F7FBD-2515-4B6E-B9DB-88A92072874B"),
        ("E", "354A0946-5C06-4C5A-98D0-D92C64BE4FF0"), ("F", "F730BC5E-3FBA-49A6-9834-F2C136CFE38C"),
    ]

    /// The six, answered A to F a minute apart on the 8th, each with a ten-day interval — so due a
    /// minute apart on the 18th, in exactly the order they were last answered.
    private func answeredInOrder() throws -> (cards: [StudyCard], letters: [UUID: String]) {
        var cards: [StudyCard] = [], letters: [UUID: String] = [:]
        for (index, (letter, text)) in Self.six.enumerated() {
            let id = try #require(UUID(uuidString: text))
            let answered = try at(8, 20, index)
            cards.append(card(id: id, due: answered.addingTimeInterval(10 * 86_400), lastReview: answered))
            letters[id] = letter
        }
        return (cards, letters)
    }

    private func asked(_ plan: SittingPlan, _ letters: [UUID: String]) -> String {
        plan.batch.map { letters[$0.id] ?? "?" }.joined()
    }

    // MARK: - Order

    /// **Due is graded-at plus whole days, so the order a sitting was answered in comes back as the
    /// order the next one asks** — and that order is a cue: the reader learns that *laconic* comes
    /// after *ephemeral* and recalls the sequence instead of the word (review-module-plan §3, R6).
    /// The SQL queue asks these A to F (`due`, then `id`); the planner shuffles cards due on one
    /// study day, with a seed fixed for the sitting's study day.
    @Test func cardsDueOnOneStudyDayAreNotAskedInTheOrderTheyWereLastAnswered() throws {
        let (cards, letters) = try answeredInOrder()
        let plan = try planner(at: at(20, 10)).reviewSitting(from: SittingCandidates(cards: cards, introducedToday: 0))
        let order = asked(plan, letters)
        #expect(Set(order) == Set("ABCDEF"), "the shuffle lost or invented a card: \(order)")
        #expect(order != "ABCDEF", "asked in the order they were last answered")
        #expect(order != "FEDCBA", "asked in that order reversed, which is the same cue")
        // **Pinned**, from an independent FNV-1a 64 computation in Python over the seed's eight
        // little-endian bytes and the card's sixteen — not from the Swift that implements it.
        #expect(order == "FDEACB")
    }

    /// **Fixed for a study day, different across them.** Within one study day every sitting — and
    /// every process — asks the same order, so "another batch" does not reshuffle what the reader
    /// already saw; the next study day draws a new one. 03:59 on the 21st is still the 20th's day.
    @Test func theShuffleIsFixedForAStudyDayAndChangesWithIt() throws {
        let (cards, letters) = try answeredInOrder()
        let candidates = SittingCandidates(cards: cards, introducedToday: 0)
        for instant in [try at(20, 4), try at(20, 10), try at(21, 3, 59)] {
            #expect(asked(try planner(at: instant).reviewSitting(from: candidates), letters) == "FDEACB",
                    "a sitting at \(instant) is the 20th's study day and asked another order")
        }
        #expect(asked(try planner(at: at(21, 4)).reviewSitting(from: candidates), letters) == "FEBCDA")
        #expect(asked(try planner(at: at(22, 10)).reviewSitting(from: candidates), letters) == "DEFCBA")
    }

    /// **The key is FNV-1a 64, pinned against the specification.** `Hasher` is seeded per process,
    /// so an order built on it would differ every launch and could not be reproduced by anyone.
    @Test func theShuffleKeyIsFNV1aOverTheSeedAndTheCard() throws {
        let card = try #require(UUID(uuidString: Self.six[0].1))
        #expect(SittingPlanner.seed(forDayStarting: try at(20, 4)) == 1_800_417_600)
        #expect(SittingPlanner.shuffleKey(seed: 1_800_417_600, card: card) == 9_376_196_469_172_987_563)
        #expect(SittingPlanner.shuffleKey(seed: 0, card: card) == 12_771_591_119_714_985_201)
        // A study day before 1970 has a negative start; its seed is that number's bit pattern.
        let early = SittingPlanner.seed(forDayStarting: Date(timeIntervalSince1970: -86_400))
        #expect(early == UInt64(bitPattern: -86_400))
        #expect(SittingPlanner.shuffleKey(seed: early, card: card) == 9_423_069_882_135_563_380)
        // **An instant no whole-second count holds still seeds**, as the Double's own bit pattern —
        // a planner can be handed any `Date`, and ReviewKit may not trap on its input (audit-fix
        // round 1, the class of MemoryScheduler's interval). Distinct, so two such days still differ.
        let far = [1e30, -1e30, .infinity, .nan].map { SittingPlanner.seed(at: Date(timeIntervalSince1970: $0)) }
        #expect(far[0] == (1e30).bitPattern && far[1] == (-1e30).bitPattern)
        #expect(Set(far).count == far.count)
    }

    /// **Nothing per-process reaches the order**, read from the source with comments removed. The
    /// pinned values above already fail under a seeded `Hasher`; this names the class of mistake
    /// before it is made, and its control proves it can see one.
    @Test func theShuffleReadsNoPerProcessRandomness() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ReviewKit/SittingPlanner.swift"), encoding: .utf8)
        #expect(Self.perProcessRandomness(in: source).isEmpty,
                "the planner names \(Self.perProcessRandomness(in: source))")
        // Positive controls: each spelling is seen in code, and none is seen in a comment.
        #expect(Self.perProcessRandomness(in: "var h = Hasher()") == ["Hasher"])
        #expect(Self.perProcessRandomness(in: "cards.shuffled()") == [".shuffled("])
        #expect(Self.perProcessRandomness(in: "x.hashValue") == ["hashValue"])
        #expect(Self.perProcessRandomness(in: "/// never Hasher").isEmpty)
    }

    private static func perProcessRandomness(in source: String) -> [String] {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.range(of: "//").map { String(line[line.startIndex..<$0.lowerBound]) } ?? String(line)
        }.joined(separator: "\n")
        return ["Hasher", "hashValue", "hash(into", ".shuffled(", ".shuffle(", "random",
                "RandomNumberGenerator"].filter { code.contains($0) }
    }

    /// **Phase first, then the study day of `due`, then the shuffle** — the SQL queue's order with
    /// only its tie among one study day's cards replaced. Learning and relearning are one rank, as
    /// they are in SQL; an older day comes before a newer one; new cards last.
    @Test func phaseThenTheStudyDayOfDueThenTheShuffle() throws {
        let relearning = card(.relearning, due: try at(19, 9))
        let learningLate = card(.learning, due: try at(20, 9, 30))
        let learningEarly = card(.learning, due: try at(20, 9))
        let reviewOld = card(due: try at(15, 12))
        let reviewA = card(due: try at(18, 10))
        let reviewB = card(due: try at(18, 9))
        let fresh = [newCard(), newCard()]
        let all = [fresh[0], reviewA, learningLate, relearning, reviewOld, fresh[1], reviewB, learningEarly]
        let plan = try planner(at: at(20, 10), perDay: .max)
            .reviewSitting(from: SittingCandidates(cards: all, introducedToday: 0))
        let ids = plan.batch.map(\.id)
        #expect(ids.count == all.count)
        #expect(ids.first == relearning.id, "the 19th's relearning card is before the 20th's learning ones")
        #expect(Set(ids[1...2]) == [learningLate.id, learningEarly.id])
        #expect(ids[3] == reviewOld.id, "the oldest study day of review comes first")
        #expect(Set(ids[4...5]) == [reviewA.id, reviewB.id])
        #expect(Set(ids[6...7]) == Set(fresh.map(\.id)), "new cards last")
    }

    /// **One card per note (R08), and the order picks it.** A learning card beats its review
    /// sibling, an older study day beats a newer one, and a review card beats a new sibling. The
    /// sibling left out is still due, so the counts still hold it: the next batch can ask it.
    @Test func oneCardPerNoteAndTheOrderChoosesWhich() throws {
        let first = UUID(), second = UUID(), third = UUID()
        let learning = card(note: first, .learning, due: try at(20, 9))
        let behindIt = card(note: first, due: try at(17, 9))
        let older = card(note: second, due: try at(15, 9))
        let newer = card(note: second, due: try at(18, 9))
        let reviewed = card(note: third, due: try at(19, 9))
        let unseen = newCard(note: third)
        let plan = try planner(at: at(20, 10)).reviewSitting(from: SittingCandidates(
            cards: [behindIt, newer, unseen, learning, older, reviewed], introducedToday: 0))
        #expect(plan.batch.map(\.id) == [learning.id, older.id, reviewed.id])
        #expect(plan.counts == QueueCounts(due: 6, heldBack: 0), "\(plan.counts)")
    }

    // MARK: - Rationing and counts

    /// **The allowance holds whatever the shuffle does** (ADR-0037). Forty study days are forty
    /// seeds, so forty orders; under each, at most the allowance's worth of new cards is asked, all
    /// of them behind the due work, and the rest are held back rather than lost.
    @Test func newCardsStayRationedUnderEveryOrder() throws {
        let reviews = try (0..<3).map { card(due: try at(10, 9 + $0)) }
        let fresh = (0..<12).map { _ in newCard() }
        let candidates = { (introduced: Int) in
            SittingCandidates(cards: fresh + reviews, introducedToday: introduced)
        }
        var chosen = Set<Set<UUID>>()
        for offset in 0..<40 {
            let now = try at(20, 10).addingTimeInterval(TimeInterval(offset) * 86_400)
            for (perDay, increase, introduced) in [(0, 0, 0), (1, 0, 0), (4, 0, 2), (4, 3, 2), (20, 0, 0),
                                                   (.max, 0, 0), (.max, 5, 3), (2, 0, 9)] {
                let plan = try planner(at: now, perDay: perDay, increase: increase)
                    .reviewSitting(from: candidates(introduced))
                let total = perDay > Int.max - increase ? Int.max : perDay + increase
                let left = max(0, total - introduced)
                let asked = plan.batch.filter { $0.scheduled.phase == .new }
                #expect(asked.count == min(left, fresh.count, 10 - reviews.count),
                        "day +\(offset), allowance \(perDay)+\(increase)−\(introduced): \(asked.count) new asked")
                #expect(Array(plan.batch.prefix(reviews.count)).allSatisfy { $0.scheduled.phase == .review },
                        "a new card was asked before due work")
                #expect(plan.counts == QueueCounts(due: reviews.count + min(left, fresh.count),
                                                   heldBack: fresh.count - min(left, fresh.count)))
                if perDay == 4, increase == 0 { chosen.insert(Set(asked.map(\.id))) }
            }
        }
        // **The orders really differed**, or forty days tested one order forty times.
        #expect(chosen.count > 1, "every study day introduced the same two cards")
    }

    /// **The counts and the batch come from one candidate set, judged at one instant.** The batch
    /// is a subset of what is counted as due; the difference is what did not fit; and the cards at
    /// the boundary — due exactly now, hidden until exactly now — are in both or in neither. The
    /// instant is one storage moves by an ulp, so a count taken at the in-memory instant would
    /// disagree with a batch taken at the stored one.
    @Test func countsAndTheBatchComeFromOneCandidateSet() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_965_756.388_499_6)
        let stored = ReviewInstant.stored(now)
        try #require(stored != now, "the fixture's instant is one storage does not move")
        let past = now.addingTimeInterval(-3 * 86_400)
        var cards = (0..<12).map { _ in card(due: past) }
        let sibling = UUID()
        cards += [card(note: sibling, due: past), card(note: sibling, .learning, due: past)]
        let dueNow = card(due: stored), unhiddenNow = card(due: past, hiddenUntil: stored)
        cards += [dueNow, unhiddenNow]
        cards += [card(due: past, paused: true), card(due: past, hiddenUntil: stored.addingTimeInterval(1)),
                  card(due: stored.addingTimeInterval(1))]
        cards += (0..<8).map { _ in newCard() }
        let planner = SittingPlanner(studyDay: StudyDay(timeZone: try utc(), cutoffHour: 4), now: now,
                                     batchSize: 10, newCardsPerDay: 5)
        let candidates = SittingCandidates(cards: cards, introducedToday: 1)
        let plan = planner.reviewSitting(from: candidates)

        // 12 + 2 siblings + the two at the boundary are due; 4 of the 8 new are allowed.
        #expect(plan.counts == QueueCounts(due: 16 + 4, heldBack: 4), "\(plan.counts)")
        #expect(plan.batch.count == 10)
        #expect(plan.batch.allSatisfy { $0.isDue(at: stored) }, "the batch holds a card the count left out")
        #expect(Set(plan.batch.map(\.noteID)).count == plan.batch.count, "two cards of one note")
        #expect(plan.counts.due - plan.batch.count == 10, "what did not fit is still due")
        // The boundary is judged once, at the stored instant, for both halves.
        let roomy = SittingPlanner(studyDay: planner.studyDay, now: now, batchSize: 100, newCardsPerDay: 5)
        let everything = roomy.reviewSitting(from: candidates).batch.map(\.id)
        #expect(everything.contains(dueNow.id) && everything.contains(unhiddenNow.id),
                "a card due or hidden until exactly now was left out")
        #expect(everything.count == 15 + 4, "one per note: 12, the sibling pair once, the boundary two, four new")
        #expect(planner.askableCount(at: now, in: candidates) == plan.batch.count)
    }

    // MARK: - The predicted count

    /// **What a sitting would hold at an instant other than now** (§5.1): the reminder asks it for
    /// a fire time hours or days away. Due at that instant, not hidden or paused at it, one card per
    /// note, new cards within *that* study day's allowance, and no more than a batch.
    @Test func askableCountIsEvaluatedAtTheInstant() throws {
        let tonight = card(due: try at(20, 20))
        let putOff = card(due: try at(19, 9), hiddenUntil: try at(20, 22))
        let paused = card(due: try at(19, 9), paused: true)
        let pair = UUID()
        let siblings = [card(note: pair, due: try at(18, 9)), card(note: pair, due: try at(19, 9))]
        let fresh = (0..<7).map { _ in newCard() }
        // Today's allowance: five, two more for today only, three already introduced → four left.
        let candidates = SittingCandidates(cards: [tonight, putOff, paused] + siblings + fresh,
                                           introducedToday: 3)
        let today = try planner(at: at(20, 8), perDay: 5, increase: 2)

        #expect(today.askableCount(at: try at(20, 9), in: candidates) == 1 + 4,
                "at 09:00: the pair once, four new; not tonight's card, not the one put off")
        #expect(today.askableCount(at: try at(20, 21), in: candidates) == 2 + 4, "21:00: tonight's is due")
        #expect(today.askableCount(at: try at(20, 22), in: candidates) == 3 + 4,
                "22:00: hidden until then is not hidden then")
        #expect(today.askableCount(at: try at(21, 1), in: candidates) == 3 + 4,
                "01:00 is still today's study day, so still today's allowance")
        #expect(today.askableCount(at: try at(21, 9), in: candidates) == 3 + 5,
                "tomorrow: the base allowance, nothing introduced yet, no increase")
        #expect(try planner(at: at(20, 8), perDay: 5).askableCount(at: try at(20, 9), in: candidates) == 1 + 2,
                "without the increase, today has two left")
        #expect(try planner(at: at(20, 8), batch: 6, perDay: 5, increase: 2)
            .askableCount(at: try at(21, 9), in: candidates) == 6, "capped at the batch")
        // The paused card is never counted: nothing but a write resumes it, and a write re-plans.
        #expect(try planner(at: at(20, 8), perDay: 0).askableCount(at: try at(30, 9), in: candidates) == 3)
    }

    /// **The count at the sitting's own instant is the batch it draws**, over two hundred random
    /// candidate sets — phases, due days, hidden, paused, siblings, allowances and batch sizes — and
    /// neither depends on the order the candidates arrive in.
    @Test func askableCountAtTheSittingsInstantIsTheBatchItDraws() throws {
        var generator = Seeded(state: 20_261_004)
        let now = try at(20, 10)
        let phases = SchedulePhase.allCases
        for round in 0..<200 {
            let notes = (0..<Int.random(in: 1...6, using: &generator)).map { _ in UUID() }
            let cards = (0..<Int.random(in: 0...30, using: &generator)).map { _ -> StudyCard in
                let phase = phases[Int.random(in: 0..<phases.count, using: &generator)]
                let due = now.addingTimeInterval(TimeInterval(Int.random(in: -5...2, using: &generator)) * 43_200)
                let hidden: Date? = Bool.random(using: &generator)
                    ? now.addingTimeInterval(TimeInterval(Int.random(in: -1...1, using: &generator)) * 3_600) : nil
                return card(note: notes[Int.random(in: 0..<notes.count, using: &generator)], phase, due: due,
                            paused: Int.random(in: 0..<8, using: &generator) == 0, hiddenUntil: hidden)
            }
            let planner = try planner(at: now, batch: Int.random(in: -1...12, using: &generator),
                                      perDay: Int.random(in: 0...4, using: &generator),
                                      increase: Int.random(in: 0...2, using: &generator))
            let candidates = SittingCandidates(cards: cards, introducedToday: Int.random(in: 0...3, using: &generator))
            let plan = planner.reviewSitting(from: candidates)
            #expect(planner.askableCount(at: now, in: candidates) == plan.batch.count, "round \(round)")
            #expect(plan.counts.due >= plan.batch.count, "round \(round): the batch outnumbers the count")
            let shuffled = SittingCandidates(cards: cards.shuffled(using: &generator),
                                             introducedToday: candidates.introducedToday)
            #expect(planner.reviewSitting(from: shuffled) == plan, "round \(round): the input order leaked")
        }
    }

    /// SplitMix64, seeded, so a failing round can be found again.
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

    // MARK: - Edges

    /// **Zero holds every new card back; `.max` admits them all and does not overflow** when the
    /// day's increase is added to it — the shape every test below the wire passes (ADR-0037).
    @Test func aZeroOrMaximalAllowanceIsHonouredWithoutOverflow() throws {
        let fresh = (0..<4).map { _ in newCard() }
        let review = card(due: try at(19, 9))
        let candidates = SittingCandidates(cards: fresh + [review], introducedToday: 2)
        let none = try planner(at: at(20, 10), perDay: 0).reviewSitting(from: candidates)
        #expect(none.batch.map(\.id) == [review.id])
        #expect(none.counts == QueueCounts(due: 1, heldBack: 4))
        let all = try planner(at: at(20, 10), perDay: .max, increase: 7).reviewSitting(from: candidates)
        #expect(all.batch.count == 5)
        #expect(all.counts == QueueCounts(due: 5, heldBack: 0))
        #expect(try planner(at: at(20, 10), perDay: .max, increase: 7)
            .askableCount(at: try at(25, 10), in: candidates) == 5)
        // More introduced than allowed is nothing left, never a negative allowance.
        let spent = try planner(at: at(20, 10), perDay: 1).reviewSitting(from: candidates)
        #expect(spent.counts == QueueCounts(due: 1, heldBack: 4))
    }

    /// **A batch of zero, or less, draws nothing and still counts.** `Array.prefix` traps on a
    /// negative length; the counts are about the queue, not about the sitting's size.
    @Test func anEmptyOrNegativeBatchDrawsNothingAndStillCounts() throws {
        let candidates = SittingCandidates(cards: [card(due: try at(19, 9)), newCard()], introducedToday: 0)
        for size in [0, -1, Int.min] {
            let planner = try planner(at: at(20, 10), batch: size)
            let plan = planner.reviewSitting(from: candidates)
            #expect(plan.batch.isEmpty)
            #expect(plan.counts == QueueCounts(due: 2, heldBack: 0))
            #expect(planner.askableCount(at: try at(20, 10), in: candidates) == 0)
        }
        let empty = try planner(at: at(20, 10)).reviewSitting(from: SittingCandidates(cards: [], introducedToday: 0))
        #expect(empty.batch.isEmpty && empty.counts == QueueCounts(due: 0, heldBack: 0))
    }

    /// **Judged at the stored instant**, as the SQL queue binds it and as the commit asks
    /// (`ReviewInstant`, WI-9a). A card hidden until — or due at — the instant storage moves `now`
    /// to is askable then; judged at the in-memory instant, an ulp earlier, it was not.
    @Test func thePlannerJudgesAtTheStoredInstant() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_965_756.388_499_6)
        let stored = ReviewInstant.stored(now)
        try #require(now < stored, "the fixture needs storage to move the instant later")
        let hidden = card(due: now.addingTimeInterval(-86_400), hiddenUntil: stored)
        let due = card(due: stored)
        let planner = SittingPlanner(studyDay: StudyDay(timeZone: try utc(), cutoffHour: 4), now: now,
                                     batchSize: 10, newCardsPerDay: 5)
        #expect(planner.now == stored)
        let candidates = SittingCandidates(cards: [hidden, due], introducedToday: 0)
        #expect(Set(planner.reviewSitting(from: candidates).batch.map(\.id)) == [hidden.id, due.id])
        #expect(planner.askableCount(at: now, in: candidates) == 2)
        #expect(SittingPlanner.counts(of: candidates.cards, at: now, newCardsLeft: 0).due == 2)
    }
}
