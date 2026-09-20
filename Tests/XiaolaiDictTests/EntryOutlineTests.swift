import AppKit
@testable import XiaolaiDict
@testable import XiaolaiDictUI
import XiaolaiDictCore
import Testing

/// The panel's sidebar, as decision D1 settled it: dictionary → entry → sense. A dictionary that
/// answered with several records contributes several entries — which is the whole point of the
/// stage that stopped throwing them away.
struct EntryOutlineTests {
    private static func entry(_ dictionary: String, _ headword: String, homograph: String? = nil, term: String? = nil) -> DictionaryEntry {
        DictionaryEntry(
            dictionary: DictionaryIdentity(name: dictionary), headword: headword, lookedUp: term ?? headword,
            html: "<p/>",
            document: EntryDocument(
                isStyled: true, entryID: "\(dictionary).\(headword).\(homograph ?? "-")", homograph: homograph))
    }

    /// NOAD's four *fine* entries nest under NOAD; 牛津's two under 牛津. One level per rung.
    @Test func entriesNestUnderTheirDictionary() {
        let outline = EntryOutline(entries: [
            Self.entry("NOAD", "fine", homograph: "1"),
            Self.entry("NOAD", "fine", homograph: "2"),
            Self.entry("NOAD", "fine", homograph: "3"),
            Self.entry("NOAD", "fine", homograph: "4"),
            Self.entry("牛津英汉汉英词典", "fine"),
            Self.entry("牛津英汉汉英词典", "fine"),
        ])
        #expect(outline.dictionaries.map(\.name) == ["NOAD", "牛津英汉汉英词典"])
        #expect(outline.dictionaries.map { $0.entries.count } == [4, 2])
        #expect(outline.dictionaries[0].entries.map(\.label) == ["fine¹", "fine²", "fine³", "fine⁴"])
    }

    /// Every entry keeps its place in the flat list the outcome carries, so selecting a row in the
    /// tree still names exactly one entry to render.
    @Test func everyEntryKeepsItsFlatIndex() {
        let outline = EntryOutline(entries: [
            Self.entry("A", "x"), Self.entry("B", "y"), Self.entry("B", "z"), Self.entry("C", "w"),
        ])
        #expect(outline.dictionaries.flatMap { $0.entries.map(\.index) } == [0, 1, 2, 3])
        #expect(outline.dictionaries.map(\.name) == ["A", "B", "C"])
    }

    /// A dictionary without homograph numbers gets none invented: 牛津英汉汉英 files each homograph
    /// as its own record and numbers nothing, so both rows read "fine" and the part of speech
    /// tells them apart.
    @Test func noHomographMeansNoInventedOrdinal() {
        let outline = EntryOutline(entries: [Self.entry("牛津", "fine"), Self.entry("牛津", "fine")])
        #expect(outline.dictionaries[0].entries.map(\.label) == ["fine", "fine"])
    }

    /// A marker that is not a plain number is shown as it is, in brackets, rather than mangled into
    /// a superscript that drops characters.
    @Test func anUnexpectedMarkerIsShownPlainly() {
        let outline = EntryOutline(entries: [Self.entry("D", "fine", homograph: "I")])
        #expect(outline.dictionaries[0].entries[0].label == "fine (I)")
    }

    /// The bridge groups a dictionary's records together, but the outline does not depend on it:
    /// a dictionary that somehow appears twice stays two groups rather than silently merging
    /// entries that arrived apart.
    @Test func aDictionaryThatAppearsTwiceStaysTwoGroups() {
        let outline = EntryOutline(entries: [Self.entry("A", "x"), Self.entry("B", "y"), Self.entry("A", "z")])
        #expect(outline.dictionaries.map(\.name) == ["A", "B", "A"])
        #expect(Set(outline.dictionaries.map(\.id)).count == 3, "each group is separately addressable")
    }

    /// The note under a dictionary's name moved to the entry it belongs to: with several entries
    /// per dictionary, "entry for its dictionary form" is a fact about one of them.
    @Test func theMatchNoteBelongsToTheEntry() {
        let outline = EntryOutline(entries: [Self.entry("NOAD", "run", term: "running")])
        #expect(outline.dictionaries[0].entries[0].note == "entry for “run”, its dictionary form")
    }

    @Test func noEntriesIsNoGroups() {
        #expect(EntryOutline(entries: []).dictionaries.isEmpty)
    }
}

/// The third rung of decision D1: senses under their entry.
struct OutlineSenseTests {
    private static func entry(senses: [DictionarySense], dictionary: String = "NOAD") -> DictionaryEntry {
        DictionaryEntry(
            dictionary: DictionaryIdentity(name: dictionary), headword: "hold", lookedUp: "hold", html: "<p/>",
            document: EntryDocument(
                isStyled: true, entryID: "e1", homograph: nil,
                blocks: [SenseBlock(number: 1, partOfSpeech: "noun", senses: senses)]))
    }

    private static func sense(_ ordinal: Int, _ key: String?, _ kind: SenseKeyKind, _ definition: String) -> DictionarySense {
        DictionarySense(
            path: SensePath(block: 1, ordinal: ordinal), key: key, keyKind: kind,
            definition: definition, text: definition)
    }

    @Test func sensesHangUnderTheirEntry() {
        let outline = EntryOutline(entries: [Self.entry(senses: [
            Self.sense(1, "e1.001", .publisher, "grasp"),
            Self.sense(2, "e1.002", .publisher, "the cargo space of a ship"),
        ])])
        let entry = outline.dictionaries[0].entries[0]
        #expect(entry.senses.map(\.label) == ["grasp", "the cargo space of a ship"])
        #expect(entry.senseKeyKind == .publisher)
    }

    /// Every row in the sidebar must be separately addressable, or selecting one would select two.
    @Test func everySenseRowHasItsOwnIdentity() {
        let outline = EntryOutline(entries: [
            Self.entry(senses: [Self.sense(1, "a", .publisher, "x"), Self.sense(2, "b", .publisher, "y")]),
            Self.entry(senses: [Self.sense(1, "a", .publisher, "x")], dictionary: "Other"),
        ])
        let ids = outline.dictionaries.flatMap { $0.entries.flatMap { $0.senses.map(\.id) } }
        #expect(Set(ids).count == ids.count, "two sense rows share an identity: \(ids)")
    }

    /// A selected sense still names its entry: D2 marks a sense, it never jumps to one, so the pane
    /// always has a whole entry to render.
    @Test func aSenseSelectionStillNamesItsEntry() {
        let selection = OutlineSelection.sense(entry: 3, key: "e1.002")
        #expect(selection.entryIndex == 3)
        #expect(selection.senseKey == "e1.002")
        #expect(OutlineSelection.entry(2).senseKey == nil)
    }

    /// A dictionary that cannot key senses shows none, rather than rows it cannot stand behind.
    @Test func anEntryWithNoSensesShowsNoSenseRows() {
        let bare = DictionaryEntry(
            dictionary: DictionaryIdentity(name: "Collins"), headword: "fine", lookedUp: "fine", html: "<p/>",
            document: EntryDocument(isStyled: true, entryID: "_8pm", homograph: nil))
        let entry = EntryOutline(entries: [bare]).dictionaries[0].entries[0]
        #expect(entry.senses.isEmpty)
        #expect(entry.senseKeyKind == SenseKeyKind.none)
    }

    /// A positional sense reads as the weaker claim it is.
    @Test func aPositionalSenseSaysSo() {
        let outline = EntryOutline(entries: [Self.entry(senses: [Self.sense(1, "1.1", .position, "很好的")])])
        #expect(outline.dictionaries[0].entries[0].senses[0].keyKind == .position)
    }
}

/// Found by audit, in the hover paths.
struct HoverAuditTests {
    /// A plain substring search took the first *occurrence*: hovering "he" in "there he stood"
    /// found it inside "there" and re-segmented to the wrong word.
    @Test func awholeWordMatchDoesNotHitInsideAnotherWord() throws {
        let sentence = "there he stood"
        let range = try #require(ScreenWordReader.wholeWordRange(of: "he", in: sentence))
        #expect(range.location == 6, "matched inside 'there' at \(range.location)")
        #expect((sentence as NSString).substring(with: range) == "he")
    }

    @Test func awordThatIsNotThereAsAWholeWordIsNotFound() {
        #expect(ScreenWordReader.wholeWordRange(of: "he", in: "therefore thereafter") == nil)
    }

    @Test func thefirstWholeWordOccurrenceIsTaken() throws {
        let range = try #require(ScreenWordReader.wholeWordRange(of: "the", in: "the cat and the dog"))
        #expect(range.location == 0)
    }

    /// A window moved inside the three-second content cache would crop where it used to be.
    @Test func amovedWindowIsNotTreatedAsTheSameGeometry() {
        let was = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(ScreenTextRecogniser.sameGeometry(was, was))
        // Sub-point rounding between the two APIs is not a move.
        #expect(ScreenTextRecogniser.sameGeometry(was, CGRect(x: 100.4, y: 100, width: 800, height: 600)))
        #expect(!ScreenTextRecogniser.sameGeometry(was, CGRect(x: 140, y: 100, width: 800, height: 600)))
        #expect(!ScreenTextRecogniser.sameGeometry(was, CGRect(x: 100, y: 100, width: 640, height: 600)))
    }

    /// Found by the second verify pass. A capture the recogniser cannot attribute to an app cannot
    /// be checked against the exclusion list, so it must not happen at all — a display-scoped
    /// region could contain a password manager's window and no check would ever see it.
    @Test func anUnattributableCaptureIsRefusedNotChecked() {
        #expect(RecognitionError.unattributable.errorDescription?.isEmpty == false)
        #expect(RecognitionError.excludedApp("Terminal").errorDescription?.contains("Terminal") == true)
    }

    /// Found by the second verify pass: the pointer resting on XiaolaiDict's own panel used to fall
    /// through to the recogniser, which skips XiaolaiDict's windows — and so read whatever the panel was
    /// covering.
    @Test func ourOwnWindowIsItsOwnOutcome() {
        // The case exists and is distinct from "no element here", which *may* still try OCR.
        let ours = ScreenWordReader.TargetOutcome.ourOwnWindow
        if case .ourOwnWindow = ours {} else { Issue.record("the case collapsed into .none") }
    }

    /// The guard must be releasable only by whoever finishes, which is why it is a reference type:
    /// a value copy would let a second hover think it holds one.
    @Test func thecaptureGuardIsHeldUntilReleased() {
        let guardOne = HoverReader.CaptureGuard()
        #expect(guardOne.claim(), "a fresh guard refused its first claimant")
        #expect(guardOne.isHeld)
        #expect(!guardOne.claim(), "a second capture started while one was in flight")
        guardOne.release()
        #expect(!guardOne.isHeld)
        #expect(guardOne.claim())
    }

    // MARK: - The rows the sidebar draws

    /// **One element, one row.** The sidebar is a `List` with `.sidebar` style, which on macOS is
    /// an `NSOutlineView`; a `ForEach` body that emitted an entry *and* its senses trapped
    /// SwiftUI's outline coordinator in `ViewListTree.visitItem` every time the list was rendered.
    /// The flattening is the fix, so the count is what has to hold.
    @Test func everyEntryAndEverySenseIsExactlyOneRow() {
        let outline = EntryOutline(entries: [sampleEntry("NOAD"), sampleEntry("Thesaurus")])
        for dictionary in outline.dictionaries {
            let senses = dictionary.entries.reduce(0) { $0 + $1.senses.count }
            #expect(dictionary.rows.count == dictionary.entries.count + senses)
        }
    }

    /// An entry is followed by its own senses, not by another entry's.
    @Test func eachEntryIsFollowedByItsOwnSenses() throws {
        let outline = EntryOutline(entries: [sampleEntry("NOAD")])
        let rows = try #require(outline.dictionaries.first).rows
        guard case .entry(let first) = rows.first else {
            Issue.record("the first row is not an entry")
            return
        }
        let following = rows.dropFirst().prefix { if case .sense = $0 { true } else { false } }
        #expect(following.count == first.senses.count)
        for (row, sense) in zip(following, first.senses) {
            #expect(row.id == sense.id)
        }
    }

    /// A duplicate id in a `List` is its own crash. Two dictionaries answering with the same entry
    /// — the same publisher ids, the same sense keys — is the ordinary case, not a contrived one.
    @Test func noTwoRowsInTheWholeOutlineShareAnID() {
        let outline = EntryOutline(entries: [sampleEntry("NOAD"), sampleEntry("Thesaurus")])
        let ids = outline.dictionaries.flatMap { $0.rows.map(\.id) }
        #expect(Set(ids).count == ids.count, "the sidebar has duplicate row identities")
    }

    /// The row's identity is what `List` selects by, now that the explicit tags are gone. If it
    /// stopped matching, selection would silently stop working rather than fail.
    @Test func aRowsIdentityIsTheSelectionItStandsFor() throws {
        let outline = EntryOutline(entries: [sampleEntry("NOAD")])
        let rows = try #require(outline.dictionaries.first).rows
        guard case .entry(let entry) = rows.first else {
            Issue.record("the first row is not an entry")
            return
        }
        #expect(rows[0].id == OutlineSelection.entry(entry.index))
    }
}
