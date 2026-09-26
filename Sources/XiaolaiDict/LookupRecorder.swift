import Foundation
import Observation
import XiaolaiDictBase
import XiaolaiDictCore
import os

/// What reaches the reader's ledger, and what to tell them when nothing did.
///
/// **Its own type because the ordering is the whole subject, and the ordering is not obvious.**
/// Three separate rules have to hold at once, and each was a defect first:
///
/// - **A tap belongs to its own lookup, not to whichever row landed last.** The panel draws every
///   sense as soon as the dictionaries answer, and the lookup's own row is written only once the
///   selector has decided — seconds later on the local model's rung. A tap in between belongs to a
///   lookup the ledger has never heard of, and hanging it off the newest row files a study item
///   under the previous word, silently. `SenseTapQueue` holds it until *that* request's row lands.
/// - **The status shown is the newest request's, not the newest write's.** Writes finish out of
///   order, so `if request >= reported` is what keeps a stale failure from overwriting a fresh
///   success — and what keeps the launch-time "ledger unavailable" from overwriting a real lookup's
///   own, better, message.
/// - **A failure is surfaced, never swallowed.** It goes in the menu, where the reader already
///   looks. A sense that could not be written is logged only: the row it belonged to is already
///   gone from a drawer they have moved on from.
///
/// Opening is a background task because a migration on the first launch after an update is file and
/// database work, and the menu bar must not wait for it.
@Observable
@MainActor
final class LookupRecorder {
    @ObservationIgnored private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "ledger")
    @ObservationIgnored private var opening: Task<LedgerStore, any Error>?

    /// The ledger's state as of the newest request to finish recording — **not** of whichever write
    /// happened to finish last.
    private var status: (request: Int, problem: String?) = (0, nil)

    /// Which lookup a reader's tap belongs to — see `SenseTapQueue`.
    @ObservationIgnored private var taps = SenseTapQueue()

    /// What the menu says about recording, or nil when there is nothing to say.
    var problem: String? { status.problem }

    /// Whether the ledger has been asked to open. A recorder that was never started records
    /// nothing rather than pretending to — which is what an instrument run wants.
    var isOpen: Bool { opening != nil }

    /// Opens the reader's ledger on a background task. Called once, at launch.
    ///
    /// `open` is a parameter so a test opens a temporary ledger rather than the reader's own.
    func start(open: @escaping @Sendable () async throws -> LedgerStore = { try await LedgerStore.openDefault() }) {
        let task = Task { try await open() }
        opening = task
        Task { [weak self] in
            do {
                _ = try await task.value
            } catch {
                guard let self else { return }
                // Reported only if no lookup has reported since: a later lookup's own failure says
                // more, and must not be overwritten by this older news.
                if status.request == 0 {
                    status = (0, "Lookups are not being recorded: \(error)")
                }
                log.error("ledger unavailable: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The ledger itself, for the surfaces that read it — the history drawer, and the memory strip's
    /// prior encounters. Nil until `start` has been called.
    var store: Task<LedgerStore, any Error>? { opening }

    /// A lookup the reader saw. Returns nothing: what there is to say lands in `problem`.
    func record(_ recording: LookupRecording, request: Int) async {
        guard let opening else { return }
        var problem: String?
        do {
            let id = try await opening.value.record(recording)
            // Whatever the reader tapped while this row was being written now has somewhere to go.
            for encounter in taps.recorded(request: request, id: id) { write(encounter, for: id) }
        } catch {
            problem = "The last lookup was not recorded: \(error)"
            log.error("ledger write failed: \(String(describing: error), privacy: .public)")
        }
        if request >= status.request { status = (request, problem) }
    }

    /// A sense the reader tapped. Recorded as theirs — `chosen_by: reader` — which the ledger keeps
    /// apart from the selector's guesses, because a hypothesis and a fact must never merge.
    ///
    /// Held rather than written where the lookup's own row does not exist yet.
    func study(_ encounter: SenseEncounter, request: Int) {
        guard isOpen, let lookup = taps.tapped(encounter, request: request) else { return }
        write(encounter, for: lookup)
    }

    private func write(_ encounter: SenseEncounter, for lookup: Int) {
        guard let opening else { return }
        Task { [log] in
            do {
                try await opening.value.record(encounter, for: lookup)
            } catch {
                // Logged, not surfaced: the row is already gone from a drawer the reader has moved
                // on from, and an alert about a history row is worse than the row.
                log.error("sense not recorded: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// How many taps are still waiting for their lookup's row — for tests, and for reasoning about
    /// `SenseTapQueue`'s cap.
    var heldTaps: Int { taps.heldCount }
}
