import Foundation

/// **What this app has asked the system to deliver, one state per study day and kind** (review-module-plan
/// §5.2, WI-6).
///
/// Notification Center is not a history: it lists what is "still present", and what a reader's
/// dismissal does to that list is not documented. So this is the history, kept in the app's defaults
/// (WI-7), and the **intent → add → added** protocol keeps it ahead of the system: the intent is written
/// before the add, so no reminder exists that the log does not know about.
///
/// | State | Written when | Terminal? |
/// |---|---|---|
/// | absent / `notPlanned(.nothingAskable)` | the count at the fire time is 0 | **no** — asked again every plan |
/// | `intent` | before a first add | no — added again only while its fire time is ahead |
/// | `added` | the add succeeded | no — until it leaves the pending list |
/// | `failed` | the add failed | no — retried at the next trigger, once |
/// | `gone` | an added request left the pending list, or was delivered | **yes** — never added again |
/// | `withdrawn(.skipped)` | the reader's act | **yes** |
/// | `withdrawn(.satToday)` | by no build since WI-8; read so an older log stays closed | **yes** |
/// | `withdrawn(.disabled)` | reminders turned off | **while they are off** — see `State.isTerminal` |
///
/// Every transition returns a new log; nothing here mutates one in place.
public struct ReminderLog: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// The plan looked and a sitting at the fire time would hold nothing. The same as no entry,
        /// written down so the instrument can say why there was no reminder.
        case notPlanned(NotPlanned)
        /// About to be added for the first time — written, and persisted, before the add.
        case intent(ReminderRequest)
        /// In the system's pending list, as far as the log knows.
        case added(ReminderRequest)
        /// The add failed at `at`. Nothing reached the system.
        case failed(ReminderRequest, at: Date)
        /// It was added and has left the pending list — fired, removed, or past its time — or it was
        /// delivered. Which one cannot be told, and only one of them may be followed by another alert.
        case gone
        /// The reader took it back.
        case withdrawn(Withdrawal)

        /// **Whether no plan may ever add it again.**
        ///
        /// `gone`, a skipped day and a day the reader sat are. **`withdrawn(.disabled)` is not**, and
        /// this is a departure from the plan's table, which marks every withdrawal terminal: read
        /// literally, turning reminders off and on again would silence every day the horizon had
        /// already planned — up to seven — with no transition able to reopen them. It lasts while
        /// reminders are off, which is the only time a plan would have to honour it (an off plan plans
        /// nothing); the reconciler writes it in the same update that removes the pending request, so
        /// it never stands over a request still waiting to fire.
        public var isTerminal: Bool {
            switch self {
            case .gone, .withdrawn(.satToday), .withdrawn(.skipped): true
            case .withdrawn(.disabled), .notPlanned, .intent, .added, .failed: false
            }
        }

        /// What an add put, or was about to put, in the system.
        var request: ReminderRequest? {
            switch self {
            case .intent(let request), .added(let request), .failed(let request, _): request
            case .notPlanned, .gone, .withdrawn: nil
            }
        }
    }

    public enum NotPlanned: String, Sendable, Equatable, Codable {
        case nothingAskable
    }

    public enum Withdrawal: String, Sendable, Equatable, CaseIterable, Codable {
        /// The reader sat a sitting that left nothing askable. **Written by no build since WI-8**, and
        /// read so a log that holds it stays closed: "nothing askable now" closed days whose work came
        /// back before the reminder fired. A sitting now re-plans, and the plan's own count at the fire
        /// instant withdraws the day non-terminally, as `notPlanned(.nothingAskable)`.
        case satToday
        /// "Skip today" — **never labelled "Not today"**, which means postpone (ADR-0038).
        case skipped
        /// Reminders were turned off.
        case disabled
    }

    /// What became of an add the reconciler released.
    public enum AddOutcome: Sendable, Equatable {
        case added
        case failed(at: Date)
    }

    public let entries: [ReminderKey: State]
    /// **The instant the reader asked Later for, by study day.** An ask, like the settings' time is a
    /// choice: the plan reads it, the state machine runs beside it, and its presence is what makes Later
    /// once a day.
    public let laterAsked: [ReminderDay: Date]

    public init() {
        self.init(entries: [:], laterAsked: [:])
    }

    init(entries: [ReminderKey: State], laterAsked: [ReminderDay: Date]) {
        self.entries = entries
        self.laterAsked = laterAsked
    }

    public subscript(key: ReminderKey) -> State? { entries[key] }

    // MARK: - A log that was lost

    /// **What to plan against when the log kept was lost** — deleted, or unreadable (WI-8).
    ///
    /// Nothing is known of any day, and ignorance about one day can cost a second banner: today's.
    /// Its unrequested reminder may already have been delivered and dismissed, which leaves nothing in
    /// Notification Center to say so, and a time moved later in the day would plan it again. So today
    /// is closed, both kinds, as `gone`: **a lost log costs today's reminders and never adds one.**
    ///
    /// Every other day is open, as in an empty log. A day before today is never planned again — its
    /// fire times have passed. A day after it cannot have fired yet; its pending request, unknown to
    /// this log, is removed and added again through the intent protocol by the next pass.
    public static func lost(today: ReminderDay) -> ReminderLog {
        ReminderLog(entries: Dictionary(uniqueKeysWithValues: ReminderKind.allCases.map {
            (ReminderKey(day: today, kind: $0), State.gone)
        }), laterAsked: [:])
    }

    // MARK: - The outcome of an add

    /// **Records what became of an add.** Success records the request as added — whatever the log said,
    /// it is what the system now holds. Failure turns the intent it answers into `failed`; a failed
    /// replacement leaves the log as it was, because the request it would have replaced is still
    /// pending and still recorded, and the next trigger tries again. Nothing reopens a terminal state:
    /// a request added over one is removed by the next reconcile.
    public func recordingAdd(_ outcome: AddOutcome, of reminder: PlannedReminder) -> ReminderLog {
        let current = self[reminder.key]
        if let current, current.isTerminal { return self }
        switch outcome {
        case .added:
            return setting(.added(reminder.request), for: reminder.key)
        case .failed(let at):
            guard current == .intent(reminder.request) else { return self }
            return setting(.failed(reminder.request, at: ReviewInstant.stored(at)), for: reminder.key)
        }
    }

    // MARK: - The reader's acts

    /// **Closes both of a study day's reminders** — "Skip today" — so no plan adds either again. A day already closed for good stays as it is: a delivered reminder is
    /// still gone. The pending request, if any, is removed by the next reconcile.
    public func withdrawing(_ day: ReminderDay, _ reason: Withdrawal) -> ReminderLog {
        var entries = entries
        for kind in ReminderKind.allCases {
            let key = ReminderKey(day: day, kind: kind)
            if let current = entries[key], current.isTerminal { continue }
            entries[key] = .withdrawn(reason)
        }
        return ReminderLog(entries: entries, laterAsked: laterAsked)
    }

    /// **Later: the reader's request, from a delivered reminder of `day`** (§5.2).
    ///
    /// At most once a study day, `settings.laterDelay` after `instant` in whole seconds, and refused if
    /// that would be at or past the start of the next study day — on the calendar, so a 25-hour night is
    /// 25 hours. Asked, it records the instant, marks the original gone — it was delivered, and is
    /// being taken away — and releases the removal of the delivered original once that is written.
    /// The Later itself is planned and added by the next reconcile, like any reminder, under
    /// `review.<day>.later`.
    public func askingLater(on day: ReminderDay, at instant: Date, settings: ReminderSettings,
                            studyDay: StudyDay) -> LaterOutcome {
        let daily = ReminderKey(day: day, kind: .daily), later = ReminderKey(day: day, kind: .later)
        guard settings.isEnabled else { return .refused(.remindersOff) }
        for key in [daily, later] {
            if case .withdrawn(let reason)? = self[key], reason != .disabled { return .refused(.dayWithdrawn) }
        }
        guard laterAsked[day] == nil, self[later]?.isTerminal != true else { return .refused(.alreadyAsked) }
        // Whole seconds: the trigger has no finer grain, and a whole second since 1970 is its own stored form.
        let fireAt = Date(timeIntervalSince1970:
            ReviewInstant.encoded(instant.addingTimeInterval(settings.laterDelay)).rounded(.down))
        guard let start = day.start(in: studyDay), fireAt < studyDay.startOfNextDay(containing: start) else {
            return .refused(.crossesIntoTheNextStudyDay)
        }
        var entries = entries
        if entries[daily]?.isTerminal != true { entries[daily] = .gone }
        var asked = laterAsked
        asked[day] = fireAt
        return .asked(ReminderUpdate(original: self, log: ReminderLog(entries: entries, laterAsked: asked),
                                     actions: [.removeDelivered(id: daily.identifier)]))
    }

    // MARK: - Kept, and pruned

    /// **Fourteen study days, today included, and every day ahead** (§5.2) — the rest is dropped, asks
    /// for Later with it.
    func pruned(today: ReminderDay) -> ReminderLog {
        guard let oldest = today.adding(days: 1 - ReminderRecommendation.retainedStudyDays) else { return self }
        return ReminderLog(entries: entries.filter { $0.key.day >= oldest },
                           laterAsked: laterAsked.filter { $0.key >= oldest })
    }

    func setting(_ state: State?, for key: ReminderKey) -> ReminderLog {
        var entries = entries
        entries[key] = state
        return ReminderLog(entries: entries, laterAsked: laterAsked)
    }
}

/// What asking for Later came to.
public enum LaterOutcome: Sendable, Equatable {
    /// The new log, and the removal of the delivered original it releases once written.
    case asked(ReminderUpdate)
    case refused(LaterRefusal)
}

public enum LaterRefusal: Sendable, Equatable, CaseIterable {
    /// Reminders are off; a banner delivered before they were turned off asks for nothing.
    case remindersOff
    /// The reader skipped the day, or sat it.
    case dayWithdrawn
    /// Later was asked already this study day — at most once.
    case alreadyAsked
    /// It would land at or past the next study day's start.
    case crossesIntoTheNextStudyDay
}

// MARK: - Kept between launches

extension ReminderLog: Codable {
    private enum CodingKeys: String, CodingKey {
        case entries, later
    }

    private enum RecordKeys: String, CodingKey {
        case day, kind, state, fireAt, content, failedAt, reason
    }

    private enum StateName: String, Codable {
        case notPlanned, intent, added, failed, gone, withdrawn
    }

    private enum LaterKeys: String, CodingKey {
        case day, fireAt
    }

    /// **Reads whatever a version wrote, and fails closed.**
    ///
    /// Extra fields anywhere are ignored. A record whose day or kind cannot be read cannot be placed and
    /// is passed over. **A record whose state cannot be read in full — an unknown state or reason, a
    /// request missing its instant or its content — is `gone`**: terminal, never added again. Reading
    /// it as open could add a second banner for a day a later version had already delivered; reading it
    /// as closed costs one reminder at most. Instants are seconds since 1970, as the ledger keeps them.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var entries: [ReminderKey: State] = [:]
        let records: [KeyedDecodingContainer<RecordKeys>] = try Self.records(values, .entries)
        for record in records {
            guard let day = try? record.decode(ReminderDay.self, forKey: .day),
                  let kind = try? record.decode(ReminderKind.self, forKey: .kind)
            else { continue }
            let key = ReminderKey(day: day, kind: kind)
            let state = (try? Self.state(from: record)) ?? .gone
            // Two records for one key: a closed one wins, for the same reason as above.
            if let held = entries[key], held.isTerminal { continue }
            entries[key] = state
        }
        var asked: [ReminderDay: Date] = [:]
        let asks: [KeyedDecodingContainer<LaterKeys>] = try Self.records(values, .later)
        for record in asks {
            guard let day = try? record.decode(ReminderDay.self, forKey: .day),
                  let seconds = try? record.decode(Double.self, forKey: .fireAt)
            else { continue }
            asked[day] = ReviewInstant.decoded(seconds)
        }
        self.init(entries: entries, laterAsked: asked)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        var list = values.nestedUnkeyedContainer(forKey: .entries)
        for (key, state) in entries.sorted(by: { $0.key < $1.key }) {
            var record = list.nestedContainer(keyedBy: RecordKeys.self)
            try record.encode(key.day, forKey: .day)
            try record.encode(key.kind, forKey: .kind)
            try Self.encode(state, into: &record)
        }
        var later = values.nestedUnkeyedContainer(forKey: .later)
        for (day, fireAt) in laterAsked.sorted(by: { $0.key < $1.key }) {
            var record = later.nestedContainer(keyedBy: LaterKeys.self)
            try record.encode(day, forKey: .day)
            try record.encode(ReviewInstant.encoded(fireAt), forKey: .fireAt)
        }
    }

    /// Every element of a list that is an object, each as a keyed container; anything else is passed
    /// over. An absent list is empty.
    ///
    /// **A list that is there and is not a list throws** — `true`, `null`, an object. Read as empty it
    /// was a valid log that had never added today, so the store did not treat it as lost and a later
    /// time added a second banner (audit-fix round 1). Thrown, the store reads the log unreadable and
    /// plans `lost(today:)`, which is the protection a damaged log is owed.
    private static func records<Keys: CodingKey>(_ values: KeyedDecodingContainer<CodingKeys>,
                                                 _ key: CodingKeys) throws -> [KeyedDecodingContainer<Keys>] {
        guard values.contains(key) else { return [] }
        var list = try values.nestedUnkeyedContainer(forKey: key)
        var records: [KeyedDecodingContainer<Keys>] = []
        while !list.isAtEnd {
            if let record = try? list.nestedContainer(keyedBy: Keys.self) {
                records.append(record)
            } else if (try? list.decode(Skipped.self)) == nil {
                // Nothing advanced past the element: stop rather than loop. What was read stands.
                break
            }
        }
        return records
    }

    /// Decodes from anything, reading nothing: how a list steps past an element it cannot use.
    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    private static func state(from record: KeyedDecodingContainer<RecordKeys>) throws -> State {
        func request() throws -> ReminderRequest {
            ReminderRequest(fireAt: ReviewInstant.decoded(try record.decode(Double.self, forKey: .fireAt)),
                            content: try record.decode(ReminderContent.self, forKey: .content))
        }
        switch try record.decode(StateName.self, forKey: .state) {
        case .notPlanned: return .notPlanned(try record.decode(NotPlanned.self, forKey: .reason))
        case .intent: return .intent(try request())
        case .added: return .added(try request())
        case .failed:
            return .failed(try request(), at: ReviewInstant.decoded(try record.decode(Double.self, forKey: .failedAt)))
        case .gone: return .gone
        case .withdrawn: return .withdrawn(try record.decode(Withdrawal.self, forKey: .reason))
        }
    }

    private static func encode(_ state: State, into record: inout KeyedEncodingContainer<RecordKeys>) throws {
        func encode(_ request: ReminderRequest) throws {
            try record.encode(ReviewInstant.encoded(request.fireAt), forKey: .fireAt)
            try record.encode(request.content, forKey: .content)
        }
        switch state {
        case .notPlanned(let reason):
            try record.encode(StateName.notPlanned, forKey: .state)
            try record.encode(reason, forKey: .reason)
        case .intent(let request):
            try record.encode(StateName.intent, forKey: .state)
            try encode(request)
        case .added(let request):
            try record.encode(StateName.added, forKey: .state)
            try encode(request)
        case .failed(let request, let at):
            try record.encode(StateName.failed, forKey: .state)
            try encode(request)
            try record.encode(ReviewInstant.encoded(at), forKey: .failedAt)
        case .gone:
            try record.encode(StateName.gone, forKey: .state)
        case .withdrawn(let reason):
            try record.encode(StateName.withdrawn, forKey: .state)
            try record.encode(reason, forKey: .reason)
        }
    }
}
