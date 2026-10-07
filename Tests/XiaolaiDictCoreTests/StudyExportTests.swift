import CaptureModel
import DictionaryModel
import Foundation
import Testing
@testable import XiaolaiDictCore

/// **What leaves this Mac, and what does not.** WI-007's D03/D04.
///
/// One rule dominates: a publisher's gloss never leaves. The index is not distributed and the
/// ledger's `gloss` is local-only; an export is another way out of the machine, and the rule does
/// not weaken because the transport changed.
struct StudyExportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger() throws -> Ledger { try Ledger(path: ":memory:") }

    /// The caller's words for what could not travel. **Not the app's**: Core is tested on what it does
    /// with labels it is given, and the app's own are held to the catalog by `LibraryOrganisationWiringTests`.
    private static let labels = StudyExport.Labels(incomplete: "LABEL-INCOMPLETE", withoutAWord: "LABEL-NO-WORD")

    @discardableResult
    private func save(_ ledger: Ledger, _ word: String, gloss: String,
                      sentence: String? = nil) throws -> StudyNote {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: sentence ?? "A sentence with \(word).",
            lemmaBasis: .tagger, language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        return try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: gloss), lookupID: lookup, at: now)
    }

    /// **The publisher's words do not appear anywhere in the file.** Not in a field, not in a
    /// comment, not in a header.
    @Test func apublishersGlossNeverLeaves() throws {
        let ledger = try ledger()
        let gloss = "PUBLISHERWORDSTHATMUSTNOTTRAVEL"
        try save(ledger, "fine", gloss: gloss)
        let export = try ledger.export(dictionary: nil)
        let text = export.tabSeparated(labels: Self.labels)
        #expect(!text.contains(gloss), "the dictionary's definition reached the export")
        #expect(export.rows.allSatisfy { $0.answer == nil })
    }

    /// **A card with no answer of its own is exported labelled, not dropped and not blank.** The
    /// reader asked for their collection; a short file with no explanation is a worse answer than a
    /// complete one that says what is missing.
    @Test func acardWithoutTheReadersOwnAnswerIsLabelledIncomplete() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine", gloss: "a penalty")
        try save(ledger, "hold", gloss: "a compartment")
        try ledger.setReaderAnswer("the money you pay", of: note.id, at: now)

        let export = try ledger.export(dictionary: nil)
        #expect(export.rows.count == 2, "an incomplete card is still the reader's")
        #expect(export.preview.cards == 2)
        #expect(export.preview.incomplete == 1)
        let text = export.tabSeparated(labels: Self.labels)
        #expect(text.contains("the money you pay"))
        #expect(text.contains(Self.labels.incomplete))
    }

    /// **The external id is first and is ours.** Anki matches its text import on the first field,
    /// so the same file imported twice updates rather than duplicates — and manufacturing one of
    /// Anki's own GUIDs is how a collection acquires duplicates nobody can reconcile.
    @Test func theexternalIdentifierIsFirstAndStable() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine", gloss: "a penalty")
        try ledger.setReaderAnswer("the money", of: note.id, at: now)
        let text = try ledger.export(dictionary: nil).tabSeparated(labels: Self.labels)
        let header = try #require(text.split(separator: "\n").first { $0.hasPrefix("#columns:") })
        #expect(header.hasPrefix("#columns:XiaolaiDictID\t"))
        let row = try #require(text.split(separator: "\n").first { !$0.hasPrefix("#") })
        #expect(row.hasPrefix(note.id.uuidString + "\t"))
    }

    /// **The same collection exports to the same bytes.** A reader comparing two exports is asking
    /// what changed; a reshuffled file answers a different question.
    @Test func theexportIsDeterministic() throws {
        let ledger = try ledger()
        for word in ["fine", "hold", "bank", "spring"] { try save(ledger, word, gloss: "x") }
        #expect(try ledger.export(dictionary: nil).tabSeparated(labels: Self.labels)
            == (try ledger.export(dictionary: nil).tabSeparated(labels: Self.labels)))
    }

    /// Tags travel; they are the reader's own.
    @Test func tagsTravelWithTheCard() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine", gloss: "a penalty")
        try ledger.setReaderAnswer("the money", of: note.id, at: now)
        try ledger.tag(noteID: note.id, "law")
        try ledger.tag(noteID: note.id, "reading")
        let text = try ledger.export(dictionary: nil).tabSeparated(labels: Self.labels)
        #expect(text.contains("law reading"))
    }

    /// A tab inside a sentence would be a column the reader never wrote.
    @Test func atabInsideAfieldCannotMakeAnExtraColumn() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine", gloss: "x", sentence: "He\tpaid\tthe fine.")
        try ledger.setReaderAnswer("the\tmoney", of: note.id, at: now)
        let text = try ledger.export(dictionary: nil).tabSeparated(labels: Self.labels)
        let row = try #require(text.split(separator: "\n").first { !$0.hasPrefix("#") })
        #expect(row.split(separator: "\t", omittingEmptySubsequences: false).count
            == StudyExport.fields.count)
    }

    /// **A card whose reading was deleted still leaves, with everything that is the reader's** (audit-fix
    /// round 3, #9). Deleting a reading keeps the note (ADR-0033), and the word it is filed under came only
    /// from that reading — so the row was skipped, and the reader's own answer and tags with it: a quietly
    /// short file, which ADR-0036 rejected for incomplete cards. It goes out labelled, and counted.
    @Test func acardWhoseReadingWasDeletedLeavesWithItsAnswerAndTags() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine", gloss: "a penalty")
        try ledger.setReaderAnswer("the money you pay", of: note.id, at: now)
        try ledger.tag(noteID: note.id, "law")
        try save(ledger, "hold", gloss: "a compartment")
        try ledger.deleteReading(lookups: try ledger.lookupIDs(evidencing: note.id))

        let export = try ledger.export(dictionary: nil)
        #expect(export.rows.count == 2, "a card whose reading was deleted was dropped from the export")
        let row = try #require(export.rows.first { $0.externalID == note.id.uuidString })
        #expect(row.front == nil, "a word was invented for a card that no longer has one")
        #expect(row.answer == "the money you pay")
        #expect(row.tags == ["law"])
        #expect(export.preview.cards == 2)
        #expect(export.preview.withoutAWord == 1)

        let line = try #require(export.tabSeparated(labels: Self.labels).split(separator: "\n")
            .first { $0.hasPrefix(note.id.uuidString) })
        #expect(line.split(separator: "\t", omittingEmptySubsequences: false)
                == [Substring(note.id.uuidString), "LABEL-NO-WORD", "", "the money you pay", "law"])
    }

    /// **What a row says where something could not travel is the caller's to word** (audit-fix round 3,
    /// #8). Core holds no display text (AGENTS.md, ADR-0025): the English marker that lived here was
    /// written into every export in English, past the catalog. Both labels are the caller's, verbatim,
    /// and each only where its own case holds.
    @Test func theLabelsAreTheCallersAndAppearOnlyWhereTheyApply() throws {
        let ledger = try ledger()
        try save(ledger, "hold", gloss: "a compartment")
        let labels = StudyExport.Labels(incomplete: "标签：未完成", withoutAWord: "UNUSED-NO-WORD")
        let text = try ledger.export(dictionary: nil).tabSeparated(labels: labels)
        let row = try #require(text.split(separator: "\n").first { !$0.hasPrefix("#") })
        let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
        #expect(fields[1] == "hold")
        #expect(fields[3] == "标签：未完成")
        #expect(!text.contains("UNUSED-NO-WORD"), "the no-word label was written for a card that has its word")
    }

    /// The export is scoped to one study namespace, like everything else about study state.
    @Test func theexportIsScopedToOneDictionary() throws {
        let ledger = try ledger()
        try save(ledger, "fine", gloss: "x")
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "A sentence.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        try ledger.enroll(.sense(dictionary: "oxford", entryID: "e1", senseKey: "e1.1",
                                 senseKeyKind: .publisher),
                          issuer: .live, language: "en", chosenBy: .reader,
                          answer: StudyAnswer(origin: .reader, text: "mine"), lookupID: lookup, at: now)
        #expect(try ledger.export(dictionary: "noad").rows.count == 1)
        #expect(try ledger.export(dictionary: nil).rows.count == 2)
    }
}
