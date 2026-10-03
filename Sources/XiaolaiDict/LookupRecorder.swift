import Foundation
import Observation
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI
import os

/// Request-keyed durable reading, enrichment and ordered reader intent.
@Observable @MainActor
final class LookupRecorder {
    @ObservationIgnored private var opening: Task<LedgerStore, any Error>?
    @ObservationIgnored private var opener: (@Sendable () async throws -> LedgerStore)?
    @ObservationIgnored private var writeVersions: [Int: Int] = [:]
    @ObservationIgnored private var writes: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var ids: [Int: Int] = [:]
    @ObservationIgnored private var recordings: [Int: LookupRecording] = [:]
    @ObservationIgnored private var discarded: Set<Int> = []
    @ObservationIgnored private var discardOperations: [Int: UUID] = [:]
    @ObservationIgnored private var taps = SenseTapQueue()
    @ObservationIgnored private var readerChoices: [Int: Set<String>] = [:]
    private struct SenseIntent: Equatable {
        let encounter: SenseEncounter
        let enrolling: Bool
        let language: String?
        let source: StudyKeepSource
    }
    /// `refresh`: reading the status failed, and Retry reads it again — replaying the recording
    /// instead could reapply an automatic choice the reader has since changed.
    private enum RetryIntent { case recording(LookupRecording), sense(SenseIntent), undo, refresh }
    @ObservationIgnored private var failedIntents: [Int: RetryIntent] = [:]
    @ObservationIgnored private var senseIntents: [Int: SenseIntent] = [:]
    /// Held taps a write failed on — that one and every tap after it, in order. **Each tap is its own
    /// intent**: the catch below kept only the latest, so one failed write lost every tap behind it.
    @ObservationIgnored private var unwrittenTaps: [Int: [SenseIntent]] = [:]
    /// How many status refreshes each request has started — the newest is the one that applies.
    @ObservationIgnored private var refreshes: [Int: Int] = [:]
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "lookup-keeping")
    private var newest = 0
    static let retainedRequests = 64
    private(set) var problem: String?
    private(set) var states: [Int: LookupKeepStatus] = [:]
    var isOpen: Bool { opening != nil }
    var store: Task<LedgerStore, any Error>? { opening }
    var heldTaps: Int { taps.heldCount }

    func start(open: @escaping @Sendable () async throws -> LedgerStore = { try await LedgerStore.openDefault() }) {
        opener = open
        let task = Task { try await open() }; opening = task
        Task { [weak self] in
            do { _ = try await task.value }
            catch { guard let self, newest == 0 else { return }; problem = String(localized: "Readings are not being recorded: \(String(describing: error))") }
        }
    }
    /// Scheduling is synchronous; the lookup display never waits for SQLite.
    func begin(_ recording: LookupRecording, request: Int) {
        recordings[request] = recording
        if let existing = recording.lookupID { ids[request] = existing }
        newest = max(newest, request)
        if states[request] == nil { states[request] = .keeping }
        schedule(request: request) { [weak self] in await self?.persist(recording, request: request) }
    }
    private func schedule(request: Int, work: @escaping @MainActor () async -> Void) {
        let prior = writes[request]
        let version = (writeVersions[request] ?? 0) + 1
        writeVersions[request] = version
        writes[request] = Task { [weak self] in
            await prior?.value
            await work()
            if self?.writeVersions[request] == version { self?.writes[request] = nil; self?.prune() }
        }
    }
    func record(_ recording: LookupRecording, request: Int) async {
        begin(recording, request: request)
        await writes[request]?.value
    }
    /// The ledger, or the reason it could not be opened. **A failed opening is not kept**: a `Task`
    /// remembers its error for ever, so awaiting the same one again turned a transient failure — a
    /// locked file, a disk since cleared — into one that Retry could never get past.
    private func ledger(from task: Task<LedgerStore, any Error>) async throws -> LedgerStore {
        do { return try await task.value } catch {
            if opening == task, let opener { opening = Task { try await opener() } }
            throw error
        }
    }
    /// One recording into the ledger: its row, then what the reader's disposition allows, then the
    /// failures this write settled. **Orchestration only** — each step is its own function, in the
    /// order they must happen (audit round 3, #26).
    private func persist(_ recording: LookupRecording, request: Int) async {
        guard let opening else { return }
        do {
            let ledger = try await ledger(from: opening)
            let id = try await row(for: recording, request: request, in: ledger)
            if discarded.contains(request) {
                let operation = discardOperations[request] ?? UUID()
                discardOperations[request] = operation
                _ = try await ledger.changeDisposition(.discarded, lookups: [id], operation: operation)
                states[request] = .discarded
            } else if try await ledger.disposition(ofLookup: id) == .discarded {
                states[request] = .discardedExternally
            } else {
                try await recordEncounter(of: recording, lookup: id, request: request, in: ledger)
                try await drainHeldTaps(lookup: id, request: request)
            }
            log.info("request \(request) lookup \(id) policy \(recording.keepPolicy.rawValue, privacy: .public) committed")
            settleFailures(after: request)
            if request >= newest { problem = nil }
            LedgerChanges.shared.committed()
        } catch {
            log.error("request \(request) persistence failed")
            failedIntents[request] = senseIntents[request].map(RetryIntent.sense) ?? .recording(recording)
            states[request] = .failed
            if request >= newest { problem = String(localized: "The last reading was not recorded: \(String(describing: error))") }
        }
    }

    /// The lookup's row id — written now, or the one it already has.
    ///
    /// **A pending row never overwrites an answered one.** It exists so a new lookup has an id before
    /// the dictionaries reply; a reopened reading already has its answer, and one superseded before
    /// the reply would otherwise stay pending for good.
    private func row(for recording: LookupRecording, request: Int, in ledger: LedgerStore) async throws -> Int {
        if let old = ids[request] {
            if recording.record.result != .pending { try await ledger.enrich(recording, lookup: old) }
            return old
        }
        let id = try await ledger.record(LookupRecording(
            record: recording.record, encounter: nil, keepPolicy: recording.keepPolicy,
            primaryDictionary: recording.primaryDictionary))
        ids[request] = id
        return id
    }

    /// The sense the lookup met, kept automatically where the policy and the primary allow — **never
    /// over the reader's own choice** — and the status that leaves.
    private func recordEncounter(
        of recording: LookupRecording, lookup id: Int, request: Int, in ledger: LedgerStore
    ) async throws {
        if let encounter = recording.encounter, !(readerChoices[request]?.contains(encounter.dictionary.key) ?? false) {
            try await ledger.record(encounter, for: id)
            if recording.keepPolicy == .automatic,
               recording.primaryDictionary == nil || encounter.dictionary.key == recording.primaryDictionary {
                let note = try await ledger.keep(encounter, for: id, language: recording.record.language, source: .automatic)
                states[request] = Self.status(of: note, for: encounter)
            }
        }
        if states[request] == .keeping {
            states[request] = recording.keepPolicy == .manual ? .manual : .needsMeaning
        }
    }

    /// The taps and enrolments made before the row existed, written now, in order. **A failure keeps
    /// that tap and every one after it** for Retry, each under the language it was made in.
    private func drainHeldTaps(lookup id: Int, request: Int) async throws {
        let held = taps.recorded(request: request, id: id)
        for (index, tap) in held.enumerated() {
            do {
                try await write(tap.encounter, lookup: id, enrolling: tap.enrolling,
                                language: tap.language, request: request, source: tap.source)
            } catch {
                keepUnwritten(held[index...].map {
                    SenseIntent(encounter: $0.encounter, enrolling: $0.enrolling,
                                language: $0.language, source: $0.source)
                }, request: request)
                throw error
            }
        }
    }

    /// **Only what this write committed is cleared.** A reader's failed choice stays the thing Retry
    /// replays: it bars the recording's own encounter, so nothing here could carry it — and it stays
    /// *visible*, or the status this write drew would hide Retry over it. **Not over a discard**: that
    /// is the reader's later word on the reading (ADR-0044), a discarded request writes no sense, and
    /// Retry there was dead while it hid Undo. Undoing the discard persists again, and the failure
    /// comes back with it.
    private func settleFailures(after request: Int) {
        if case .sense = failedIntents[request] {
            if states[request] != .discarded && states[request] != .discardedExternally { states[request] = .failed }
        } else { failedIntents[request] = nil }
    }
    private func prune() {
        let stale = recordings.keys.sorted().dropLast(Self.retainedRequests)
        for request in stale where writes[request] == nil {
            taps.forget(request: request)
            recordings[request] = nil; ids[request] = nil; states[request] = nil
            discarded.remove(request); discardOperations[request] = nil; readerChoices[request] = nil; writeVersions[request] = nil; failedIntents[request] = nil; senseIntents[request] = nil
            unwrittenTaps[request] = nil; refreshes[request] = nil
        }
    }
    func refreshStatus(request: Int) async {
        guard writes[request] == nil, states[request] != .failed,
              let id = ids[request], let opening else { return }
        // **Applied only if no write began meanwhile.** The guard above is checked before the awaits
        // below; a write that started during them owns the status, and this read is already stale.
        let version = writeVersions[request]
        // **And only if it is the newest refresh.** Each ledger revision starts one, and an older one
        // finishing last would draw the status before the newer change.
        refreshes[request, default: 0] += 1
        let generation = refreshes[request]
        let unchanged = { [self] in
            writes[request] == nil && writeVersions[request] == version && refreshes[request] == generation
        }
        do {
            let ledger = try await ledger(from: opening)
            let discarded = try await ledger.disposition(ofLookup: id) == .discarded
            let row = discarded ? nil : try await ledger.reading(ofLookup: id)
            guard unchanged() else { return }
            if discarded { states[request] = discardOperations[request] == nil ? .discardedExternally : .discarded }
            else if let row { states[request] = status(of: row.studyStatus, request: request) }
        } catch {
            guard unchanged() else { return }
            failedIntents[request] = .refresh
            states[request] = .failed
        }
    }

    /// What a reading's study status says about this request — one mapping, where three copies were.
    private func status(of study: StudyReadiness?, request: Int) -> LookupKeepStatus {
        switch study {
        case .ready: .kept
        case .needsConfirmation: .needsConfirmation
        case .needsRepair: .needsMeaning
        case nil: recordings[request]?.keepPolicy == .manual ? .manual : .needsMeaning
        }
    }
    func retry(request: Int) {
        states[request] = .keeping
        let failed = failedIntents[request]
        if case .undo? = failed {
            undoDiscard(request: request)
            return
        }
        if case .refresh? = failed {
            failedIntents[request] = nil
            Task { await refreshStatus(request: request) }
            return
        }
        // **A tap is held until its row exists, so a row that was never written is written first** —
        // and the held taps with it, by `persist`. Retry used to re-enqueue the tap, which only held
        // it again: the ledger had failed to open before the row landed, and nothing would ever
        // write either.
        if ids[request] == nil, let row = recordings[request] {
            begin(row, request: request)
            return
        }
        switch failed {
        case .recording(let row)?: begin(row, request: request)
        case nil: if let row = recordings[request] { begin(row, request: request) }
        default: break
        }
        // **Every tap a write failed on, whatever else failed**, in order, then the reader's latest
        // choice if it was not one of them. A recording retry used to leave these behind for good.
        let unwritten = unwrittenTaps.removeValue(forKey: request) ?? []
        for tap in unwritten {
            enqueue(tap.encounter, request: request, enrolling: tap.enrolling, language: tap.language, source: tap.source)
        }
        if case .sense(let intent)? = failed, !unwritten.contains(intent) {
            enqueue(intent.encounter, request: request, enrolling: intent.enrolling, language: intent.language, source: intent.source)
        }
    }

    /// Keeps taps a write failed on for Retry — **added to, never replaced**: two taps failing in
    /// turn each overwrote the record of the other, and Retry replayed only the last.
    private func keepUnwritten(_ taps: some Sequence<SenseIntent>, request: Int) {
        var kept = unwrittenTaps[request] ?? []
        for tap in taps where !kept.contains(tap) { kept.append(tap) }
        unwrittenTaps[request] = kept
    }

    /// After a restore: taps still unwritten are still failures, and say so — the undo's failure,
    /// cleared by its success, was hiding them.
    private func reassertUnwritten(_ request: Int) {
        guard let first = unwrittenTaps[request]?.first else { return }
        failedIntents[request] = .sense(first)
        states[request] = .failed
    }

    /// What a note says about this request's reading.
    private static func status(of note: StudyNote?, for encounter: SenseEncounter) -> LookupKeepStatus {
        guard let note else { return .discarded }
        if encounter.senseKey == nil { return .needsMeaning }
        return note.confirmedAt == nil ? .needsConfirmation : .kept
    }
    func discard(request: Int) {
        guard !discarded.contains(request) else { return }
        log.info("request \(request) discard requested")
        states[request] = .keeping
        discarded.insert(request)
        discardOperations[request] = UUID()
        if let row = recordings[request] { begin(row, request: request) }
    }
    func undoDiscard(request: Int) {
        guard let opening else { return }
        guard let operation = discardOperations[request] else {
            guard let id = ids[request] else { return }
            schedule(request: request) { [self] in
                do {
                    _ = try await ledger(from: opening).changeDisposition(.kept, lookups: [id], operation: UUID())
                    await restored(request)
                } catch { undoFailed(request) }
            }
            return
        }
        schedule(request: request) { [self] in
            do {
                let ledger = try await ledger(from: opening)
                let result = try await ledger.undoDisposition(operation: operation)
                // **Skipped is a conflict, not an error to retry blindly.** The reading changed since
                // the discard; ask the ledger what it is now. Still discarded: the undo stays the thing
                // Retry does. Not discarded: it is restored already, by whatever changed it.
                // Retry restores afresh rather than resubmitting this operation, whose skipped result
                // the ledger keeps and would answer with again.
                if result.skipped > 0, let id = ids[request], try await ledger.disposition(ofLookup: id) == .discarded {
                    discardOperations[request] = nil
                    undoFailed(request)
                    return
                }
                await restored(request)
            } catch { undoFailed(request) }
        }
    }

    /// **Kept again**, by either undo: the status drawn afresh rather than left saying discarded, no
    /// longer discarded here either — or `persist` would discard it again — and the reading written
    /// again, with any failure that was waiting under the discard put back on show. One copy, so the
    /// two undos cannot recover differently (audit round 3, #24).
    private func restored(_ request: Int) async {
        discarded.remove(request)
        discardOperations[request] = nil
        states[request] = .keeping
        if let row = recordings[request] { await persist(row, request: request) }
        reassertUnwritten(request)
    }

    /// An undo that did not take: Retry undoes again.
    private func undoFailed(_ request: Int) {
        failedIntents[request] = .undo
        states[request] = .failed
    }
    func study(_ encounter: SenseEncounter, request: Int) {
        guard isOpen, !discarded.contains(request) else { return }
        let clarification = recordings[request]?.lookupID != nil
        let automatic = clarification || (recordings[request]?.keepPolicy == .automatic && recordings[request]?.primaryDictionary == encounter.dictionary.key)
        enqueue(encounter, request: request, enrolling: automatic, language: recordings[request]?.record.language,
                source: clarification ? .manual : .automatic)
    }
    /// Waits for every write scheduled for `request` so far. **For a caller that started a write
    /// and must not race it** — the work, not a clock: a test that polled the ledger for two
    /// seconds failed whenever the machine was busier than that.
    func settled(request: Int) async { await writes[request]?.value }

    /// Whether `request`'s reading is in the ledger — its row written, and no failed recording
    /// waiting to be retried. A failed sense choice is a different failure and does not count.
    func didRecord(request: Int) -> Bool {
        if case .recording? = failedIntents[request] { return false }
        return ids[request] != nil
    }

    /// How `request` ended in the ledger: its row written, or handed over and not written — **nil where
    /// it was never handed over**, which only the caller, who knows whether the panel drew, can name.
    func ending(request: Int) -> LookupTimeline.Ending? {
        if didRecord(request: request) { return .recorded }
        return recordings[request] == nil ? nil : .notRecorded
    }

    func enrol(_ encounter: SenseEncounter, request: Int, language: String?) {
        guard isOpen, !discarded.contains(request) else { return }
        enqueue(encounter, request: request, enrolling: true, language: language, source: .manual)
    }
    private func enqueue(_ encounter: SenseEncounter, request: Int, enrolling: Bool, language: String?, source: StudyKeepSource) {
        let intent = SenseIntent(encounter: encounter, enrolling: enrolling, language: language, source: source)
        senseIntents[request] = intent
        readerChoices[request, default: []].insert(encounter.dictionary.key)
        guard let lookup = ids[request] ?? taps.tapped(encounter, request: request, enrolling: enrolling, source: source, language: language) else { return }
        states[request] = .keeping
        schedule(request: request) { [self] in
            do { try await write(encounter, lookup: lookup, enrolling: enrolling, language: language, request: request, source: source) }
            catch {
                keepUnwritten([intent], request: request)
                failedIntents[request] = .sense(intent)
                states[request] = .failed
            }
        }
    }
    private func write(_ encounter: SenseEncounter, lookup: Int, enrolling: Bool, language: String?, request: Int,
                       source: StudyKeepSource = .manual) async throws {
        guard let opening, !discarded.contains(request) else { return }
        let ledger = try await ledger(from: opening)
        try await ledger.record(encounter, for: lookup)
        if enrolling {
            let note = try await ledger.keep(encounter, for: lookup, language: language, source: source)
            states[request] = Self.status(of: note, for: encounter)
        } else {
            states[request] = status(of: try await ledger.reading(ofLookup: lookup)?.studyStatus, request: request)
        }
        log.info("request \(request) lookup \(lookup) reader intent committed enrolling \(enrolling)")
        // **A newer choice in a dictionary retires the failed ones in it**, which a later Retry would
        // otherwise replay over this one.
        unwrittenTaps[request]?.removeAll { $0.encounter.dictionary.key == encounter.dictionary.key }
        // **A choice in another dictionary is not superseded by this one**, so its failure and its
        // Retry outlive this success. A later choice in the same dictionary does replace it.
        if case .sense(let failed) = failedIntents[request], failed.encounter.dictionary.key != encounter.dictionary.key {
            senseIntents[request] = failed
            states[request] = .failed
        } else {
            failedIntents[request] = nil
            senseIntents[request] = nil
        }
        LedgerChanges.shared.committed()
    }
}

/// That the ledger changed, and nothing about where. **Every observer refreshes what it shows**, so
/// the ids this once carried were read by nobody — a payload that looks like scoping and is not.
@Observable @MainActor
final class LedgerChanges {
    static let shared = LedgerChanges()
    private(set) var revision = 0
    func committed() { revision += 1 }
}
