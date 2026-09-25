import Foundation
import XiaolaiDictCore
import XiaolaiDictUI

/// One lookup, from selection to panel to ledger row.
///
/// The panel is shown **before** the dictionaries are asked, and filled when they answer. It used
/// to be the other way round — the panel did not exist until `client.lookup` resolved — which meant
/// a hung service held the panel for the whole `DictionaryClient.defaultDeadline` of three seconds,
/// against the 1 s the reader is promised (`feature-ledger-ux.md` B3). Measured on this Mac, an
/// ordinary lookup of *hold* already takes 410 ms of that budget, most of it walking the entries'
/// XHTML, so the gap is not hypothetical.
///
/// Separate from `XiaolaiDictApp` because the *order* is the thing worth testing and cannot be seen from
/// outside an app delegate.
@MainActor
final class LookupRunner {
    private let client: DictionaryClient
    private let panel: any LookupPanelPresenting
    private let primary: () -> PrimaryDictionary
    private let selector: any SenseSelecting
    /// What this word cost the reader before — **by lemma and language**. English *gift* and
    /// German *Gift* are one lemma and two words; the ledger keeps them apart and this has to ask
    /// it to, or a reader of both is shown the other one's history.
    private let priorEncounters: @Sendable (String, Date, String?) async -> PriorEncounters
    /// Loads the local model while the dictionaries are asked, so the sense question that follows
    /// does not pay for the load: the first answer measured 1.6–2.5 s cold, 0.24–0.44 s warm.
    private let prewarm: @Sendable () async -> Void

    init(
        client: DictionaryClient, panel: any LookupPanelPresenting,
        primary: @escaping () -> PrimaryDictionary = { PrimaryDictionaryStore().load() },
        selector: any SenseSelecting = LadderSenseSelector(),
        priorEncounters: @escaping @Sendable (String, Date, String?) async -> PriorEncounters = { _, _, _ in PriorEncounters() },
        prewarm: @escaping @Sendable () async -> Void = {}
    ) {
        self.client = client
        self.panel = panel
        self.primary = primary
        self.selector = selector
        self.priorEncounters = priorEncounters
        self.prewarm = prewarm
    }

    /// Shows the panel, asks the dictionaries, fills the panel in.
    ///
    /// Returns the row to record, or nil when the lookup was superseded before its answer arrived —
    /// a lookup nobody saw is not one the reader made, and does not belong in the ledger.
    func run(
        _ selection: Selection, near pointer: UpPoint, requestedAt: Date, ticket: PanelTicket
    ) async -> LookupRecording? {
        let lemma = Lemmatizer.lemma(of: selection.text, in: selection.sentence, at: selection.rangeInSentence)
        // The app, and then the most precise thing the app could say about where inside it — which
        // for 12 of the 17 apps measured is nothing at all.
        let source = [selection.place.name, selection.place.label]
            .compactMap { $0 }.filter { !$0.isEmpty }.removingAdjacentDuplicates().joined(separator: " · ")
        var presentation = LookupPresentation(
            request: ticket.number, term: selection.text, lemma: lemma, source: source, capture: selection.quality,
            sentence: selection.quality.context == .complete ? selection.sentence : nil, outcome: nil)
        panel.show(.lookup(presentation), near: pointer, for: ticket)
        // Not awaited, and **deliberately not cancelled with this lookup**: the load runs beside the
        // dictionary lookup, which is the time it has, and a reader who supersedes one lookup with
        // another wants the model that was being loaded for the first. Detached for that reason —
        // structured, it would be torn down by the supersession it is meant to outlive. Nothing
        // waits on it, so no answer depends on its order; the worst case is the sense question
        // loading the model itself.
        Task.detached(priority: .userInitiated) { [prewarm] in await prewarm() }
        // The ledger read starts here too, so what this word cost the reader before is being fetched
        // while the dictionaries are asked rather than after them.
        let language = Lemmatizer.language(of: selection.text, in: selection.sentence)
        let history = Task { [priorEncounters] in
            await priorEncounters(lemma.text, requestedAt, language)
        }

        guard let outcome = try? await client.lookup(selection.text), panel.isCurrent(ticket) else {
            history.cancel()
            return nil
        }
        presentation.outcome = outcome
        panel.update(.lookup(presentation), for: ticket)

        // Which entry, and where it is a fact rather than a guess, which sense.
        //
        // The entry is already on screen with every one of its senses; only the *mark* waits on the
        // selector. That is Stage 1's fill-in pattern again, and no new mechanism was needed for it.
        //
        // **Started before the ledger is awaited**, because the two have nothing to do with each
        // other: the selector can take seconds on the model's rung, and waiting for a disk read
        // first would add its time to the mark for nothing.
        // `let`, so it can travel into the group's child. A `var` captured by a sending closure is
        // refused — correctly: the compiler cannot know the actor will not write it again.
        let entries: [DictionaryEntry]
        if case .entries(let found, _) = outcome {
            entries = Array(found)
        } else {
            entries = []
        }
        // Built here rather than inside the `async let`: the closure that reads the reader's chosen
        // dictionary belongs to this actor and must not travel with the work.
        let resolver = SenseResolver(primary: primary(), selector: selector)
        let partOfSpeech = Lemmatizer.partOfSpeech(
            of: selection.text, in: selection.sentence, at: selection.rangeInSentence)

        // **Each arrives when it is ready, and neither waits for the other.** Both were already
        // started side by side, and then awaited in a fixed order — so a sense the selector had
        // *already* decided sat behind the ledger read before it could be drawn. Starting two
        // pieces of work concurrently does not make their answers independent; awaiting them in
        // order puts them back in series at the last step.
        //
        // The group yields in completion order, and every mutation of `presentation` stays here on
        // the actor rather than travelling into a child — which is what keeps two arrivals from
        // racing over one value. A group awaits both children before it returns, which is exactly
        // what is wanted: the row below needs the resolution.
        //
        // The memory strip is absent on a first lookup, so a reader meeting a word for the first
        // time is shown nothing rather than "0 previous".
        enum Arrival: Sendable {
            case memory(PriorEncounters)
            case sense(SenseResolution)
        }
        var resolution = SenseResolution(mark: nil, encounter: nil)
        await withTaskGroup(of: Arrival.self) { group in
            group.addTask { .memory(await history.value) }
            // **A child of the group, never a `Task` of its own.** An unstructured task does not
            // inherit cancellation, so superseding a lookup left the sense resolver running — and
            // on the model's rung that is the GPU still answering a question nobody is waiting for.
            // `async let` had that property and an earlier version of this merge threw it away by
            // reaching for `Task { }`; a group child has it back, and the group is what allows the
            // two answers to arrive in either order.
            group.addTask {
                .sense(await resolver.resolve(
                    entries: entries, sentence: selection.sentence,
                    context: selection.quality.context, partOfSpeech: partOfSpeech, at: .now))
            }
            for await arrival in group {
                switch arrival {
                case .memory(let prior):
                    guard panel.isCurrent(ticket), prior != PriorEncounters() else { continue }
                    presentation.memory = MemoryStrip(prior)
                    presentation.met = prior.met
                    panel.update(.lookup(presentation), for: ticket)
                case .sense(let answered):
                    resolution = answered
                    guard let mark = answered.mark, panel.isCurrent(ticket) else { continue }
                    presentation.sense = mark
                    presentation.senseOwner = answered.owner
                    panel.update(.lookup(presentation), for: ticket)
                }
            }
        }
        // **Recorded even if superseded while the sense was decided**, and on purpose: the entry was
        // already on screen, so this is a lookup the reader made. The rule is "a lookup nobody saw is
        // not recorded", and only the check before the entry was shown can say nobody saw it. What a
        // superseded lookup never showed is the *mark* — and a model's mark is recorded as the
        // hypothesis it is (`chosen_by: model`), not as something the reader confirmed.
        return LookupRecording(
            record: Self.record(of: selection, lemma: lemma, language: language, outcome: outcome,
                                requestedAt: requestedAt,
                                // **A lookup the reader walked away from did not get declined and
                                // did not find no model.** Superseding it cancels this task, and the
                                // ladder reports a cancelled run as an abstention like any other —
                                // recorded, that is a false model status in the ledger for a
                                // question that was never finished being asked.
                                abstention: Task.isCancelled ? nil : resolution.abstention),
            encounter: resolution.encounter)
    }

    /// The ledger row for a lookup — what was read, where, how it was captured, what answered, and
    /// why no sense was marked where none was.
    private static func record(
        of selection: Selection, lemma: Lemma, language: String?, outcome: LookupOutcome,
        requestedAt: Date, abstention: Abstention?
    ) -> LookupRecord {
        LookupRecord(
            surface: selection.text, lemma: lemma.text, context: selection.sentence ?? selection.text,
            // All four were computed at every lookup and thrown away at the ledger before schema 4.
            // **The language is passed in, not recognised again.** `run` already built an
            // `NLLanguageRecognizer` for the ledger read; a second one per lookup answered the same
            // question twice, and two recognisers could in principle disagree — the row and the
            // history query would then be keyed on different languages for one word.
            lemmaBasis: lemma.basis, language: language,
            contextRange: selection.rangeInSentence, place: selection.place,
            lookedUpAt: requestedAt, result: outcome.result, answeredBy: outcome.answeredBy,
            quality: selection.quality,
            // Why no sense was marked — the selector's reason, which schema 6 keeps. Without it a
            // model that declined the sentence and a Mac with no model leave the same trace.
            senseAbstention: abstention,
            // **The surface, not the sentence.** The filter is about the word the reader looked
            // up; a Chinese word quoted inside an English sentence is still a Chinese word, and
            // classifying the sentence would file it under Latin and show it to a reader who
            // asked not to see it. Nil where nothing classifies — a number, punctuation — which
            // the drawer draws rather than hides.
            script: ProbeScript.dominant(in: selection.text))
    }
}

private extension Array where Element: Equatable {
    /// "Preview · Preview" reads as a stutter; the app's name and its own label can coincide.
    func removingAdjacentDuplicates() -> [Element] {
        reduce(into: []) { kept, next in if kept.last != next { kept.append(next) } }
    }
}
