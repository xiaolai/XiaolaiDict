import DictionaryModel
import Foundation
import ReviewKit
import XiaolaiDictCore

/// The ledger on disk, owned by one actor so lookups can be recorded from anywhere.
actor LedgerStore {
    private let ledger: Ledger

    /// A ledger at `path`, created if absent. Opening is file and database work — creation, and a
    /// schema migration on the first launch after an update — so call it off the main actor.
    /// Where this store's file is. **Kept**, because erasure has to reach the copies beside it and
    /// a caller guessing the path would guess the reader's own rather than a test's.
    let path: String

    init(path: String) throws {
        self.path = path
        ledger = try Ledger(path: path)
    }

    /// The support directory the ledger lives in, and the file inside it. **Changing either
    /// orphans every reader's history**: the app would open an empty ledger beside the full one,
    /// and an empty ledger is indistinguishable from a working one. `LedgerStoreTests` pins both
    /// as literals so a rename cannot move them quietly.
    static let directoryName = "XiaolaiDict"
    static let fileName = "ledger.sqlite"

    /// `~/Library/Application Support/XiaolaiDict/ledger.sqlite`, created on first use, opened on a
    /// background task whoever calls it. `applicationSupport` is a parameter so it can be opened
    /// against a temporary directory instead of the reader's own.
    static func openDefault(applicationSupport: URL? = nil) async throws -> LedgerStore {
        try await Task.detached(priority: .utility) {
            let root = try applicationSupport ?? FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try LedgerStore(path: directory.appendingPathComponent(fileName).path)
        }.value
    }

    /// The reader's ledger **for an instrument that changes nothing**: opened only if it is there, and
    /// only at this build's schema — never created, never migrated, and never written, because the one
    /// connection is read-only (`Ledger(readingAt:)`). `--reminder-report` opened it through
    /// `openDefault`, which makes one where there is none and upgrades an older one (audit-fix round 1);
    /// then through a version check followed by the writable door, which switched the journal and would
    /// have created or migrated whatever was at the path by the second open (round 2).
    static func openForReading(applicationSupport: URL? = nil) async throws -> LedgerStore {
        try await Task.detached(priority: .utility) {
            let root = try applicationSupport ?? FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let path = root.appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(fileName).path
            // Said by name rather than as SQLite's "unable to open". Not a guard against creation: the
            // read-only open cannot create, whatever is at the path by then.
            guard FileManager.default.fileExists(atPath: path) else { throw NotOpenedForReading.absent(path) }
            return try LedgerStore(readingAt: path)
        }.value
    }

    /// One read-only connection to `path`. Every write through it is refused by SQLite.
    init(readingAt path: String) throws {
        self.path = path
        ledger = try Ledger(readingAt: path)
    }

    /// Why `openForReading` did not open: nothing there. Another schema is `LedgerError.anotherSchema`.
    enum NotOpenedForReading: Error, Equatable {
        case absent(String)
    }

    /// Every dictionary a study note belongs to — what decides whether a reader who never chose has
    /// study progress that a changed default would orphan.
    func studiedDictionaries() throws -> [String] { try ledger.studiedDictionaries() }

    /// What the developer pane shows: how much the ledger holds.
    func developerCounts() throws -> (lookups: Int, notes: Int) {
        try ledger.developerCounts()
    }

    /// **A copy first, then every row.** The copy is timestamped and never replaces an earlier one, so a
    /// clear after a deploy cannot overwrite the only copy of real data with test data.
    func clearForDeveloper(now: Date) throws -> (rows: Int, backup: String) {
        let stamp = DateFormatter.developerStamp.string(from: now)
        let backup = "\(path).dev-before-clear-\(stamp).backup"
        try ledger.backUp(to: backup)
        return (try ledger.clearEveryRow(), backup)
    }

    func deployForDeveloper(now: Date) throws -> TestDataReport { try ledger.deployTestData(now: now) }

    /// What the reader met of this lemma before `before`. Encounters, never meanings.
    ///
    /// **In this language.** English *gift* and German *Gift* share a lemma and are two words; asked
    /// without one, a reader of both is shown the other word's history as this one's.
    func priorEncounters(of lemma: String, before: Date, language: String?) throws -> PriorEncounters {
        try ledger.priorEncounters(of: lemma, before: before, language: language)
    }

    /// The lookup, and the sense it met where that is a fact — in one call, so a sense can never
    /// end up in the ledger without the lookup it belongs to. **Answers the row's identity**, read back
    /// in the same call: everything later said about this reading is checked against it, because its id
    /// alone is reused once the largest is deleted (audit-fix round 2).
    @discardableResult
    func record(_ recording: LookupRecording) throws -> LookupIdentity {
        // One transaction, so a sense that cannot be written takes its lookup with it rather than
        // leaving a row the caller has been told does not exist.
        let id = try ledger.recordForLearning(recording.record, with: recording.encounter,
            policy: recording.keepPolicy, primary: recording.primaryDictionary)
        guard let identity = try ledger.identity(ofLookup: id) else { throw LedgerError.lookupGone(id) }
        return identity
    }

    /// A sense the reader picked, hung off a lookup already recorded — **that** lookup, or nothing.
    /// Kept apart from the model's guesses by `chosenBy`, which is the whole point of that column.
    func record(_ encounter: SenseEncounter, for lookup: LookupIdentity) throws {
        try ledger.holding(lookup) {
            guard !(try ledger.encounters(ofLookup: lookup.id)).contains(encounter) else { return }
            try ledger.record(encounter, for: lookup.id)
        }
    }

    /// What the history drawer shows. Bounded in both directions — a window of days and a cap on
    /// rows — because the drawer is a surface the reader opens often, and a ledger years deep must
    /// never arrive whole on the main actor.
    ///
    /// `studying` is passed through rather than defaulted here, for the reason the ledger makes it
    /// required: a surface that forgot the reader's setting would go on drawing the words they
    /// filtered out, and read as a setting that does nothing.
    func recentLookups(since: Date, limit: Int, studying: Set<ProbeScript>) throws -> [ReadingEntry] {
        try ledger.recentLookups(since: since, limit: limit, studying: studying)
    }

    /// What an encounter enrols as, when it is kept: a keyed sense where the dictionary marks one, the
    /// entry rung where it does not. The answer is the dictionary's own snapshot, which is **local
    /// only**, carried with the version and hash that let a later content update be noticed rather than
    /// silently re-pointing the card.
    private static func studyTarget(of encounter: SenseEncounter) -> StudyTarget {
        let dictionary = encounter.dictionary.key
        return if let key = encounter.senseKey, encounter.senseKeyKind != .none {
            .sense(dictionary: dictionary, entryID: encounter.entryID, senseKey: key,
                   senseKeyKind: encounter.senseKeyKind)
        } else {
            .entry(dictionary: dictionary, entryID: encounter.entryID)
        }
    }

    private static func studyAnswer(of encounter: SenseEncounter) -> StudyAnswer? {
        encounter.gloss.map {
            StudyAnswer(origin: .dictionary, text: $0,
                        dictionaryVersion: encounter.dictionary.version, senseHash: encounter.senseHash)
        }
    }

    /// What is in the way of the meanings that need the reader, by reason — Review's empty state and
    /// the toolbar's count of what Confirm can fix.
    func attentionCounts(dictionary: String?) throws -> StudyAttention { try ledger.attentionCounts(dictionary: dictionary) }
    func eraseReadings(_ ids: [Int]) throws -> Ledger.ErasureReport { try ledger.eraseReadingData(at: path, lookups: ids) }
    // **One reading, by its identity** (audit-fix round 2): what a lookup card says and does about the
    // reading it drew, each checked against that reading's row in the transaction that reads or writes
    // it — `LedgerError.lookupGone` where the id now names another reading, or none.
    func enrich(_ recording: LookupRecording, lookup: LookupIdentity) throws {
        try ledger.holding(lookup) {
            try ledger.resolvePrimary(ofLookup: lookup.id, dictionary: recording.primaryDictionary)
            try ledger.enrichLookup(lookup.id, result: recording.record.result,
                                    answeredBy: recording.record.answeredBy,
                                    abstention: recording.record.senseAbstention)
        }
    }
    func disposition(of lookup: LookupIdentity) throws -> LookupDisposition? {
        try ledger.holding(lookup) { try ledger.disposition(ofLookup: lookup.id) }
    }
    func changeDisposition(_ value: LookupDisposition, of lookup: LookupIdentity,
                           operation: UUID) throws -> DispositionResult {
        try ledger.holding(lookup) { try ledger.changeDisposition(value, lookups: [lookup.id], operation: operation) }
    }
    func reading(of lookup: LookupIdentity) throws -> ReadingEntry? {
        try ledger.holding(lookup) { try ledger.reading(ofLookup: lookup.id) }
    }
    func keep(_ encounter: SenseEncounter, for lookup: LookupIdentity, language: String?,
              source: StudyKeepSource) throws -> StudyNote? {
        try ledger.holding(lookup) { try keep(encounter, for: lookup.id, language: language, source: source) }
    }

    /// What automatic keeping did with a reading's encounter.
    enum AutomaticKeep: Equatable {
        /// Kept as the meaning it is — nil where the reading or its primary refused it, as `keep` answers.
        case kept(StudyNote?)
        /// **The encounter is in the own entry of a phrase the reader saved as a card**: that card stands
        /// for it, and nothing is enrolled (ADR-0049).
        case phraseSaved(StudyNote)
    }

    /// **Automatic keeping, one card for a phrase** (ADR-0049). An encounter is kept as the meaning the ladder
    /// chose, a sense of a phrase's own entry included (ADR-0028) — unless `phrase`, the phrase whose own
    /// entry it is in, is a card the reader saved already. Asked and kept in the one transaction that holds
    /// the reading, so no save can land between the question and the keep.
    func keepAutomatically(_ encounter: SenseEncounter, for lookup: LookupIdentity, language: String?,
                           ownEntryOf phrase: String?) throws -> AutomaticKeep {
        try ledger.holding(lookup) {
            if let phrase, let saved = try ledger.phraseCard(
                phrase, dictionary: encounter.dictionary.key, language: language ?? StudyNote.unknownLanguage) {
                return .phraseSaved(saved)
            }
            return .kept(try keep(encounter, for: lookup.id, language: language, source: .automatic))
        }
    }

    /// **The keep, and then the reading's word-only cards replaced by the meaning it kept — in one
    /// transaction** (R1b, with the reader's option on). A word-only card that cannot be read refuses
    /// both: no meaning is saved over a card it was meant to replace and could not.
    func keepReplacingWordCards(_ encounter: SenseEncounter, for lookup: LookupIdentity, language: String?,
                                source: StudyKeepSource) throws -> (note: StudyNote?, wordCards: WordCardReplacement) {
        try ledger.holding(lookup) {
            guard let note = try keep(encounter, for: lookup.id, language: language, source: source) else {
                return (nil, .nothing)
            }
            return (note, try ledger.replaceWordCards(onLookup: lookup.id, with: note.id, at: .now))
        }
    }

    /// **A phrase the reader saved as a card, linked to the reading it was saved from** — checked against
    /// that reading's row in the transaction that writes it, like every other write a lookup card makes.
    /// An unrecorded language is `unknown`, as a saved meaning's is.
    func collectPhrase(_ phrase: PhraseCollection, for lookup: LookupIdentity,
                       language: String?) throws -> PhraseCollectOutcome {
        try ledger.holding(lookup) {
            try ledger.collectPhrase(phrase, language: language ?? StudyNote.unknownLanguage,
                                     lookupID: lookup.id, at: .now)
        }
    }

    func changeDisposition(_ value: LookupDisposition, lookups: [Int], operation: UUID) throws -> DispositionResult {
        try ledger.changeDisposition(value, lookups: lookups, operation: operation)
    }
    func undoDisposition(operation: UUID) throws -> DispositionResult { try ledger.undoDisposition(operation: operation) }
    func reading(ofLookup id: Int) throws -> ReadingEntry? { try ledger.reading(ofLookup: id) }
    func readingArchive(_ query: ReadingArchiveQuery) throws -> [ReadingEntry] { try ledger.readingArchive(query) }
    func readingArchiveCount(_ query: ReadingArchiveQuery) throws -> Int { try ledger.readingArchiveCount(query) }
    func backfillKeptDrafts(limit: Int) throws -> Int { try ledger.backfillKeptDrafts(limit: limit) }
    func keep(_ encounter: SenseEncounter, for lookup: Int, language: String?, source: StudyKeepSource) throws -> StudyNote? {
        try ledger.keep(Self.studyTarget(of: encounter), issuer: .live, language: language ?? StudyNote.unknownLanguage,
            chosenBy: encounter.chosenBy, answer: Self.studyAnswer(of: encounter), lookupID: lookup, at: .now, source: source)
    }
    func keepHistory(_ id: Int) throws -> StudyNote? {
        guard let row = try ledger.reading(ofLookup: id), let encounter = try ledger.preferredEvidence(ofLookup: id) else { return nil }
        return try keep(encounter, for: id, language: row.language, source: .manual)
    }

    // MARK: - Review

    /// What a Review sitting is planned from: every card of every askable note and today's
    /// introductions, read in one call so no write lands between the two.
    func sittingCandidates(dictionary: String?, introducedSince dayStart: Date) throws -> SittingCandidates {
        try ledger.sittingCandidates(dictionary: dictionary, introducedSince: dayStart)
    }

    /// What a Selected sitting is planned from: the same read, the reader's choice beside it, and which
    /// of the chosen notes belong to another study dictionary — in one call, so no write lands between.
    func selectedCandidates(noteIDs: [UUID], dictionary: String?,
                            introducedSince dayStart: Date) throws -> SelectedCandidates {
        try ledger.selectedCandidates(noteIDs: noteIDs, dictionary: dictionary, introducedSince: dayStart)
    }

    /// Today's introductions — the allowance spent so far — for a surface that must count as a sitting
    /// would without drawing one: the Library's Review Selected.
    func introductions(since dayStart: Date, dictionary: String?) throws -> Int {
        try ledger.introductions(since: dayStart, dictionary: dictionary)
    }

    /// **"Not today."** Out of the way until `when`, with the schedule untouched — the reader
    /// saying "not this one, not now" is not the reader saying anything about their memory.
    func postpone(cardID: UUID, until when: Date?) throws {
        try ledger.postpone(cardID: cardID, until: when)
    }

    func practisableCards(limit: Int, dictionary: String?) throws -> [StudyCard] {
        try ledger.practisableCards(limit: limit, dictionary: dictionary)
    }

    @discardableResult
    func practise(cardID: UUID, _ grade: Grade, eventID: UUID, at when: Date) throws -> ReviewEvent {
        try ledger.practise(cardID: cardID, grade, eventID: eventID, at: when)
    }

    /// The cards the reader keeps failing — R09's rule, the Struggling filter's own — which the end of a
    /// review sitting names where this sitting forgot them too. **A read**: nothing is paused or
    /// rescheduled by asking.
    func repeatedlyLapsed(dictionary: String?) throws -> [UUID] {
        try ledger.repeatedlyLapsed(dictionary: dictionary)
    }

    func queueCounts(at when: Date, dictionary: String?, newAllowance: Int,
                     dayStart: Date) throws -> QueueCounts {
        try ledger.queueCounts(at: when, dictionary: dictionary, newAllowance: newAllowance,
                               dayStart: dayStart)
    }

    /// Whether the reader has saved anything at all. **A different nothing** from having nothing due,
    /// and the review window says so differently.
    func anyNotes(dictionary: String? = nil) throws -> Bool {
        try ledger.collectedCount(dictionary: dictionary) > 0
    }

    /// The front of a card, and — separately, only when asked — its back.
    func cue(forCard id: UUID) throws -> ReviewCue? {
        try ledger.cue(forCard: id)
    }

    func revealed(cardID: UUID) throws -> ReviewAnswer? {
        try ledger.revealed(cardID: cardID)
    }

    /// One grade, committed with its event or not at all. The scheduler is built here rather than
    /// passed in: a caller choosing its own retention would be choosing the reader's, silently.
    @discardableResult
    func grade(cardID: UUID, _ grade: Grade, eventID: UUID, expectedRevision: Int,
               at when: Date) throws -> ReviewEvent {
        try ledger.grade(cardID: cardID, grade, eventID: eventID,
                         expectedRevision: expectedRevision, at: when,
                         using: try MemoryScheduler())
    }

    @discardableResult
    func undoLatestReview(ofCard cardID: UUID, at when: Date) throws -> ReviewEvent {
        try ledger.undoLatestReview(ofCard: cardID, at: when)
    }

    /// What revision a card is at now. **Read after an undo**, which is a write and moves it — the
    /// session cannot know the new number and a grade committed against the old one is refused.
    func revision(ofCard cardID: UUID) throws -> Int? {
        try ledger.card(id: cardID)?.revision
    }

    /// Why a card can no longer be asked now, or nil where it can — what a grade's eligibility check would
    /// refuse, by name. What a sitting asks before it shows a card, and after a grade is refused.
    func departure(ofCard cardID: UUID, at when: Date) throws -> Departure? {
        try ledger.departure(ofCard: cardID, at: when)
    }

    // MARK: - Library

    func library(_ query: LibraryQuery) throws -> [LibraryRow] { try ledger.library(query) }
    func libraryCount(_ query: LibraryQuery) throws -> Int { try ledger.libraryCount(query) }
    func answers(of ids: [UUID]) throws -> [UUID: StudyAnswer] { try ledger.answers(of: ids) }
    func setPaused(_ paused: Bool, ofNotes ids: [UUID]) throws {
        try ledger.setPaused(paused, ofNotes: ids)
    }
    func setEnrollment(_ enrollment: StudyEnrollment, ofNotes ids: [UUID]) throws {
        try ledger.setEnrollment(enrollment, ofNotes: ids)
    }
    func removeFromStudy(_ ids: [UUID]) throws { try ledger.removeFromStudy(ids) }

    /// **The other deletion** (ADR-0033). *Remove from study* keeps every lookup; this keeps the
    /// note and takes the readings, leaving it `needsRepair`. Both exist in the ledger; only the
    /// first had a control, so the reader could not tidy their reading without losing the card.
    func deleteReading(ofNotes ids: [UUID]) throws {
        var lookups: [Int] = []
        for id in ids { lookups += try ledger.lookupIDs(evidencing: id) }
        try ledger.deleteReading(lookups: lookups)
    }

    func restorePauseStates(_ states: [UUID: Bool]) throws { try ledger.restorePauseStates(states) }
    func restoreEnrollments(_ dispositions: [UUID: StudyEnrollment]) throws {
        try ledger.restoreEnrollments(dispositions)
    }

    /// Reads what a bulk pause is about to change **and changes it, without leaving the actor**,
    /// so putting it back restores what was there rather than the inverse of what was done.
    ///
    /// The model did these as two `await`s, so another operation could write between them and
    /// the undo it recorded described a state that had already gone. One hop, one answer.
    func pauseAndRemember(_ paused: Bool, ofNotes ids: [UUID]) throws -> [UUID: Bool] {
        let before = try ledger.pauseStates(ofCardsUnder: ids)
        try ledger.setPaused(paused, ofNotes: ids)
        return before
    }

    /// The same for archiving.
    func setEnrollmentAndRemember(_ enrollment: StudyEnrollment,
                                  ofNotes ids: [UUID]) throws -> [UUID: StudyEnrollment] {
        let before = try ledger.enrollments(ofNotes: ids)
        try ledger.setEnrollment(enrollment, ofNotes: ids)
        return before
    }
    /// Confirms one note and, where `hidden` is given, hides its card — the cooldown experiment's write.
    /// Nil is a plain confirmation.
    func confirm(noteID: UUID, at when: Date, hidingCardsUntil hidden: Date?) throws {
        try ledger.confirm(noteID: noteID, at: when, hidingCardsUntil: hidden)
    }
    func confirm(noteIDs ids: [UUID], at when: Date) throws {
        try ledger.confirm(noteIDs: ids, at: when)
    }
    func tag(noteIDs ids: [UUID], _ tag: String) throws { try ledger.tag(noteIDs: ids, tag) }
    /// The reader's own words, replacing what the card reveals. The encounter's `gloss` — the
    /// publisher's snapshot — is untouched, so the evidence stays what it was when it was saved.
    func setReaderAnswer(_ text: String, of noteID: UUID, at when: Date) throws {
        try ledger.setReaderAnswer(text, of: noteID, at: when)
    }
    func untag(noteID: UUID, _ tag: String) throws { try ledger.untag(noteID: noteID, tag) }
    func timeline(of noteID: UUID) throws -> NoteTimeline { try ledger.timeline(of: noteID) }
    func tags(of noteID: UUID) throws -> [String] { try ledger.tags(of: noteID) }
    func allTags() throws -> [(tag: String, count: Int)] { try ledger.allTags() }
    func ignoredSuggestions() throws -> [IgnoredLemma] { try ledger.ignoredSuggestions() }
    func unignoreSuggestion(lemma: String, language: String) throws {
        try ledger.unignoreSuggestion(lemma: lemma, language: language)
    }
    func retention(dictionary: String?) throws -> Ledger.RetentionReport {
        try ledger.retention(dictionary: dictionary)
    }
    func suggestions(limit: Int, language: String?,
                     studying: Set<ProbeScript>) throws -> [Ledger.Suggestion] {
        try ledger.suggestions(limit: limit, language: language, studying: studying)
    }
    func export(dictionary: String?) throws -> StudyExport { try ledger.export(dictionary: dictionary) }

    /// **"Already know" is a declaration about a word, not a measurement of it.** No note is made
    /// — a declaration is not a card (ADR-0036) — only a row naming the lemma and its language,
    /// which is what stops the word being suggested and what `unignoreSuggestion` takes back.
    ///
    /// The previous sentence here said a note *was* made and set aside. It never was, and a
    /// comment describing a design the code does not have is worse than none.
    func ignoreSuggestion(lemma: String, language: String, at when: Date) throws {
        try ledger.ignoreSuggestion(lemma: lemma, language: language, at: when)
    }

    /// **This store's own path, never the caller's idea of it.** Both of these delete rows from
    /// *this* ledger and copies from beside whatever path they are handed, so a mismatched
    /// argument would erase one reader's rows and another ledger's backups. Every caller passed
    /// the right thing; the type no longer lets them pass the wrong one.
    func readingErasureImpact() throws -> (lookups: Int, notesLeftWithoutACue: Int, backups: Int) {
        try ledger.readingErasureImpact(at: path)
    }

    func eraseReadingData() throws -> Ledger.ErasureReport {
        try ledger.eraseReadingData(at: path)
    }

    /// The newest lookup's id, for an instrument that has to put back exactly what it added.
    func newestLookupID() throws -> Int { try ledger.newestLookupID() }

    /// Removes every lookup above `baseline`. **An instrument's own rows**, identified by an id
    /// it took before it wrote any.
    func deleteLookups(after baseline: Int) throws { try ledger.deleteLookups(after: baseline) }
}

private extension DateFormatter {
    /// `20261005-195500`: sorts as time does, and has no character a file name refuses.
    static let developerStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
