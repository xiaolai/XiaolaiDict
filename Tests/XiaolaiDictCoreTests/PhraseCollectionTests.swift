import DictionaryModel
import Foundation
import ReviewKit
import Testing
@testable import XiaolaiDictCore

/// **A phrase the reader saved as a card** — the owner's decision of 2026-10-05, ADR-0049.
///
/// Until then a phrase sense was never a study item: the inventory explained a phrase and keyed
/// nothing. Now the reader may say *save this phrase*, and that one gesture is the only way a phrase
/// becomes a card. What the ledger must hold to is the identity — the dictionary's own spelling, issued
/// by the inventory, never a parent's entry id and never a guess at the spelling — and everything that
/// already reads a note: readiness, the queue, the Library, the review card and the export.
struct PhraseCollectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "2.6")
    private static let other = DictionaryIdentity(name: "Oxford Thesaurus", identifier: "com.apple.dictionary.OT")
    private static let spelling = "take something into account"
    private static let meaning = "consider something along with other factors before reaching a decision"
    private static let sentence = "They took what people thought into account."

    private static func filing(
        parent: String = "m_en_gbus0005190", block: String = "m_en_gbus0005190.081",
        definitions: [String] = [meaning], dictionary: DictionaryIdentity = noad,
        content: String = "2.6:0011223344556677:8899aabbccddeeff"
    ) -> PhraseFiling {
        PhraseFiling(dictionary: dictionary, parentEntryID: parent, blockID: block, definitions: definitions,
                     contentVersion: content, formatVersion: "phrases/6")
    }

    private static func phrase(
        _ spelling: String = spelling, answer: String? = meaning,
        filings: [PhraseFiling] = [filing()], ownEntryKeys: [String] = [], proposal: Bool = false
    ) -> PhraseCollection {
        PhraseCollection(dictionary: noad, spelling: spelling, answer: answer, filings: filings,
                         ownEntryKeys: ownEntryKeys, isProposal: proposal)
    }

    /// A reading of *took*, in the reader's own sentence, captured whole.
    @discardableResult
    private func read(_ ledger: Ledger, _ sentence: String = sentence, surface: String = "took",
                      lemma: String = "take", at when: Date? = nil) throws -> Int {
        try ledger.record(LookupRecord(
            surface: surface, lemma: lemma, context: sentence, lemmaBasis: .tagger, language: "en",
            contextRange: (sentence as NSString).range(of: surface),
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: when ?? now, result: .found, answeredBy: .dictionaryService,
            quality: .accessibility(.accessibilityTextRange, context: .complete), script: .latin))
    }

    private func collect(_ ledger: Ledger, _ phrase: PhraseCollection = phrase(), lookup: Int,
                         at when: Date? = nil) throws -> StudyNote {
        let outcome = try ledger.collectPhrase(phrase, language: "en", lookupID: lookup, at: when ?? now)
        return try #require(outcome.note, "nothing was saved: \(outcome)")
    }

    // MARK: - The note it makes

    /// **Keyed by the dictionary's own spelling, issued by the inventory, in the study dictionary.**
    /// Not the parent word's entry — `account`'s id is already the word *account*'s note (ADR-0029).
    @Test func aSavedPhraseIsANoteKeyedByItsSpellingAndIssuedByTheInventory() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try read(ledger)
        let outcome = try ledger.collectPhrase(Self.phrase(), language: "en", lookupID: lookup, at: now)
        guard case .collected(let note) = outcome else {
            Issue.record("a first save answered \(outcome)")
            return
        }
        #expect(note.target == .phrase(dictionary: Self.noad.key, text: Self.spelling))
        #expect(note.issuer == .inventory, "the spelling came from the phrase inventory, and the note says so")
        #expect(note.language == "en")
        #expect(note.enrollment == .active)
        #expect(note.confirmedAt == now, "the reader asked for this phrase, plainly drawn")
        #expect(try ledger.lookupIDs(evidencing: note.id) == [lookup], "the card has no cue")
        #expect(try ledger.existingCard(of: note.id, prompt: .meaning)?.scheduled.phase == .new,
                "saving is not a review, and the card is new")
        #expect(try ledger.answer(of: note.id)
            == StudyAnswer(origin: .dictionary, text: Self.meaning, dictionaryVersion: "2.6", senseHash: nil),
                "the card reveals the publisher's meaning, marked as theirs")
        #expect(try ledger.readiness(of: note.id) == .ready)
        #expect(try ledger.collectedCount(dictionary: Self.noad.key) == 1, "an explicit save is a collected note")
        // The row keys nothing but the spelling: no entry id, no sense key, ever.
        var columns: [String] = []
        try ledger.run("SELECT entry_id, sense_key, sense_key_kind, phrase_text FROM study_notes",
                       bind: []) { row in columns = try (0..<4).map { try row.text($0) } }
        #expect(columns == ["", "", "", Self.spelling])
    }

    /// **Where the meaning was found is evidence, one locator per filing, and never a key.** A phrase
    /// filed under two parents keeps both — the loss ADR-0028 stopped at the wire must not come back here.
    @Test func everyFilingIsRecordedAsALocatorAndNoneAsAKey() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try read(ledger)
        let second = Self.filing(parent: "m_en_gbus0002222", block: "m_en_gbus0002222.014",
                                 definitions: ["first", "second"])
        let note = try collect(ledger, Self.phrase(filings: [Self.filing(), second]), lookup: lookup)
        // Recorded at one instant, so the ledger's order between them is its id's — compared by parent.
        let locators = try ledger.locators(of: note.id).sorted { $0.parentEntryID > $1.parentEntryID }
        #expect(locators.count == 2)
        #expect(locators.map(\.parentEntryID) == ["m_en_gbus0005190", "m_en_gbus0002222"])
        #expect(locators.map(\.blockID) == ["m_en_gbus0005190.081", "m_en_gbus0002222.014"])
        #expect(locators.allSatisfy { $0.contentVersion == "2.6:0011223344556677:8899aabbccddeeff" })
        #expect(locators.allSatisfy { $0.formatVersion == "phrases/6" })
        #expect(locators.last?.definitions == ["first", "second"], "every definition, as it read")
        #expect(note.target == .phrase(dictionary: Self.noad.key, text: Self.spelling),
                "a block id is where a meaning was found, not the note's name")
    }

    /// **Only the study dictionary's filings are its evidence.** Another dictionary's parent and block,
    /// recorded on this note, would say this dictionary filed the phrase where it did not.
    @Test func anotherDictionarysFilingIsNotThisCardsEvidence() {
        let mixed = PhraseCollection(
            dictionary: Self.noad, spelling: Self.spelling, answer: Self.meaning,
            filings: [Self.filing(), Self.filing(parent: "ot-1", block: "ot-1.1", dictionary: Self.other)],
            ownEntryKeys: [], isProposal: false)
        #expect(mixed.filings.map(\.dictionary) == [Self.noad])
    }

    // MARK: - Once, and said so

    /// **Saving the same phrase again is the same note, and the answer says so.** Read in another
    /// sentence it is one more reading of the card, not a second card — and the first answer stays.
    @Test func savingThePhraseAgainIsOneNoteAndSaysSo() throws {
        let ledger = try Ledger(path: ":memory:")
        let first = try read(ledger)
        let note = try collect(ledger, lookup: first)
        let second = try read(ledger, "Take everything into account.", surface: "Take",
                              at: now.addingTimeInterval(60))
        let again = try ledger.collectPhrase(Self.phrase(answer: "a different gloss"), language: "en",
                                             lookupID: second, at: now.addingTimeInterval(60))
        #expect(again == .alreadyCollected(note), "a second save answered \(again)")
        // And a third, from the same reading, links nothing twice.
        _ = try ledger.collectPhrase(Self.phrase(), language: "en", lookupID: second, at: now.addingTimeInterval(61))

        #expect(try ledger.notes().count == 1, "the same phrase became two notes")
        #expect(try ledger.cards(ofNotes: [note.id], prompt: .meaning).count == 1)
        #expect(try ledger.lookupIDs(evidencing: note.id) == [first, second])
        #expect(try ledger.answer(of: note.id)?.text == Self.meaning, "the first answer stays (ADR-0030)")
        #expect(try ledger.locators(of: note.id).count == 1, "the same filing was recorded twice")
    }

    // MARK: - One phrase, one card (the final closing pass, finding 1)

    /// A meaning of `red herring`'s own entry, kept as automatic keeping keeps the ladder's proposal.
    private func ownEntryMeaning(_ ledger: Ledger, lookup: Int, entry: String = "red-herring-1",
                                 language: String = "en", dictionary: String = noad.key) throws -> StudyNote {
        try #require(try ledger.keep(
            .sense(dictionary: dictionary, entryID: entry, senseKey: "\(entry).2", senseKeyKind: .publisher),
            issuer: .live, language: language, chosenBy: .model,
            answer: StudyAnswer(origin: .dictionary, text: "a clue that is intended to mislead"),
            lookupID: lookup, at: now, source: .automatic))
    }

    private static let redHerring = phrase("red herring", answer: "a clue that is intended to mislead", filings: [],
                                           ownEntryKeys: ["red-herring-1"])

    /// **A phrase whose own entry's meaning is a card already is not made a second.** That card stands for
    /// it, and the save writes nothing — no note, no answer, no locator, and no link, which would make the
    /// phrase's meaning the one the reading's word is kept under.
    @Test func aPhraseWhoseOwnEntrysMeaningIsACardIsNotMadeASecond() throws {
        let ledger = try Ledger(path: ":memory:")
        let first = try read(ledger, "That is a red herring.", surface: "herring", lemma: "herring")
        let kept = try ownEntryMeaning(ledger, lookup: first)
        let second = try read(ledger, "A red herring again.", surface: "herring", lemma: "herring",
                              at: now.addingTimeInterval(60))

        let outcome = try ledger.collectPhrase(Self.redHerring, language: "en", lookupID: second, at: now)
        #expect(outcome == .savedAsItsEntry(kept), "\(outcome)")
        #expect(try ledger.notes().map(\.id) == [kept.id], "one phrase became two cards")
        #expect(try ledger.lookupIDs(evidencing: kept.id) == [first], "the save linked a reading to the meaning")
        #expect(try ledger.answer(of: kept.id)?.text == "a clue that is intended to mislead")
        #expect(try ledger.locators(of: kept.id).isEmpty)
    }

    /// **The entry rung counts too** — a word saved with no meaning chosen is a card for that entry.
    @Test func anOwnEntrySavedAtTheEntryRungStandsForThePhrase() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try read(ledger, "That is a red herring.", surface: "herring", lemma: "herring")
        let word = try #require(try ledger.keep(
            .entry(dictionary: Self.noad.key, entryID: "red-herring-1"), issuer: .live, language: "en",
            chosenBy: nil, answer: nil, lookupID: lookup, at: now, source: .manual))
        #expect(try ledger.collectPhrase(Self.redHerring, language: "en", lookupID: lookup, at: now)
                == .savedAsItsEntry(word))
        #expect(try ledger.notes().count == 1)
    }

    /// **Only the phrase's own entries, in this dictionary and language, stand for it.** Another entry,
    /// another study dictionary, another language: each is another card, and the save makes the phrase's.
    @Test func anotherEntryDictionaryOrLanguageDoesNotStandForThePhrase() throws {
        for (entry, language, dictionary) in [("herring-1", "en", Self.noad.key), ("red-herring-1", "fr", Self.noad.key),
                                              ("red-herring-1", "en", Self.other.key)] {
            let ledger = try Ledger(path: ":memory:")
            let lookup = try read(ledger, "That is a red herring.", surface: "herring", lemma: "herring")
            _ = try ownEntryMeaning(ledger, lookup: lookup, entry: entry, language: language, dictionary: dictionary)
            let outcome = try ledger.collectPhrase(Self.redHerring, language: "en", lookupID: lookup, at: now)
            guard case .collected(let saved) = outcome else {
                Issue.record("\(entry), \(language), \(dictionary): \(outcome)")
                continue
            }
            #expect(saved.target == .phrase(dictionary: Self.noad.key, text: "red herring"))
        }
    }

    /// **A phrase card made before stays the answer**: where both exist — two cards from before this rule —
    /// the save answers with its own card and links the reading, as a second save always did.
    @Test func aPhraseCardAlreadyMadeIsStillTheOneASaveAnswersWith() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try read(ledger, "That is a red herring.", surface: "herring", lemma: "herring")
        guard case .collected(let card) = try ledger.collectPhrase(Self.redHerring, language: "en",
                                                                    lookupID: lookup, at: now) else {
            Issue.record("premise: the first save made the phrase card")
            return
        }
        _ = try ownEntryMeaning(ledger, lookup: lookup)
        let later = try read(ledger, "A red herring again.", surface: "herring", lemma: "herring",
                             at: now.addingTimeInterval(60))
        guard case .alreadyCollected(let again) = try ledger.collectPhrase(
            Self.redHerring, language: "en", lookupID: later, at: now) else {
            Issue.record("the save did not answer with the phrase card it made")
            return
        }
        #expect(again.id == card.id)
        #expect(try ledger.lookupIDs(evidencing: card.id) == [lookup, later])
    }

    /// **A damaged note on the entry is refused, never read past** — skipped, it would look like no card and
    /// a second would be made beside it.
    @Test func aDamagedNoteOnTheOwnEntryIsRefused() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try read(ledger, "That is a red herring.", surface: "herring", lemma: "herring")
        let kept = try ownEntryMeaning(ledger, lookup: lookup)
        try ledger.execute("PRAGMA ignore_check_constraints = ON")
        try ledger.run("UPDATE study_notes SET issuer = 'guesswork' WHERE id = ?",
                       bind: [.text(kept.id.uuidString)]) { _ in }
        try ledger.execute("PRAGMA ignore_check_constraints = OFF")
        #expect(throws: LedgerError.corruptRow("study_notes \(kept.id.uuidString)")) {
            try ledger.collectPhrase(Self.redHerring, language: "en", lookupID: lookup, at: now)
        }
        var notes = 0
        try ledger.run("SELECT COUNT(*) FROM study_notes", bind: []) { notes = $0.integer(0) }
        #expect(notes == 1, "a refused save still wrote a card")
    }

    // MARK: - Refused, loudly, and nothing written

    /// **A spelling the inventory could not have issued is refused.** The inventory lowercases what it
    /// files, trims its labels, and skips anything holding a tab or a newline; a single word is not a
    /// phrase. Anything else is the reader's text or a normalised guess, and keyed by it the same phrase
    /// would become two notes.
    @Test(arguments: [
        "Take something into account", " take something into account", "take something into account ",
        "take\tsomething into account", "take something\ninto account", "take\u{00A0}something into account",
        "account", "", "   ",
    ])
    func aSpellingTheInventoryCouldNotHaveIssuedIsRefused(spelling: String) throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try read(ledger)
        #expect(throws: LedgerError.notAnInventorySpelling(spelling)) {
            try ledger.collectPhrase(Self.phrase(spelling), language: "en", lookupID: lookup, at: now)
        }
        #expect(try ledger.notes().isEmpty, "a refused spelling still wrote a note")
    }

    /// The positive control: spellings the inventory does issue — slots, apostrophes, digits, hyphens, and
    /// the run of spaces a key with its slot word missing carries (71 of 115,128 measured, 2026-10-05).
    @Test(arguments: ["take something into account", "by all accounts", "keep one's head", "24-hour clock",
                      "blow a fuse", "a   and a half"])
    func aSpellingTheInventoryIssuesIsAccepted(spelling: String) {
        #expect(PhraseCollection.isInventorySpelling(spelling))
    }

    /// **A damaged row is refused, never read past.** The phrase's note with an enrollment this build
    /// cannot name would otherwise look absent, and a second note would be written beside it.
    @Test func aDamagedNoteIsRefusedAndNothingIsWritten() throws {
        let ledger = try Ledger(path: ":memory:")
        let note = try collect(ledger, lookup: try read(ledger))
        try ledger.execute("PRAGMA ignore_check_constraints = ON")
        try ledger.run("UPDATE study_notes SET enrollment = 'mislaid' WHERE id = ?",
                       bind: [.text(note.id.uuidString)]) { _ in }
        try ledger.execute("PRAGMA ignore_check_constraints = OFF")
        let later = try read(ledger, at: now.addingTimeInterval(60))
        #expect(throws: LedgerError.corruptRow("study_notes \(note.id.uuidString)")) {
            try ledger.collectPhrase(Self.phrase(), language: "en", lookupID: later, at: now)
        }
        var links = 0
        try ledger.run("SELECT COUNT(*) FROM study_note_lookups", bind: []) { links = $0.integer(0) }
        #expect(links == 1, "a refused save still linked the reading")
    }

    /// **And a damaged answer is refused the same way**, rather than read as no answer and replaced.
    @Test func aDamagedAnswerIsRefused() throws {
        let ledger = try Ledger(path: ":memory:")
        let note = try collect(ledger, lookup: try read(ledger))
        try ledger.execute("PRAGMA ignore_check_constraints = ON")
        try ledger.run("UPDATE study_answers SET origin = 'rumour' WHERE note_id = ?",
                       bind: [.text(note.id.uuidString)]) { _ in }
        try ledger.execute("PRAGMA ignore_check_constraints = OFF")
        #expect(throws: LedgerError.corruptRow("study_answers \(note.id.uuidString)")) {
            try ledger.collectPhrase(Self.phrase(), language: "en",
                                     lookupID: try read(ledger, at: now.addingTimeInterval(60)), at: now)
        }
    }

    /// **A discarded reading saves nothing**, the rule `keep` follows: the reader put the reading away.
    @Test func aDiscardedReadingSavesNothing() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try read(ledger)
        _ = try ledger.changeDisposition(.discarded, lookups: [lookup], operation: UUID())
        let outcome = try ledger.collectPhrase(Self.phrase(), language: "en", lookupID: lookup, at: now)
        #expect(outcome == .readingDiscarded)
        #expect(try ledger.notes().isEmpty)
    }

    /// A reading that is not there is not a discarded one: refused by name.
    @Test func aMissingReadingIsRefusedByName() throws {
        let ledger = try Ledger(path: ":memory:")
        #expect(throws: LedgerError.lookupGone(42)) {
            try ledger.collectPhrase(Self.phrase(), language: "en", lookupID: 42, at: now)
        }
    }

    // MARK: - What may be asked

    /// **The card's standing is what is saved** (ADR-0030). A phrase drawn as a guess — an inferred
    /// split, or a meaning the selector proposed — waits for the reader's agreement; saving it plainly
    /// later is that agreement.
    @Test func aPhraseDrawnAsAGuessIsSavedAsAProposal() throws {
        let ledger = try Ledger(path: ":memory:")
        let note = try collect(ledger, Self.phrase(proposal: true), lookup: try read(ledger))
        #expect(note.confirmedAt == nil)
        #expect(try ledger.readiness(of: note.id) == .needsConfirmation)
        let row = try #require(try ledger.library(LibraryQuery(now: now)).first)
        #expect(row.obstacle == .confirmation, "Confirm is what the Library offers for it")

        let plain = try collect(ledger, lookup: try read(ledger, at: now.addingTimeInterval(60)),
                                at: now.addingTimeInterval(60))
        #expect(plain.id == note.id)
        #expect(plain.confirmedAt == now.addingTimeInterval(60))
        #expect(try ledger.readiness(of: note.id) == .ready)
    }

    /// **No meaning of the study dictionary's on the card is no answer**, never another dictionary's text
    /// signed with this one's name. The card is saved and waits for the reader's own words.
    @Test func aPhraseSavedWithNoMeaningWaitsForAnAnswer() throws {
        let ledger = try Ledger(path: ":memory:")
        let note = try collect(ledger, Self.phrase(answer: nil, filings: []), lookup: try read(ledger))
        #expect(try ledger.answer(of: note.id) == nil)
        #expect(try ledger.readiness(of: note.id) == .needsRepair)
        #expect(try ledger.library(LibraryQuery(now: now)).first?.obstacle == .answer)
        #expect(try ledger.askableNoteIDs().isEmpty)

        try ledger.setReaderAnswer("weigh it up", of: note.id, at: now)
        #expect(try ledger.readiness(of: note.id) == .ready)
    }

    /// **The queue and `readiness(of:)` judge a phrase alike**, in every state it can be in — and the
    /// Library's facts agree with both. The SQL predicate is the one copy of the rule that cannot be
    /// avoided; this is what holds it to the rule for the kind that is new to it.
    @Test func theQueueAndReadinessAgreeAboutPhrases() throws {
        let ledger = try Ledger(path: ":memory:")
        func saved(_ spelling: String, answer: String? = Self.meaning, proposal: Bool = false) throws -> StudyNote {
            try collect(ledger, Self.phrase(spelling, answer: answer, proposal: proposal), lookup: try read(ledger))
        }
        let ready = try saved("take something into account")
        let proposal = try saved("blow a fuse", proposal: true)
        let answerless = try saved("by all accounts", answer: nil)
        let readingless = try saved("keep a tight rein on")
        let archived = try saved("once in a blue moon")
        for id in try ledger.lookupIDs(evidencing: readingless.id) { try ledger.delete(lookup: id) }
        try ledger.setEnrollment(.archived, of: archived.id)

        let bySQL = try ledger.askableNoteIDs()
        var bySwift = Set<UUID>()
        for note in try ledger.notes() where note.enrollment == .active {
            if try ledger.readiness(of: note.id) == .ready { bySwift.insert(note.id) }
        }
        #expect(bySQL == bySwift, "the queue and readiness(of:) disagree about phrases")
        #expect(bySQL == [ready.id])
        for row in try ledger.library(LibraryQuery(now: now)) {
            #expect(row.readiness == (try ledger.readiness(of: row.id)), "the Library judged \(row.word) differently")
        }
        // **The sittings read it**: Review's candidates and a Selected sitting over all five.
        let readyCard = try #require(try ledger.existingCard(of: ready.id, prompt: .meaning))
        let sitting = try ledger.sittingCandidates(dictionary: Self.noad.key, introducedSince: .distantPast)
        #expect(sitting.cards.map(\.id) == [readyCard.id])
        let selected = try ledger.selectedCandidates(
            noteIDs: [ready, proposal, answerless, readingless, archived].map(\.id),
            dictionary: Self.noad.key, introducedSince: .distantPast)
        #expect(selected.queue.cards.map(\.id) == [readyCard.id])
    }

    // MARK: - Where it is shown

    /// **The Library names a phrase by its spelling**, not by the word that was hovered — `took` is not
    /// what the reader saved. Their own sentence is still the row's excerpt.
    @Test func theLibraryNamesAPhraseByItsSpelling() throws {
        let ledger = try Ledger(path: ":memory:")
        _ = try collect(ledger, lookup: try read(ledger))
        let row = try #require(try ledger.library(LibraryQuery(now: now)).first)
        #expect(row.word == Self.spelling, "the Library listed the phrase as \(row.word)")
        #expect(row.excerpt == Self.sentence)
        #expect(row.note.target.kind == .phrase)
    }

    /// **The review card asks the phrase, in the reader's own sentence, and never shows its meaning**
    /// (C2): the front is everything needed to ask and nothing that answers; the back is a separate call.
    @Test func theReviewCardAsksThePhraseAndKeepsItsMeaningForTheBack() throws {
        let ledger = try Ledger(path: ":memory:")
        let note = try collect(ledger, lookup: try read(ledger))
        let card = try #require(try ledger.existingCard(of: note.id, prompt: .meaning))
        let cue = try #require(try ledger.cue(forCard: card.id))
        #expect(cue.word == Self.spelling, "the card asked about \(cue.word), not the phrase")
        #expect(cue.sentence == Self.sentence)
        #expect(cue.target == .phrase(dictionary: Self.noad.key, text: Self.spelling))
        #expect(!String(describing: cue).contains(Self.meaning), "the front carries the answer")
        #expect(try ledger.revealed(cardID: card.id)
            == ReviewAnswer(text: Self.meaning, dictionary: Self.noad.key, origin: .dictionary))
    }

    /// **The publisher's meaning never leaves** (ADR-0036). The phrase goes out under its spelling, with
    /// the reader's sentence, labelled incomplete — and with their own answer once they write one.
    @Test func aPhrasesPublisherMeaningNeverLeaves() throws {
        let ledger = try Ledger(path: ":memory:")
        let note = try collect(ledger, lookup: try read(ledger))
        let labels = StudyExport.Labels(incomplete: "INCOMPLETE", withoutAWord: "NO WORD")
        let export = try ledger.export(dictionary: Self.noad.key)
        let row = try #require(export.rows.first)
        #expect(row.front == Self.spelling)
        #expect(row.sentence == Self.sentence)
        #expect(row.answer == nil, "the dictionary's meaning was exported as the reader's")
        #expect(!export.tabSeparated(labels: labels).contains(Self.meaning))

        try ledger.setReaderAnswer("weigh it up", of: note.id, at: now)
        #expect(try ledger.export(dictionary: Self.noad.key).rows.first?.answer == "weigh it up")
    }

    // MARK: - A phrase is not its reading's word

    /// **A reading is kept under its word, and a phrase saved from it does not take that over.** The
    /// reading projection took the newest note linked to a lookup as the reading's own: a phrase saved
    /// after the word's meaning became what the history card revealed and what the lookup card's status
    /// read — the phrase's meaning under the word, and "Saved" for a word that was not.
    @Test func aReadingIsStillKeptUnderItsWordAfterAPhraseIsSaved() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try read(ledger)
        let word = try ledger.enroll(
            .sense(dictionary: Self.noad.key, entryID: "take-1", senseKey: "take-1.004", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "lay hold of"), lookupID: lookup, at: now)
        _ = try collect(ledger, lookup: lookup, at: now.addingTimeInterval(5))
        let reading = try #require(try ledger.reading(ofLookup: lookup))
        #expect(reading.studyNoteID == word.id, "the phrase took over the reading's own note")
        #expect(reading.studyAnswer == "lay hold of")

        let phraseOnly = try read(ledger, at: now.addingTimeInterval(60))
        _ = try collect(ledger, lookup: phraseOnly, at: now.addingTimeInterval(60))
        #expect(try ledger.reading(ofLookup: phraseOnly)?.studyNoteID == nil,
                "a reading whose word was not saved read as saved")
    }

    /// **A word is still suggested after a phrase from its reading is saved.** The reader took up
    /// *take something into account*, not *take*; reading the phrase as the word's note silenced a word
    /// they have looked up on two days and never saved.
    @Test func aWordIsStillSuggestedAfterAPhraseFromItsReadingIsSaved() throws {
        let ledger = try Ledger(path: ":memory:")
        let first = try read(ledger)
        try read(ledger, "Take your time.", surface: "Take", at: now.addingTimeInterval(86_400 * 2))
        _ = try collect(ledger, lookup: first)
        let found = try ledger.suggestions(limit: 10, language: "en", studying: [.latin])
        #expect(found.map(\.lemma) == ["take"], "saving a phrase silenced its word: \(found.map(\.lemma))")
    }
}
