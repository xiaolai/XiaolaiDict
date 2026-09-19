import AppKit
import XiaolaiDictCore

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
    private let priorEncounters: @Sendable (String, Date) async -> PriorEncounters

    init(
        client: DictionaryClient, panel: any LookupPanelPresenting,
        primary: @escaping () -> PrimaryDictionary = { PrimaryDictionaryStore().load() },
        selector: any SenseSelecting = LadderSenseSelector(),
        priorEncounters: @escaping @Sendable (String, Date) async -> PriorEncounters = { _, _ in PriorEncounters() }
    ) {
        self.client = client
        self.panel = panel
        self.primary = primary
        self.selector = selector
        self.priorEncounters = priorEncounters
    }

    /// Shows the panel, asks the dictionaries, fills the panel in.
    ///
    /// Returns the row to record, or nil when the lookup was superseded before its answer arrived —
    /// a lookup nobody saw is not one the reader made, and does not belong in the ledger.
    func run(
        _ selection: Selection, near pointer: NSPoint, requestedAt: Date, ticket: PanelTicket
    ) async -> LookupRecording? {
        let lemma = Lemmatizer.lemma(of: selection.text, in: selection.sentence, at: selection.rangeInSentence)
        // The app, and then the most precise thing the app could say about where inside it — which
        // for 12 of the 17 apps measured is nothing at all.
        let source = [selection.place.name, selection.place.label]
            .compactMap { $0 }.filter { !$0.isEmpty }.removingAdjacentDuplicates().joined(separator: " · ")
        var presentation = LookupPresentation(
            term: selection.text, lemma: lemma, source: source, capture: selection.quality,
            sentence: selection.quality.context == .complete ? selection.sentence : nil, outcome: nil)
        panel.show(.lookup(presentation), near: pointer, for: ticket)

        guard let outcome = try? await client.lookup(selection.text), panel.isCurrent(ticket) else { return nil }
        presentation.outcome = outcome
        panel.update(.lookup(presentation), for: ticket)

        let record = LookupRecord(
            surface: selection.text, lemma: lemma.text, context: selection.sentence ?? selection.text,
            // All four were computed at every lookup and thrown away at the ledger before schema 4.
            lemmaBasis: lemma.basis, language: Lemmatizer.language(of: selection.text, in: selection.sentence),
            contextRange: selection.rangeInSentence, place: selection.place,
            lookedUpAt: requestedAt, result: outcome.result, answeredBy: outcome.answeredBy,
            quality: selection.quality)
        // Which entry, and where it is a fact rather than a guess, which sense.
        //
        // The entry is already on screen with every one of its senses; only the *mark* waits on the
        // selector. That is Stage 1's fill-in pattern again, and no new mechanism was needed for it.
        var entries: [DictionaryEntry] = []
        if case .entries(let found, _) = outcome { entries = Array(found) }
        let resolution = await SenseResolver(primary: primary(), selector: selector).resolve(
            entries: entries, sentence: selection.sentence, context: selection.quality.context,
            partOfSpeech: Lemmatizer.partOfSpeech(
                of: selection.text, in: selection.sentence, at: selection.rangeInSentence),
            at: .now)
        if let mark = resolution.mark, panel.isCurrent(ticket) {
            presentation.sense = mark
            panel.update(.lookup(presentation), for: ticket)
        }
        return LookupRecording(record: record, encounter: resolution.encounter)
    }
}

private extension Array where Element: Equatable {
    /// "Preview · Preview" reads as a stutter; the app's name and its own label can coincide.
    func removingAdjacentDuplicates() -> [Element] {
        reduce(into: []) { kept, next in if kept.last != next { kept.append(next) } }
    }
}
