import Capture
import CaptureModel
import DictionaryModel
import Foundation
import StudyKit
import StudyModels
import XiaolaiDictBase
import os
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
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "lookup")
    private let initialRecording: @MainActor (LookupRecording, Int) -> Void
    private let keepPolicy: @MainActor () -> LookupKeepPolicy
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
    /// Waits, bounded, until the study dictionary has been derived for this reader's language.
    private let settle: () async -> Void
    /// Notes each stage this lookup reaches, under its request — `LookupTimeline`.
    private let mark: @MainActor (LookupTimeline.Stage, Int, ContinuousClock.Instant) -> Void

    init(
        client: DictionaryClient, panel: any LookupPanelPresenting,
        primary: @escaping () -> PrimaryDictionary = { PrimaryDictionaryStore().load() },
        selector: any SenseSelecting = LadderSenseSelector(),
        priorEncounters: @escaping @Sendable (String, Date, String?) async -> PriorEncounters = { _, _, _ in PriorEncounters() },
        prewarm: @escaping @Sendable () async -> Void = {},
        settle: @escaping () async -> Void = {},
        keepPolicy: @escaping @MainActor () -> LookupKeepPolicy = { .manual },
        initialRecording: @escaping @MainActor (LookupRecording, Int) -> Void = { _, _ in },
        mark: @escaping @MainActor (LookupTimeline.Stage, Int, ContinuousClock.Instant) -> Void = { _, _, _ in }
    ) {
        self.mark = mark
        self.initialRecording = initialRecording
        self.keepPolicy = keepPolicy
        self.client = client
        self.panel = panel
        self.primary = primary
        self.selector = selector
        self.priorEncounters = priorEncounters
        self.prewarm = prewarm
        self.settle = settle
    }

    /// Shows the panel, asks the dictionaries, fills the panel in.
    ///
    /// Returns the row to record, or nil when the lookup was superseded before its answer arrived —
    /// a lookup nobody saw is not one the reader made, and does not belong in the ledger.
    func run(
        _ selection: Selection, near pointer: UpPoint, requestedAt: Date, ticket: PanelTicket, existingLookup: LookupIdentity? = nil,
        seen reportSeen: @MainActor (Bool) -> Void = { _ in }
    ) async -> LookupRecording? {
        let frozenKeepPolicy = existingLookup == nil ? keepPolicy() : .manual
        // **A `stat`, and only to notice that the service finished a build** since this process last read the
        // table; the read itself is off this path, and a lookup meanwhile uses the table in force.
        FormAuthority.shared.refreshInBackground()
        // Provisional: the card must not wait for the table, so the first lookup of a session shows the lemma the
        // tagger gave; the lemma that keys the ledger is settled below, once the panel is up.
        let tableAtFirst = FormAuthority.shared.revision
        var lemma = Lemmatizer.lemma(of: selection.text, in: selection.sentence, at: selection.rangeInSentence)
        var presentation = Self.presentation(of: selection, lemma: lemma, request: ticket.number)
        // **Stops here if the panel is not on screen.** Not a formality: the window action is
        // captured by a view's `.task`, so until that runs there is nothing to draw into, and a
        // lookup that ran anyway resolved a sense and wrote a ledger row for a panel the reader
        // never saw. The rule is "a lookup nobody saw is not recorded", and this is the only place
        // that can tell.
        guard panel.show(.lookup(presentation), near: pointer, for: ticket) else {
            reportSeen(false)
            return nil
        }
        // **And the compositor's word that it is.** `show` answering true says the window was asked
        // for, not that it is drawn — and only the compositor is evidence of that. Asked beside the
        // lookup rather than before it, so the reader's answer is not held up by the check.
        // **Dated when the compositor listed it**, so "panel" times what the reader saw, and a panel
        // that never drew is never timed as shown.
        let seen = Task { () -> ContinuousClock.Instant? in await panel.seenOnScreen(ticket) ? .now : nil }
        let language = Lemmatizer.language(of: selection.text, in: selection.sentence)
        // **The primary is frozen only now, after the panel is up and not before**: a reader whose language
        // has not been derived yet (first lookup after an upgrade or a language change) waits here, bounded,
        // rather than studying from whatever is first in Dictionary.app's order for this one lookup.
        await settle()
        // **The ledger's lemma waits, bounded, for the table the app is still reading at launch** — after the panel
        // is up, so the wait is never blank screen — and is decided again if it arrived. Without it the same word
        // would be keyed one way in the first second of a session and another way after.
        if await FormAuthority.shared.settled(within: .milliseconds(750)) == .timedOut {
            log.notice("lemma: the form table was still loading; this lookup is keyed without it")
        }
        // **Decided again if the table changed since the first reading**, however it got there: a load can finish
        // before the wait begins, which the wait reports as idle.
        if FormAuthority.shared.revision != tableAtFirst {
            lemma = Lemmatizer.lemma(of: selection.text, in: selection.sentence, at: selection.rangeInSentence)
        }
        let chosenPrimary = primary()
        // **What every recording of this lookup shares, worked out once** — the pending row, the
        // answered one and the final one differ only in what they add to it (audit round 3, #29).
        let basis = RecordingBasis(
            selection: selection, lemma: lemma, language: language, requestedAt: requestedAt,
            lookup: existingLookup, keepPolicy: frozenKeepPolicy)
        let pending = basis.pending(primaryDictionary: chosenPrimary.chosen ?? chosenPrimary.automatic)
        // Not awaited, and **deliberately not cancelled with this lookup**: the load runs beside the
        // dictionary lookup, which is the time it has, and a reader who supersedes one lookup with
        // another wants the model that was being loaded for the first. Detached for that reason —
        // structured, it would be torn down by the supersession it is meant to outlive. Nothing
        // waits on it, so no answer depends on its order; the worst case is the sense question
        // loading the model itself.
        Task.detached(priority: .userInitiated) { [prewarm] in await prewarm() }
        // The ledger read starts here too, so what this word cost the reader before is being fetched
        // while the dictionaries are asked rather than after them.
        let history = Task { [priorEncounters] in
            await priorEncounters(lemma.text, requestedAt, language)
        }

        // **The sentence goes with the term**, so the service can answer in one round trip whether the
        // reader is standing inside a phrase their dictionary knows. Sent whatever the capture's quality:
        // a sentence that may be cut can still hold the phrase whole, and a cut that fell inside it simply
        // matches nothing. Nothing on the lookup path may delete a candidate.
        let request = LookupRequest(
            term: selection.text, sentence: selection.sentence,
            termLocation: selection.rangeInSentence?.location,
            termLength: selection.rangeInSentence?.length)
        // **Dated when it arrives**, not when the visibility check below lets it be read.
        async let answer: (LookupResolution?, ContinuousClock.Instant) = { (try? await client.lookup(request), .now) }()
        // A lookup nobody saw is not recorded — not even as the pending row it starts with. A
        // superseded lookup stops waiting for the compositor at once.
        guard let shownAt = await value(of: seen, orOnCancel: { nil }) else {
            reportSeen(false)
            history.cancel()
            return nil
        }
        reportSeen(true)
        mark(.panelShown, ticket.number, shownAt)
        initialRecording(pending, ticket.number)
        let (answered, answeredAt) = await answer
        guard let resolved = answered, panel.isCurrent(ticket) else {
            history.cancel()
            return nil
        }
        mark(.dictionaryAnswered, ticket.number, answeredAt)
        let outcome = resolved.word
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
        // **The phrase's own entries, for the selector to choose against.** Not merged into `entries`:
        // that list is what the card draws and what `primaryEntry` is chosen from, and a phrase's entry
        // appearing there would put *take something into account* in the reader's dictionary switcher as
        // though they had looked it up.
        // **Only where the phrase has an entry of its own**, which is the one measurement that decided this.
        // A sub-entry phrase is answered with its parent, so `hit.entries` would be *account*'s six noun
        // senses under `take something into account` — noise in the candidate set, and a hypothesis the
        // selector could confidently pick. `PhraseHit.entries` is already empty for that case; this says so
        // rather than relying on it.
        let phraseEntries = Self.candidateEntries(of: resolved.phrase)
        // Built here rather than inside the `async let`: the closure that reads the reader's chosen
        // dictionary belongs to this actor and must not travel with the work.
        // **Which entry the card opens on.** Set here, from the same `PrimaryDictionary` the
        // resolver is built with, so the dictionary shown and the dictionary whose sense is
        // resolved and recorded cannot be different ones.
        // `pinned` is that one primary: the card, the first recording and the resolver all ask it, so
        // none of them can settle on a dictionary from a list the others did not see.
        let pinned = chosenPrimary.pinned(word: entries, phrase: phraseEntries)
        // The *reader's* choice is still what is recorded where they made one: automatic keeping
        // compares against it, and a fallback is not a choice.
        // **And it is the study dictionary a phrase is saved in** (ADR-0049): the namespace Review asks, so
        // a phrase card made here is one the reader's sittings can reach.
        let effectivePrimary = chosenPrimary.chosen ?? chosenPrimary.automatic ?? pinned.chosen
        // **Built against the sentence the card holds, not the one that was sent.** The request sends the
        // sentence whatever the capture's quality, while the presentation drops it for an incomplete one —
        // so a span measured against the first and drawn on the second would bracket whatever sits at that
        // offset. `PhrasePresentation.init(_:sentence:)` checks the pairing rather than trusting it.
        presentation.phrase = PhrasePresentation(
            resolved.phrase, sentence: presentation.sentence, studyDictionary: effectivePrimary)
        logPhrase(resolved.phrase)
        presentation.outcome = outcome
        panel.update(.lookup(presentation), for: ticket)

        presentation.primaryEntry = pinned.entries(among: entries).first
            .map { PanelSelection.identity(of: $0) }
        // **The phrase's entries go with it**, so this early row claims no more than the resolver
        // will: a one-sense word inside a phrase is not yet resolved, and automatic keeping must
        // not confirm it before the selector has weighed the two.
        let early = pinned.encounter(among: entries, phrase: phraseEntries, at: requestedAt)
        initialRecording(basis.recording(
            outcome: outcome, abstention: nil, encounter: early, primaryDictionary: effectivePrimary,
            phraseOfEncounter: Self.phrase(owning: early, in: resolved.phrase)), ticket.number)
        let resolver = SenseResolver(primary: pinned, selector: selector)
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
            // **Cancelled with the group.** `history` is a task of its own, which cancelling this
            // child would not reach — a superseded lookup went on waiting for its ledger read.
            group.addTask { .memory(await value(of: history, orOnCancel: { PriorEncounters() })) }
            // **A child of the group, never a `Task` of its own.** An unstructured task does not
            // inherit cancellation, so superseding a lookup left the sense resolver running — and
            // on the model's rung that is the GPU still answering a question nobody is waiting for.
            // `async let` had that property and an earlier version of this merge threw it away by
            // reaching for `Task { }`; a group child has it back, and the group is what allows the
            // two answers to arrive in either order.
            group.addTask {
                .sense(await resolver.resolve(
                    entries: entries, phrase: phraseEntries, sentence: selection.sentence,
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
                    mark(.senseResolved, ticket.number, .now)
                    guard answered.mark != nil, panel.isCurrent(ticket) else { continue }
                    Self.apply(answered, to: &presentation, phrase: resolved.phrase,
                               studyDictionary: effectivePrimary)
                    panel.update(.lookup(presentation), for: ticket)
                }
            }
        }
        // **Recorded even if superseded while the sense was decided**, and on purpose: the entry was
        // already on screen, so this is a lookup the reader made. The rule is "a lookup nobody saw is
        // not recorded", and only the check before the entry was shown can say nobody saw it. What a
        // superseded lookup never showed is the *mark* — and a model's mark is recorded as the
        // hypothesis it is (`chosen_by: model`), not as something the reader confirmed.
        return basis.recording(
            outcome: outcome,
            // **A lookup the reader walked away from did not get declined and did not find no model.**
            // Superseding it cancels this task, and the ladder reports a cancelled run as an abstention
            // like any other — recorded, that is a false model status in the ledger for a question that
            // was never finished being asked.
            abstention: Task.isCancelled ? nil : resolution.abstention,
            encounter: resolution.encounter, primaryDictionary: effectivePrimary,
            phraseOfEncounter: Self.phrase(owning: resolution.encounter, in: resolved.phrase))
    }

    /// **The phrase whose own entry `encounter` is in**, by the inventory's spelling — the hit's, as *Save
    /// This Phrase* keys it — or nil where the encounter is the word's. The reply says which entries are a
    /// phrase's own (ADR-0028), so this is read off it, never inferred.
    nonisolated static func phrase(owning encounter: SenseEncounter?, in phrase: PhraseAnswer) -> String? {
        guard let encounter, case .found(let hits) = phrase else { return nil }
        return hits.first { hit in
            hit.entries.contains { $0.dictionary.key == encounter.dictionary.key && $0.entryKey == encounter.entryID }
        }?.phrase
    }

    /// The card a lookup opens with, before anything has answered.
    private static func presentation(of selection: Selection, lemma: Lemma, request: Int) -> LookupPresentation {
        // The app, and then the most precise thing the app could say about where inside it — which
        // for 12 of the 17 apps measured is nothing at all.
        let source = [selection.place.name, selection.place.label]
            .compactMap { $0 }.filter { !$0.isEmpty }.removingAdjacentDuplicates().joined(separator: " · ")
        var presentation = LookupPresentation(
            request: request, term: selection.text, lemma: lemma, source: source, capture: selection.quality,
            sentence: selection.quality.context == .complete ? selection.sentence : nil, outcome: nil)
        // Kept beside the sentence it indexes: without it the card has to search, and a search
        // finds the wrong occurrence of a word that appears twice.
        presentation.sentenceRange =
            selection.quality.context == .complete ? selection.rangeInSentence : nil
        return presentation
    }

    /// One line about the phrase the reader was standing in, or why there is none.
    private func logPhrase(_ phrase: PhraseAnswer) {
        switch phrase {
        case .found(let hits):
            // The wire does not promise a non-empty list; nothing here traps on one.
            guard let leading = hits.first else { return }
            log.notice("phrase: \(leading.phrase, privacy: .public), gap \(leading.separation.gap, privacy: .public), \(hits.count, privacy: .public) covering, \(hits.reduce(0) { $0 + $1.entries.count }, privacy: .public) entries")
        case .notReady:
            log.notice("phrase: the inventory was still being read")
        case .unavailable:
            // **A fault, not a notice.** This says no dictionary's phrases could be read at all, which will
            // not fix itself on the next lookup — unlike `.notReady`, which resolves in seconds.
            log.fault("phrase: no dictionary's phrases could be read")
        case .none, .notAsked:
            break
        }
    }

    /// **Every phrase's senses, not only the leading one's.** The card draws one, and the selector chooses
    /// among all of them — which is the whole point of the wire carrying more than one. A hit's own
    /// entries, which is empty for a phrase filed inside another word's. **Per entry now, not per hit**:
    /// a phrase with its own entry in one dictionary and a filing in another used to contribute nothing.
    private static func candidateEntries(of phrase: PhraseAnswer) -> [DictionaryEntry] {
        guard case .found(let hits) = phrase else { return [] }
        return hits.flatMap(\.entries)
    }

    /// A decided sense, drawn on the card.
    ///
    /// **Where the winning sense is one of the phrase's, the phrase says so.** The card's entries are the
    /// word's, so `senseOwner` matches none of them and no mark is drawn there — correctly, the reader
    /// was not reading that word. The notice is the only surface that can show it, and showing the
    /// phrase's *first* definition instead would put the wrong meaning under the right phrase.
    ///
    /// **The sense's own entry, and that entry's own phrase.** A key alone is positional in some
    /// dictionaries — `1.1` is in many entries — so it is looked up only in the entry the mark is about;
    /// and where that entry is a phrase other than the leading one, the notice is rebuilt for it rather
    /// than put under the wrong phrase.
    ///
    /// **The sense says whose it is**, so a phrase saved from the card takes it as its answer only where it
    /// is the study dictionary's (ADR-0049) — the resolver's dictionary is not always that one.
    private static func apply(_ answered: SenseResolution, to presentation: inout LookupPresentation,
                              phrase: PhraseAnswer, studyDictionary: String?) {
        guard let mark = answered.mark else { return }
        presentation.sense = mark
        presentation.senseOwner = answered.owner
        if let key = mark.key, let owner = answered.owner, case .found(let hits) = phrase,
           let (index, sense) = phraseSense(key: key, owner: owner, in: hits) {
            if index != hits.startIndex {
                presentation.phrase = PhrasePresentation(
                    .found([hits[index]]), sentence: presentation.sentence, studyDictionary: studyDictionary)
            }
            presentation.phrase?.met = PhrasePresentation.SenseMet(
                definition: sense.definition ?? sense.text,
                isHypothesis: mark.isHypothesis,
                dictionary: hits[index].entries.first { PanelSelection.identity(of: $0) == owner }?.dictionary.key)
        }
    }

    /// The phrase whose own entry the winning sense is in, and the sense — **by the entry the mark is
    /// about, then the key within it**. Nil where the sense is one of the word's, which is the ordinary
    /// case and the answer "you are reading the word". Not `private`: the attribution is tested here.
    nonisolated static func phraseSense(key: String, owner: String, in hits: [PhraseHit]) -> (Int, DictionarySense)? {
        for (index, hit) in hits.enumerated() {
            let owned = hit.entries.filter { PanelSelection.identity(of: $0) == owner }
            if let sense = sense(key, in: owned) { return (index, sense) }
        }
        return nil
    }

    /// The sense `key` names, among `entries`.
    nonisolated private static func sense(_ key: String, in entries: [DictionaryEntry]) -> DictionarySense? {
        for entry in entries {
            for block in entry.blocks {
                if let found = block.senses.first(where: { $0.key == key }) { return found }
            }
        }
        return nil
    }

}

/// What every recording of one lookup shares — the selection, its lemma and language, when it was asked,
/// its script, which row it reopens and the keep policy frozen at the start. **Worked out once**: the
/// pending row, the answered row and the final row were three constructions that each re-derived it,
/// script classification included (audit round 3, #29).
private struct RecordingBasis {
    let selection: Selection
    let lemma: Lemma
    let language: String?
    let requestedAt: Date
    let lookup: LookupIdentity?
    let keepPolicy: LookupKeepPolicy
    /// **The surface, not the sentence.** The filter is about the word the reader looked up; a Chinese
    /// word quoted inside an English sentence is still a Chinese word, and classifying the sentence would
    /// file it under Latin and show it to a reader who asked not to see it. Nil where nothing classifies
    /// — a number, punctuation — which the drawer draws rather than hides.
    let script: ProbeScript?

    init(selection: Selection, lemma: Lemma, language: String?, requestedAt: Date,
         lookup: LookupIdentity?, keepPolicy: LookupKeepPolicy) {
        self.selection = selection
        self.lemma = lemma
        self.language = language
        self.requestedAt = requestedAt
        self.lookup = lookup
        self.keepPolicy = keepPolicy
        script = ProbeScript.dominant(in: selection.text)
    }

    /// The row a lookup starts with, before the dictionaries answer.
    func pending(primaryDictionary: String?) -> LookupRecording {
        LookupRecording(record: record(outcome: .notFound(serviceFailure: nil), abstention: nil).pending(),
                        encounter: nil, lookup: lookup, keepPolicy: keepPolicy,
                        primaryDictionary: primaryDictionary)
    }

    func recording(outcome: LookupOutcome, abstention: Abstention?, encounter: SenseEncounter?,
                   primaryDictionary: String?, phraseOfEncounter: String?) -> LookupRecording {
        LookupRecording(record: record(outcome: outcome, abstention: abstention), encounter: encounter,
                        lookup: lookup, keepPolicy: keepPolicy, primaryDictionary: primaryDictionary,
                        phraseOfEncounter: phraseOfEncounter)
    }

    /// The ledger row — what was read, where, how it was captured, what answered, and why no sense was
    /// marked where none was.
    private func record(outcome: LookupOutcome, abstention: Abstention?) -> LookupRecord {
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
            senseAbstention: abstention, script: script)
    }
}

private extension Array where Element: Equatable {
    /// "Preview · Preview" reads as a stutter; the app's name and its own label can coincide.
    func removingAdjacentDuplicates() -> [Element] {
        reduce(into: []) { kept, next in if kept.last != next { kept.append(next) } }
    }
}
