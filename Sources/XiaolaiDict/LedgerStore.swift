import DictionaryModel
import Foundation
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

    /// What the reader met of this lemma before `before`. Encounters, never meanings.
    ///
    /// **In this language.** English *gift* and German *Gift* share a lemma and are two words; asked
    /// without one, a reader of both is shown the other word's history as this one's.
    func priorEncounters(of lemma: String, before: Date, language: String?) throws -> PriorEncounters {
        try ledger.priorEncounters(of: lemma, before: before, language: language)
    }

    /// The lookup, and the sense it met where that is a fact — in one call, so a sense can never
    /// end up in the ledger without the lookup it belongs to.
    @discardableResult
    func record(_ recording: LookupRecording) throws -> Int {
        // One transaction, so a sense that cannot be written takes its lookup with it rather than
        // leaving a row the caller has been told does not exist.
        try ledger.record(recording.record, with: recording.encounter)
    }

    /// A sense the reader picked, hung off a lookup already recorded. Kept apart from the model's
    /// guesses by `chosenBy`, which is the whole point of that column.
    func record(_ encounter: SenseEncounter, for lookup: Int) throws {
        try ledger.record(encounter, for: lookup)
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

    /// **The reader asked to study this meaning.** Separate from meeting it: an encounter is something
    /// reading produces, an enrollment is something the reader decides, and the ledger keeps them apart.
    ///
    /// The target is built from the encounter, so what is enrolled is exactly what was on screen — a
    /// keyed sense where the dictionary marks one, the entry rung where it does not. The answer is the
    /// dictionary's own snapshot, which is **local only**, carried with the version and hash that let a
    /// later content update be noticed rather than silently re-pointing the card.
    @discardableResult
    func enroll(_ encounter: SenseEncounter, for lookup: Int, language: String?,
                at when: Date) throws -> StudyNote {
        let dictionary = encounter.dictionary.key
        let target: StudyTarget =
            if let key = encounter.senseKey, encounter.senseKeyKind != .none {
                .sense(dictionary: dictionary, entryID: encounter.entryID, senseKey: key,
                       senseKeyKind: encounter.senseKeyKind)
            } else {
                .entry(dictionary: dictionary, entryID: encounter.entryID)
            }
        let answer = encounter.gloss.map {
            StudyAnswer(origin: .dictionary, text: $0,
                        dictionaryVersion: encounter.dictionary.version, senseHash: encounter.senseHash)
        }
        return try ledger.enroll(
            target, issuer: .live, language: language ?? StudyNote.unknownLanguage,
            chosenBy: encounter.chosenBy, answer: answer, lookupID: lookup, at: when)
    }

    // MARK: - Review

    /// The batch a sitting is offered, and how much did not fit. **Two calls, both in SQL**: a count
    /// taken by subtracting what fitted from what the surface guessed would be wrong the moment a
    /// card became due between them.
    func dueCards(at when: Date, limit: Int, dictionary: String?,
                  newAllowance: Int, dayStart: Date) throws -> [StudyCard] {
        try ledger.dueCards(at: when, limit: limit, dictionary: dictionary,
                            newAllowance: newAllowance, dayStart: dayStart)
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

    func queueCounts(at when: Date, dictionary: String?, newAllowance: Int,
                     dayStart: Date) throws -> QueueCounts {
        try ledger.queueCounts(at: when, dictionary: dictionary, newAllowance: newAllowance,
                               dayStart: dayStart)
    }

    /// Whether the reader has saved anything at all. **A different nothing** from having nothing due,
    /// and the review window says so differently.
    func anyNotes() throws -> Bool {
        try !ledger.notes().isEmpty
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

    /// What a bulk action is about to change, read before it changes it — so putting it back
    /// restores what was there rather than the inverse of what was done.
    func pauseStates(ofNotes ids: [UUID]) throws -> [UUID: Bool] {
        try ledger.pauseStates(ofNotes: ids)
    }
    func restorePauseStates(_ states: [UUID: Bool]) throws { try ledger.restorePauseStates(states) }
    func enrollments(ofNotes ids: [UUID]) throws -> [UUID: StudyEnrollment] {
        try ledger.enrollments(ofNotes: ids)
    }
    func restoreEnrollments(_ dispositions: [UUID: StudyEnrollment]) throws {
        try ledger.restoreEnrollments(dispositions)
    }
    func confirm(noteID: UUID, at when: Date) throws { try ledger.confirm(noteID: noteID, at: when) }
    func confirm(noteIDs ids: [UUID], at when: Date) throws {
        try ledger.confirm(noteIDs: ids, at: when)
    }
    func tag(noteIDs ids: [UUID], _ tag: String) throws { try ledger.tag(noteIDs: ids, tag) }
    /// The reader's own words, replacing what the card reveals. The encounter's `gloss` — the
    /// publisher's snapshot — is untouched, so the evidence stays what it was when it was saved.
    func setReaderAnswer(_ text: String, of noteID: UUID, at when: Date) throws {
        try ledger.setReaderAnswer(text, of: noteID, at: when)
    }
    func tag(noteID: UUID, _ tag: String) throws { try ledger.tag(noteID: noteID, tag) }
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

    /// A lookup the reader did not mean to make. The senses met in it go with it.
    func delete(lookup id: Int) throws {
        try ledger.delete(lookup: id)
    }
}
