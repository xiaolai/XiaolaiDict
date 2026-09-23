import Foundation
import XiaolaiDictCore

/// The in-bundle instruments for the local model. **Only meaningful inside the signed bundle**:
/// the model service is found by the app's own bundle, admits only this signature, and runs MLX
/// only where its Metal library was carried into its `Contents/Resources` and signed innermost-
/// first — none of which a bare binary can check.
@MainActor
enum ModelReport {
    /// Longer than this and the unload is not waited for: a report is not held open for ten minutes.
    static let longestIdleWatch = 120
    /// How long past the interval the service still has to go before the watch calls it a failure.
    static let unloadGrace = Duration.seconds(30)
    static let unloadPoll = Duration.milliseconds(250)

    /// `--model-status`: the service's own report, including **one MLX op evaluated on its GPU**.
    /// "The service started" and "the service can run MLX" are different claims: with the Metal
    /// library in the wrong place it starts, gets a device, and dies on its first array.
    static func status(write: (String) -> Bool = LookupCommand.writeLine) async -> CommandStatus {
        guard case .status(let status)? = await ModelClient().ask(.status) else {
            // Whether that line landed changes nothing: the run has already failed, and the exit
            // code says so whether or not the harness could be told why.
            _ = write(#"{"reachable":false}"#)
            return .failure
        }
        let report: [String: Any] = [
            "reachable": true, "gpu": status.gpu ?? NSNull(), "installed": status.installed?.rawValue ?? NSNull(),
            "loaded": status.loaded, "footprintMB": status.footprint.map(megabytes) ?? NSNull(),
            "availableMB": status.availableMemory.map(megabytes) ?? NSNull(),
        ]
        guard Instrument.write(report, to: write) else { return .internalError }
        return status.gpu == nil ? .failure : .success
    }

    /// `--model-report`: the whole path the reader's Mac takes, measured end to end.
    ///
    /// Downloads the model this Mac is offered from ModelScope into the reader's store if it is not
    /// already whole there — inside this signed bundle, through the same downloader the setup board
    /// uses — then asks the service for a sense answer and a translation through the real XPC path,
    /// reports the service's footprint, and watches it end itself when idle.
    static func run(write: (String) -> Bool = LookupCommand.writeLine) async -> CommandStatus {
        var report: [String: Any] = [:]
        let ok: Bool
        do {
            ok = try await measure(into: &report)
        } catch is CancellationError {
            return .interrupted
        } catch {
            report["error"] = "\(error)"
            ok = false
        }
        guard Instrument.write(report, to: write) else { return .internalError }
        return ok ? .success : .failure
    }

    /// Whether this run watched an unload. A run with the shipped ten-minute interval does not, and
    /// reports `skipped` — which is not a pass.
    private static func measure(into report: inout [String: Any]) async throws -> Bool {
        let store = ModelStore.standard()
        let physical = SystemMemory.physical
        let available = SystemMemory.available() ?? 0
        // **The model this Mac would actually load**, by the rule the service itself follows: the
        // largest installed size that fits in memory *now*. Reading it as "the largest installed"
        // alone reported a correctly chosen smaller model as a failure on a busy Mac; asking for the
        // recommended size instead downloaded one the service would never load, beside a larger one.
        let installed = store.installedManifests(among: ModelManifest.all)
            .map(\.size)
            .filter { ModelSizing.mayLoad($0, physicalMemory: physical, availableMemory: available) }
            .max()
        guard let size = installed ?? ModelSizing.recommended(physicalMemory: physical) else {
            report["error"] = "this Mac is offered no model"
            return false
        }
        report["size"] = size.rawValue
        let downloaded = try await install(size.manifest, into: store, report: &report)
        guard downloaded.installed else { return false }

        let client = ModelClient()
        // **Measured against a service this run started.** A resident one holds whatever it loaded
        // — the previous revision of this same size satisfies every check below, because they
        // compare sizes and not pins — and its prewarm time would be reported as a cold load that
        // never happened. Ended before anything is measured, whether or not this run downloaded
        // anything, and the run stops if it will not go: numbers from the wrong process are worse
        // than no numbers.
        let ended = await client.unload()
        report["endedTheRunningService"] = ended
        guard ended else {
            report["error"] = "a model service was already running and would not end, so nothing here would be about this build"
            return false
        }
        // **Asked, then checked for cancellation, at every question.** `ModelClient.ask` answers nil
        // when the *caller* was cancelled — the service is fine and was never the problem — so a run
        // somebody stopped used to be filed as a service that could not be reached, and `run`
        // returned `.failure` for a measurement that was never taken. The check turns each of those
        // into the `CancellationError` `run` already maps to `.interrupted`.
        let first = await client.ask(.status)
        try Task.checkCancellation()
        guard case .status(let before)? = first else {
            report["reachable"] = false
            return false
        }
        report["gpu"] = before.gpu ?? NSNull()

        let warm = try await prewarm(client, report: &report)
        let answered = try await answer(client, report: &report)

        let second = await client.ask(.status)
        try Task.checkCancellation()
        guard case .status(let after)? = second else {
            report["statusAfterAnswer"] = "the service did not answer"
            return false
        }
        report["footprintMB"] = after.footprint.map(megabytes) ?? NSNull()
        report["loaded"] = after.loaded
        // The service loads by its own rule; if that is not the size this run installed, the numbers
        // above are about a different model.
        report["installedNow"] = after.installed?.rawValue ?? NSNull()
        report["measuredTheModelInstalled"] = after.installed == size
        // **The pin, not only the size.** Every check here compares `LocalModelSize`, which an
        // older revision of the same size satisfies — so the identifier is reported beside them and
        // the store is asked whether the model on disk is the one this build pins.
        report["identifier"] = size.manifest.identifier
        report["installedIsThePinnedRevision"] = store.installed(size.manifest) != nil

        // The shipped watch, with the one thing it cannot default: a question asked of this client.
        // Nil covers both "the service did not answer" and "this run was cancelled"; `freshStatus`
        // is where the two are told apart.
        let unload = try await watchIdleUnload(
            IdleWatch(status: {
                if case .status(let status)? = await client.ask(.status) { return status }
                return nil
            }),
            into: &report)
        // A watch that was skipped is not an unload that was seen: the stage asks for `observed`,
        // and a run whose interval is too long to wait out says so rather than passing quietly.
        return before.gpu != nil && warm && answered && after.loaded
            && after.installed == size && unload == .observed
    }

    /// Downloads the model if the store has no whole copy of it. `downloaded` is written **after**
    /// the install returns, so a failed one is not reported as a download that happened — and it is
    /// a claim about what *this run* found missing beforehand, not proof that bytes crossed the
    /// network: another process may have finished the same model in between.
    private static func install(
        _ manifest: ModelManifest, into store: ModelStore, report: inout [String: Any]
    ) async throws -> (installed: Bool, changed: Bool) {
        let wanted = store.installed(manifest) == nil
        report["downloadRequired"] = wanted
        report["downloaded"] = false
        let started = ContinuousClock.now
        let lastTenth = LockedInt(-1)
        try await ModelDownloader(store: store).install(manifest) { progress in
            // A line per tenth, on stderr, so a slow network is visible rather than silent.
            let tenth = Int(progress.fraction * 10)
            if lastTenth.exchange(tenth) != tenth { LookupCommand.writeError("download \(tenth * 10)%") }
        }
        // Read once: asked twice, the report and the answer could disagree about the same moment.
        let whole = store.installed(manifest) != nil
        report["downloaded"] = wanted
        report["downloadSeconds"] = seconds(since: started)
        report["installed"] = whole
        return (installed: whole, changed: wanted && whole)
    }

    private static func prewarm(_ client: ModelClient, report: inout [String: Any]) async throws -> Bool {
        let started = ContinuousClock.now
        let reply = await client.ask(.prewarm)
        try Task.checkCancellation()
        report["prewarmSeconds"] = seconds(since: started)
        report["prewarmed"] = reply == .prewarmed
        return reply == .prewarmed
    }

    /// The ship's hold: the project's canonical polysemy case, with the sense it means second — then
    /// the same sentence translated, told which sense it met.
    private static func answer(_ client: ModelClient, report: inout [String: Any]) async throws -> Bool {
        let senses = [
            "grasp, carry, or support with one's hands",
            "a large space in the lower part of a ship or aircraft in which cargo is stored",
            "keep or detain someone",
        ]
        let senseStarted = ContinuousClock.now
        let sentence = "It was stowed forward in the ship's hold, where the rats had got at the biscuit."
        let sense = await client.ask(.pickSense(SenseQuestion(
            sentence: sentence, partOfSpeech: "noun", senses: senses)))
        try Task.checkCancellation()
        report["senseSeconds"] = seconds(since: senseStarted)
        // The sentence itself, because the gate checks the explanation is not this handed back —
        // and a check reading a key the report never wrote was comparing against its own fallback
        // literal, so it could not fail.
        report["sentence"] = sentence
        if case .sense(let number)? = sense { report["sense"] = number } else { report["sense"] = "\(String(describing: sense))" }

        // **The same sentence, and the sense the model just gave for it.** Translating a different
        // sentence, told a sense picked by hand, measured neither end of the wiring it claims to.
        let met: TranslationQuestion.MetSense? = if case .sense(let number)? = sense,
            number >= 1, number <= senses.count {
            .init(term: "hold", sense: senses[number - 1])
        } else {
            nil
        }
        report["translationToldSense"] = met?.sense ?? NSNull()
        let translationStarted = ContinuousClock.now
        let translation = await client.ask(.translate(TranslationQuestion(
            sentence: sentence, target: "zh-Hans", met: met)))
        try Task.checkCancellation()
        report["translationSeconds"] = seconds(since: translationStarted)
        // **Checked the way the pane checks it.** Any `.translation` counted as success here, while
        // the pane runs `TranslationCheck` and would reject an echo or an untranslated answer — so
        // the report could pass on exactly what the reader would be shown a fallback for.
        if case .translation(let text)? = translation,
           TranslationCheck.isTranslation(text, of: sentence, into: "zh-Hans") {
            report["translation"] = text
        } else {
            report["translation"] = NSNull()
            report["translationFailure"] = "\(String(describing: translation))"
        }
        // **The sentence pane's own path, on the same sentence.** It is the third thing the panel
        // asks this model for, and the one a reader without Apple Intelligence has no other engine
        // for — so a run that measured sense and translation and left it out would say nothing
        // about whether the pane works at all.
        let explanationStarted = ContinuousClock.now
        let explanation = await client.ask(.explain(SentenceQuestion(
            sentence: sentence, term: "hold", senseText: met?.sense)))
        try Task.checkCancellation()
        report["explanationSeconds"] = seconds(since: explanationStarted)
        if case .explanation(let text)? = explanation {
            report["explanation"] = text
        } else {
            report["explanation"] = NSNull()
            report["explanationFailure"] = "\(String(describing: explanation))"
        }

        let chosen = if case .sense(2)? = sense { true } else { false }
        let translated = report["translation"] is String
        let explained = if case .explanation? = explanation { true } else { false }
        return chosen && translated && explained
    }

    enum UnloadWatch: String {
        case observed, skipped, failed
    }

    /// Everything the idle watch reads from outside itself: the interval the service is running on,
    /// whether its process is still there, the clock, the wait between polls, and one question to
    /// the service.
    ///
    /// **It exists so the watch's transitions can be exercised, and for nothing else.** Six
    /// outcomes — skipped, observed, still running, gone too early, never came back, came back
    /// loaded — were reachable only by running `--model-report` inside the signed bundle against a
    /// service whose interval had been shortened, which is one outcome per run and minutes to get
    /// it. Every value here is the shipped one; `--model-report` passes only the status probe,
    /// because that is the one thing it cannot default (it needs the client). This is not a way to
    /// configure the instrument: a run that could choose its own clock or its own idea of whether
    /// the service is running would report an unload it had arranged rather than one it had seen.
    struct IdleWatch {
        /// The interval the service itself decides by, from the app's own defaults domain — the
        /// same reading `ModelIdle` gives the service, or the watch waits for an unload that was
        /// never going to happen.
        var idleSeconds: @MainActor () -> Int = {
            ModelIdle.seconds(configured: UserDefaults.standard.object(forKey: ModelIdle.defaultsKey) as? Int)
        }
        var serviceIsRunning: @MainActor () -> Bool = { ModelServiceProcess.isRunning }
        var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
        var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        /// One status question, nil where the service did not answer it.
        var status: @MainActor () async -> ModelServiceStatus?
    }

    /// **Unloading is the service ending while its client is still here.** Watched from inside the
    /// client because that is the only way to see it: when a client process exits, launchd ends its
    /// service with it (the MLX-in-XPC spike, S2), so a watch from outside after this report
    /// finished saw the service gone in 0 s and measured the client leaving, not the idle timer.
    ///
    /// Only where the interval is short enough to wait out — the end-to-end stage sets 20 s. At the
    /// shipped ten minutes it says it did not watch, which is **not** the same as having seen one.
    /// Then asks once more, to show the next question brings a fresh service back.
    static func watchIdleUnload(_ watch: IdleWatch, into report: inout [String: Any]) async throws -> UnloadWatch {
        let interval = watch.idleSeconds()
        report["idleSeconds"] = interval
        guard interval <= longestIdleWatch else {
            report["unloadWatch"] = UnloadWatch.skipped.rawValue
            report["unload"] = "not watched: the idle interval is \(interval) s; set \(ModelIdle.defaultsKey) lower to watch one"
            return .skipped
        }
        let lastRequest = watch.now()
        let limit = lastRequest.advanced(by: .seconds(interval) + unloadGrace)
        while watch.serviceIsRunning(), watch.now() < limit {
            try await watch.sleep(unloadPoll)
        }
        // A run someone stopped measured nothing, and must not be filed as a watch that failed.
        try Task.checkCancellation()
        guard !watch.serviceIsRunning() else {
            report["unloadWatch"] = UnloadWatch.failed.rawValue
            report["unload"] = "still running \(interval) s + \(unloadGrace) after the last request"
            return .failed
        }
        let waited = seconds(since: lastRequest, now: watch.now())
        report["unloadedAfterSeconds"] = waited
        // **A service that went early did not idle out — it died.** Every disappearance counted as
        // an unload, so a crash on the first question read as the feature working.
        guard waited >= Double(interval) * earliestIdleShare else {
            report["unloadWatch"] = UnloadWatch.failed.rawValue
            report["unload"] = "the service went after \(waited) s of a \(interval) s interval, which is a crash and not an idle unload"
            return .failed
        }
        // The next question, on the same client: a new service, launched on demand, holding nothing.
        // Asked more than once, because the session to the process that has gone may not have been
        // invalidated yet — the first question can fail on the stale one, and the second is what
        // opens the fresh service. That is the client's own contract, not a workaround for it.
        // **Two different failures, and they are not called the same thing.** Nothing came back at
        // all — the service never relaunched; or one came back still holding the model, which did
        // relaunch and did not unload. Filed together as `relaunched: false`, the second read as
        // the first, and a service that had ignored the unload looked like one launchd never
        // started.
        guard let fresh = try await freshStatus(watch) else {
            report["unloadWatch"] = UnloadWatch.failed.rawValue
            report["relaunched"] = false
            return .failed
        }
        guard !fresh.loaded else {
            report["unloadWatch"] = UnloadWatch.failed.rawValue
            report["relaunched"] = true
            report["unload"] = "the service came back still holding the model, so the idle unload released nothing"
            return .failed
        }
        report["unloadWatch"] = UnloadWatch.observed.rawValue
        report["relaunched"] = true
        report["footprintAfterUnloadMB"] = fresh.footprint.map(megabytes) ?? NSNull()
        return .observed
    }

    /// The status of the service that comes back, within a bounded number of tries.
    ///
    /// **A question that came back empty because the caller gave up is not a service that never
    /// relaunched.** Cancelled, every question here answers nil, the tries run out, and the watch
    /// filed `relaunched: false` — a failure reported for a measurement nobody took. Asked after the
    /// answer, which is where that nil arrives; and again at the head of the loop, because a sleep
    /// that returns quietly would otherwise carry a stopped run into another question.
    private static func freshStatus(_ watch: IdleWatch) async throws -> ModelServiceStatus? {
        for attempt in 0..<relaunchTries {
            try Task.checkCancellation()
            let status = await watch.status()
            try Task.checkCancellation()
            if let status { return status }
            if attempt + 1 < relaunchTries { try await watch.sleep(unloadPoll) }
        }
        return nil
    }

    static let relaunchTries = 3
    /// How much of the idle interval must pass before a service going counts as having idled out
    /// rather than crashed. Not 1.0 — the watch polls and the timer's own check lands on a boundary
    /// — but close to it: at 0.8 a 120 s interval would have accepted an exit 24 s early, which is
    /// a crash with plenty of room to look like a feature.
    static let earliestIdleShare = 0.95

    private static func megabytes(_ bytes: UInt64) -> UInt64 { bytes / 1_048_576 }

    /// Reads the clock itself unless one is handed in — the idle watch hands in its own, so how
    /// long it waited is measured on the clock it waited by.
    private static func seconds(
        since start: ContinuousClock.Instant, now: ContinuousClock.Instant = ContinuousClock.now
    ) -> Double {
        let elapsed = now - start
        return ((Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * 100).rounded() / 100
    }
}

/// A counter the download's progress closure can compare-and-swap without capturing a `var`.
private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) { self.value = value }
    /// Stores `new` and returns what was there.
    func exchange(_ new: Int) -> Int { lock.withLock { defer { value = new }; return value } }
}
