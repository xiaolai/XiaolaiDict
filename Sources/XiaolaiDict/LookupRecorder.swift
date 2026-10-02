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
    private struct SenseIntent {
        let encounter: SenseEncounter
        let enrolling: Bool
        let language: String?
        let source: StudyKeepSource
    }
    private enum RetryIntent { case recording(LookupRecording), sense(SenseIntent), undo }
    @ObservationIgnored private var failedIntents: [Int: RetryIntent] = [:]
    @ObservationIgnored private var senseIntents: [Int: SenseIntent] = [:]
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
    private func persist(_ recording: LookupRecording, request: Int) async {
        guard let opening else { return }
        do {
            let ledger = try await ledger(from: opening)
            let id: Int
            // **A pending row never overwrites an answered one.** It exists so a new lookup has an id
            // before the dictionaries reply; a reopened reading already has its answer, and one
            // superseded before the reply would otherwise stay pending for good.
            if let old = ids[request] {
                id = old
                if recording.record.result != .pending { try await ledger.enrich(recording, lookup: old) }
            }
            else { id = try await ledger.record(LookupRecording(record: recording.record, encounter: nil, keepPolicy: recording.keepPolicy, primaryDictionary: recording.primaryDictionary)); ids[request] = id }
            if discarded.contains(request) {
                let operation = discardOperations[request] ?? UUID()
                discardOperations[request] = operation
                _ = try await ledger.changeDisposition(.discarded, lookups: [id], operation: operation)
                states[request] = .discarded
            } else if try await ledger.disposition(ofLookup: id) == .discarded {
                states[request] = .discardedExternally
            } else {
                if let encounter = recording.encounter, !(readerChoices[request]?.contains(encounter.dictionary.key) ?? false) {
                    try await ledger.record(encounter, for: id)
                    if recording.keepPolicy == .automatic,
                       recording.primaryDictionary == nil || encounter.dictionary.key == recording.primaryDictionary {
                        let note = try await ledger.keep(encounter, for: id, language: recording.record.language, source: .automatic)
                        states[request] = note == nil ? .discarded : encounter.senseKey == nil ? .needsMeaning : note?.confirmedAt == nil ? .needsConfirmation : .kept
                    }
                }
                if states[request] == .keeping {
                    states[request] = recording.keepPolicy == .manual ? .manual : .needsMeaning
                }
                for tap in taps.recorded(request: request, id: id) {
                    try await write(tap.encounter, lookup: id, enrolling: tap.enrolling,
                                    language: recording.record.language, request: request, source: tap.source)
                }
            }
            log.info("request \(request) lookup \(id) policy \(recording.keepPolicy.rawValue, privacy: .public) committed")
            // **Only what this write committed is cleared.** A reader's failed choice stays the thing
            // Retry replays: it bars the recording's own encounter, so nothing here could carry it —
            // and it stays *visible*, or the status this write drew would hide Retry over it. **Not over
            // a discard**: that is the reader's later word on the reading (ADR-0044), a discarded
            // request writes no sense, and Retry there was dead while it hid Undo. Undoing the
            // discard persists again, and the failure comes back with it.
            if case .sense = failedIntents[request] {
                if states[request] != .discarded && states[request] != .discardedExternally { states[request] = .failed }
            } else { failedIntents[request] = nil }
            if request >= newest { problem = nil }
            LedgerChanges.shared.committed()
        } catch {
            log.error("request \(request) persistence failed")
            failedIntents[request] = senseIntents[request].map(RetryIntent.sense) ?? .recording(recording)
            states[request] = .failed
            if request >= newest { problem = String(localized: "The last reading was not recorded: \(String(describing: error))") }
        }
    }
    private func prune() {
        let stale = recordings.keys.sorted().dropLast(Self.retainedRequests)
        for request in stale where writes[request] == nil {
            taps.forget(request: request)
            recordings[request] = nil; ids[request] = nil; states[request] = nil
            discarded.remove(request); discardOperations[request] = nil; readerChoices[request] = nil; writeVersions[request] = nil; failedIntents[request] = nil; senseIntents[request] = nil
        }
    }
    func refreshStatus(request: Int) async {
        guard writes[request] == nil, states[request] != .failed,
              let id = ids[request], let opening else { return }
        do {
            let ledger = try await ledger(from: opening)
            if try await ledger.disposition(ofLookup: id) == .discarded { states[request] = discardOperations[request] == nil ? .discardedExternally : .discarded }
            else if let row = try await ledger.reading(ofLookup: id) {
                switch row.studyStatus {
                case .ready: states[request] = .kept
                case .needsConfirmation: states[request] = .needsConfirmation
                case .needsRepair: states[request] = .needsMeaning
                case nil: states[request] = recordings[request]?.keepPolicy == .manual ? .manual : .needsMeaning
                }
            }
        } catch { states[request] = .failed }
    }
    func retry(request: Int) {
        states[request] = .keeping
        switch failedIntents[request] {
        case .sense(let intent): enqueue(intent.encounter, request: request, enrolling: intent.enrolling, language: intent.language, source: intent.source)
        case .undo: undoDiscard(request: request)
        case .recording(let row): begin(row, request: request)
        case nil: if let row = recordings[request] { begin(row, request: request) }
        }
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
                    // Kept again, so the status is drawn afresh rather than left saying discarded.
                    states[request] = .keeping
                    if let row = recordings[request] { await persist(row, request: request) }
                } catch { failedIntents[request] = .undo; states[request] = .failed }
            }
            return
        }
        schedule(request: request) { [self] in
            do {
                let result = try await ledger(from: opening).undoDisposition(operation: operation)
                guard result.skipped == 0 else { states[request] = .failed; return }
                discarded.remove(request); discardOperations[request] = nil
                states[request] = .keeping
                if let row = recordings[request] { await persist(row, request: request) }
            } catch { failedIntents[request] = .undo; states[request] = .failed }
        }
    }
    func study(_ encounter: SenseEncounter, request: Int) {
        guard isOpen, !discarded.contains(request) else { return }
        let clarification = recordings[request]?.lookupID != nil
        let automatic = clarification || (recordings[request]?.keepPolicy == .automatic && recordings[request]?.primaryDictionary == encounter.dictionary.key)
        enqueue(encounter, request: request, enrolling: automatic, language: recordings[request]?.record.language,
                source: clarification ? .manual : .automatic)
    }
    func enrol(_ encounter: SenseEncounter, request: Int, language: String?) {
        guard isOpen, !discarded.contains(request) else { return }
        enqueue(encounter, request: request, enrolling: true, language: language, source: .manual)
    }
    private func enqueue(_ encounter: SenseEncounter, request: Int, enrolling: Bool, language: String?, source: StudyKeepSource) {
        let intent = SenseIntent(encounter: encounter, enrolling: enrolling, language: language, source: source)
        senseIntents[request] = intent
        readerChoices[request, default: []].insert(encounter.dictionary.key)
        guard let lookup = ids[request] ?? taps.tapped(encounter, request: request, enrolling: enrolling, source: source) else { return }
        states[request] = .keeping
        schedule(request: request) { [self] in
            do { try await write(encounter, lookup: lookup, enrolling: enrolling, language: language, request: request, source: source) }
            catch { failedIntents[request] = .sense(intent); states[request] = .failed }
        }
    }
    private func write(_ encounter: SenseEncounter, lookup: Int, enrolling: Bool, language: String?, request: Int,
                       source: StudyKeepSource = .manual) async throws {
        guard let opening, !discarded.contains(request) else { return }
        let ledger = try await ledger(from: opening)
        try await ledger.record(encounter, for: lookup)
        if enrolling {
            let note = try await ledger.keep(encounter, for: lookup, language: language, source: source)
            states[request] = note == nil ? .discarded : encounter.senseKey == nil ? .needsMeaning : note?.confirmedAt == nil ? .needsConfirmation : .kept
        } else {
            let row = try await ledger.reading(ofLookup: lookup)
            switch row?.studyStatus {
            case .ready: states[request] = .kept
            case .needsConfirmation: states[request] = .needsConfirmation
            case .needsRepair: states[request] = .needsMeaning
            case nil: states[request] = recordings[request]?.keepPolicy == .manual ? .manual : .needsMeaning
            }
        }
        log.info("request \(request) lookup \(lookup) reader intent committed enrolling \(enrolling)")
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
