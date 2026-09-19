@testable import DictionaryBridge
import Foundation
import XiaolaiDictCore
import Testing

/// Runs the private DictionaryServices API in-process, against the dictionaries installed on this
/// Mac. The app never does that — it goes through the XPC service — but a test that crashes is a
/// loud failure, which is exactly what a test of this API should be.
struct DictionaryBridgeTests {
    @Test func atLeastOneDictionaryIsActive() throws {
        let dictionaries = try DictionaryBridge.activeDictionaries()
        #expect(!dictionaries.isEmpty)
        #expect(dictionaries.allSatisfy { !$0.name.isEmpty })
    }

    @Test func aCommonWordHasRichEntries() throws {
        let lookup = try DictionaryBridge.entries(for: "ephemeral")
        try #require(!lookup.entries.isEmpty)
        #expect(lookup.unreadable.isEmpty, "unreadable: \(lookup.unreadable)")
        for entry in lookup.entries {
            #expect(!entry.dictionary.name.isEmpty)
            #expect(entry.headword.localizedCaseInsensitiveCompare("ephemeral") == .orderedSame, "\(entry.dictionary.name)")
            #expect(entry.match == .exact, "\(entry.dictionary.name)")
            #expect(entry.html.localizedCaseInsensitiveContains("ephemeral"), "\(entry.dictionary.name)")
        }
    }

    /// The panel groups entries under their dictionary, in the order the reader set in
    /// Dictionary.app — so a dictionary's entries are contiguous, and the dictionaries ascend.
    @Test func entriesFollowTheReadersDictionaryOrder() throws {
        let order = try DictionaryBridge.activeDictionaries().map(\.name)
        let answered = try DictionaryBridge.entries(for: "fine").entries.map(\.dictionary.name)
        let positions = answered.compactMap { order.firstIndex(of: $0) }
        #expect(positions.count == answered.count, "every entry names an active dictionary")
        #expect(positions == positions.sorted(), "a dictionary's entries are contiguous and in order")
    }

    /// The defect this stage exists to fix: `.first` of the records a dictionary returns threw
    /// away exactly the entries the reader needed — *hold* the ship's hold, *fine* the penalty
    /// (`dev-docs/study-unit.md` §2). Measured through the private API on this Mac, 2026-09-19.
    @Test(arguments: [("hold", 2, ["m_en_gbus0472970", "m_en_gbus0472980"]),
                      ("fine", 4, ["m_en_gbus0362750", "m_en_gbus0362760",
                                   "m_en_gbus0362770", "m_en_gbus0362780"])])
    func everyRecordOfADictionaryReachesTheReader(term: String, count: Int, ids: [String]) throws {
        let noad = try DictionaryBridge.entries(for: term).entries
            .filter { $0.dictionary.name == "New Oxford American Dictionary" }
        try #require(!noad.isEmpty, "NOAD is not enabled in Dictionary.app on this Mac")
        #expect(noad.count == count)
        #expect(noad.map(\.entryID) == ids)
    }

    /// Not only NOAD: 牛津英汉汉英 files *fine* as two entries as well.
    @Test func anotherDictionaryAlsoReturnsSeveralRecords() throws {
        let oxford = try DictionaryBridge.entries(for: "fine").entries.filter { $0.dictionary.name.contains("牛津") }
        try #require(!oxford.isEmpty, "牛津英汉汉英词典 is not enabled in Dictionary.app on this Mac")
        #expect(oxford.count == 2)
        #expect(oxford.map(\.entryID) == ["e_b-en-zh_hans0013659", "e_b-en-zh_hans0013660"])
    }

    /// The entry id is the homograph distinction, so an entry without one cannot be keyed to a
    /// card. Measured at 100% of 1,406,503 entries in all 15 installed dictionaries.
    @Test(arguments: ["hold", "fine", "surprise", "ephemeral", "running"])
    func everyEntryCarriesANonEmptyEntryID(term: String) throws {
        let entries = try DictionaryBridge.entries(for: term).entries
        try #require(!entries.isEmpty)
        for entry in entries {
            let id = try #require(entry.entryID, "\(entry.dictionary.name) declared no d:entry id for \(term)")
            #expect(!id.isEmpty)
        }
    }

    /// Within one dictionary an entry id is the row's identity; two rows sharing one would merge
    /// two meanings into a single card.
    @Test func entryIDsAreUniqueWithinADictionary() throws {
        let entries = try DictionaryBridge.entries(for: "fine").entries
        let keys = entries.map { "\($0.dictionary.key)\u{1F}\($0.entryID ?? "")" }
        #expect(Set(keys).count == keys.count, "duplicate entry id: \(keys)")
    }

    /// Each entry is a whole document with the dictionary's own stylesheet inlined, so it renders the
    /// way Dictionary.app shows it without reading anything from disk. Sideloaded dictionaries have no
    /// DefaultStyle.css where Apple's keep theirs, so a file-based approach would leave them unstyled.
    @Test func everyEntryIsAStyledDocument() throws {
        for entry in try DictionaryBridge.entries(for: "ephemeral").entries {
            #expect(DictionaryBridge.isStyledDocument(entry.html), "\(entry.dictionary.name) is not a styled XHTML document")
            #expect(entry.html.contains("{"), "\(entry.dictionary.name) has an empty stylesheet")
        }
    }

    /// Found in the panel on the E2E machine: the dictionaries' documents declare only Apple's `d:`
    /// namespace, and parsed as XML a root outside the XHTML namespace is not HTML — the panel
    /// showed each entry as one run of text, stylesheet included. What the service sends must be
    /// XHTML at the root.
    @Test func everyEntryIsXHTMLAtItsRoot() throws {
        for entry in try DictionaryBridge.entries(for: "meeting").entries {
            let root = try #require(entry.html.range(of: #"<html\b[^>]*>"#, options: .regularExpression).map { entry.html[$0] })
            #expect(root.contains(#"xmlns="http://www.w3.org/1999/xhtml""#), "\(entry.dictionary.name): \(root)")
        }
    }

    /// An inflection is answered with whatever headword each installed dictionary chooses — "run"
    /// in some, "running" in others, and which depends on what is installed. What must hold in every
    /// case: each entry names a headword, and its match agrees with it.
    @Test func everyEntrysMatchAgreesWithItsHeadword() throws {
        let entries = try DictionaryBridge.entries(for: "running").entries
        try #require(!entries.isEmpty)
        for entry in entries {
            #expect(entry.match != .headwordUnknown, "\(entry.dictionary.name) reported no headword")
            let exact = entry.headword.lowercased() == "running"
            #expect((entry.match == .exact) == exact, "\(entry.dictionary.name): \(entry.headword) read as \(entry.match)")
            if entry.headword.lowercased() == "run" { #expect(entry.match == .dictionaryForm, "\(entry.dictionary.name)") }
        }
    }

    @Test func gibberishHasNoEntries() throws {
        #expect(try DictionaryBridge.entries(for: "qzxqzxqzxqzx") == DictionaryLookup(entries: [], unreadable: []))
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func aBlankTermIsRefused(term: String) {
        #expect(throws: DictionaryBridgeError.blankTerm) { try DictionaryBridge.entries(for: term) }
    }

    /// The service is the boundary: the app's own length limit is not the only caller's.
    @Test func aPassageIsRefusedBeforeTheFrameworkSeesIt() {
        let passage = String(repeating: "a", count: LookupRequest.maximumLength + 1)
        #expect(throws: DictionaryBridgeError.termTooLong(characters: LookupRequest.maximumLength + 1)) {
            try DictionaryBridge.entries(for: passage)
        }
    }

    @Test func aTermAtTheLimitIsLookedUp() throws {
        _ = try DictionaryBridge.entries(for: String(repeating: "a", count: LookupRequest.maximumLength))
    }

    /// Surrounding whitespace comes with a selection more often than not; it is not part of the word.
    @Test func surroundingWhitespaceIsIgnored() throws {
        let padded = try DictionaryBridge.entries(for: "  ephemeral\n")
        #expect(padded.entries.map(\.dictionary.name) == (try DictionaryBridge.entries(for: "ephemeral")).entries.map(\.dictionary.name))
    }

    /// Overlapping calls — the listener's queue is serial, tests are not — must each get a whole,
    /// correct answer.
    @Test func overlappingLookupsEachGetTheirOwnAnswer() async throws {
        let expected = try DictionaryBridge.entries(for: "ephemeral")
        try await withThrowingTaskGroup(of: DictionaryLookup.self) { group in
            for _ in 0..<8 { group.addTask { try DictionaryBridge.entries(for: "ephemeral") } }
            for try await lookup in group { #expect(lookup == expected) }
        }
    }
}

/// What the styled form promises, checked before an entry is passed on as a confident result.
struct StyledDocumentTests {
    private let xhtml = "http://www.w3.org/1999/xhtml"

    /// The documents as the dictionaries give them lack the XHTML namespace; the service adds it,
    /// and leaves a document that already has it — or has no html root at all — as it was.
    @Test func theXHTMLNamespaceIsAddedWhereMissing() {
        let bare = #"<?xml version="1.0"?><html xmlns:d="urn:d" class="c"><head><style>p { margin: 0 }</style></head><body/></html>"#
        let renderable = DictionaryBridge.renderable(bare)
        #expect(renderable.contains(#"<html xmlns="\#(xhtml)" xmlns:d="urn:d" class="c">"#))
        #expect(DictionaryBridge.isStyledDocument(renderable))
        let declared = #"<html xmlns="\#(xhtml)"><head><style>p { margin: 0 }</style></head><body/></html>"#
        #expect(DictionaryBridge.renderable(declared) == declared)
        #expect(DictionaryBridge.renderable("plain text") == "plain text")
    }

    @Test func aStyledXHTMLDocumentPasses() {
        #expect(DictionaryBridge.isStyledDocument(
            #"<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><style>p { margin: 0 }</style></head><body><d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><p>x</p></d:entry></body></html>"#))
    }

    @Test(arguments: [
        "", "   \n", "ephemeral: lasting a very short time",
        // The bare entry of form 0: no document, no stylesheet.
        #"<d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><p>x</p></d:entry>"#,
        // A document without its stylesheet — or with the element and nothing in it.
        #"<html><body><p>x</p></body></html>"#,
        #"<html><head><style/></head><body><p>x</p></body></html>"#,
        #"<html><head><style>   </style></head><body><p>x</p></body></html>"#,
        // Found by the verifier: a stray brace passed for a stylesheet.
        #"<html><head><style>{</style></head><body><p>x</p></body></html>"#,
        #"<html><head><style>p {}</style></head><body><p>x</p></body></html>"#,
        // Found by the verifier: a rule inside a comment is not a stylesheet.
        #"<html><head><style>/* p { color: red } */</style></head><body><p>x</p></body></html>"#,
        // Found on the E2E machine: outside the XHTML namespace, html, style and body are not HTML,
        // and the whole document renders as one run of text.
        #"<html xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><head><style>p { margin: 0 }</style></head><body><p>x</p></body></html>"#,
        // Malformed: the panel parses entries as XML and would show an error page.
        #"<html><head><style>p{}</style></head><body><p>x</body></html>"#,
    ])
    func anythingElseFails(document: String) {
        #expect(!DictionaryBridge.isStyledDocument(document))
    }
}

/// What the XPC service sends back. Errors become typed values, so the app can tell "nothing found"
/// from "could not look", and why.
struct ServiceReplyTests {
    @Test func aKnownWordAnswersWithEntries() {
        guard case .entries(let entries, let unreadable) = DictionaryBridge.reply(to: LookupRequest(term: "ephemeral")) else {
            Issue.record("expected entries")
            return
        }
        #expect(!entries.isEmpty)
        #expect(unreadable.isEmpty)
    }

    @Test func gibberishAnswersNotFoundNotAFailure() {
        #expect(DictionaryBridge.reply(to: LookupRequest(term: "qzxqzxqzxqzx")) == .notFound)
    }

    @Test func aBlankTermIsAnInvalidRequest() {
        guard case .failure(.invalidRequest(let reason)) = DictionaryBridge.reply(to: LookupRequest(term: "  ")) else {
            Issue.record("expected an invalid-request failure")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("blank"))
    }

    @Test func aPassageIsAnInvalidRequest() {
        let passage = String(repeating: "word ", count: 30)
        guard case .failure(.invalidRequest) = DictionaryBridge.reply(to: LookupRequest(term: passage)) else {
            Issue.record("expected an invalid-request failure")
            return
        }
    }
}

/// Senses, read from the dictionaries actually installed on this Mac. The coverage table of
/// `dev-docs/dictionary-markup.md` §5 is a measurement, and a measurement that is not re-run is a
/// claim: these reproduce it through the live lookup path.
struct SenseCoverageTests {
    private static func entries(_ term: String, from dictionary: String) throws -> [DictionaryEntry] {
        let found = try DictionaryBridge.entries(for: term).entries.filter { $0.dictionary.name.contains(dictionary) }
        try #require(!found.isEmpty, "\(dictionary) is not enabled in Dictionary.app on this Mac")
        return found
    }

    /// NOAD marks every sense with the publisher's own id — 100% of its 111,606 entries.
    @Test func noadSensesCarryPublisherIDs() throws {
        let entries = try Self.entries("fine", from: "New Oxford American")
        #expect(entries.allSatisfy { $0.senseCount > 0 })
        for sense in entries.flatMap(\.senses) {
            #expect(sense.keyKind == .publisher)
            #expect(sense.key?.hasPrefix("m_en_gbus") == true, "not a publisher id: \(sense.key ?? "nil")")
        }
    }

    /// 牛津英汉汉英 spells it `lexid`, and files *hold* as one entry of 49 senses — which is the
    /// entry `study-unit.md` §1 is about: 货舱 is sense 47 of 49, invisible to a word-level unit.
    @Test func oxfordChineseSensesCarryLexids() throws {
        let entries = try Self.entries("hold", from: "牛津")
        #expect(entries.map(\.senseCount) == [49])
        for sense in entries.flatMap(\.senses) {
            #expect(sense.keyKind == .publisher)
            #expect(sense.key?.hasPrefix("b-en-zh_hans") == true, "not a lexid: \(sense.key ?? "nil")")
        }
    }

    /// Numbering restarts per part-of-speech block, so *hold*'s 49 senses are not one run of 49.
    @Test func sensesAreGroupedIntoPartOfSpeechBlocks() throws {
        let entry = try #require(try Self.entries("hold", from: "牛津").first)
        #expect(entry.blocks.count > 1, "49 senses arrived as a single block")
        #expect(entry.blocks.allSatisfy { $0.senses.first?.path.ordinal == 1 }, "ordinals do not restart per block")
        #expect(entry.blocks.compactMap(\.partOfSpeech).count == entry.blocks.count, "a block named no part of speech")
    }

    /// 譯典通 has the sense structure and no ids at all: a weaker claim, and one that says so.
    @Test func aDictionaryWithoutIDsIsKeyedByPosition() throws {
        let entries = try Self.entries("fine", from: "譯典通")
        #expect(entries.allSatisfy { $0.senseCount > 0 })
        #expect(entries.allSatisfy { $0.senseKeyKind == .position })
        for sense in entries.flatMap(\.senses) {
            #expect(sense.keyKind == .position)
            #expect(sense.key == "\(sense.path.block).\(sense.path.ordinal)")
            #expect(!sense.textHash.isEmpty, "a position key with no hash cannot notice a content update")
        }
    }

    /// Cambridge, Merriam-Webster and Longman Activator mark senses with fonts and colours; the
    /// three sideloaded conversions enabled here are the same shape. Entry level only, and never a
    /// claim to know which sense the reader read.
    @Test(arguments: ["Collins COBUILD", "Longman Dictionary", "Oxford Collocation"])
    func aSideloadedConversionHasNoSensesToKey(dictionary: String) throws {
        for entry in try Self.entries("fine", from: dictionary) {
            #expect(entry.senseCount == 0)
            #expect(entry.senseKeyKind == SenseKeyKind.none)
            #expect(entry.entryID != nil, "even an unkeyable entry has an entry id")
        }
    }

    /// A definition is what the reader is shown and what the selector compares against, so an entry
    /// that claims senses must have text in them.
    @Test func everySenseHasTextToShow() throws {
        for entry in try DictionaryBridge.entries(for: "hold").entries {
            for sense in entry.senses {
                #expect(!sense.text.isEmpty, "\(entry.dictionary.name) \(sense.path) has no text")
                #expect(!sense.label.isEmpty)
            }
        }
    }
}

/// What the menu shows beside each dictionary when the reader chooses which one to study from
/// (decision D7). The rung is measured from real entries rather than assumed from the name.
struct DictionaryCapabilityTests {
    @Test func everyEnabledDictionaryIsReported() throws {
        let capabilities = DictionaryBridge.capabilities()
        let active = try DictionaryBridge.activeDictionaries()
        #expect(capabilities.map(\.identity) == active.map(\.identity), "the menu would not match the dictionaries")
        #expect(!capabilities.isEmpty)
    }

    /// The three rungs, measured on this Mac: NOAD and 牛津英汉汉英 carry the publisher's sense ids,
    /// 譯典通 has the structure without ids, and the sideloaded conversions have neither.
    @Test func eachDictionaryReportsTheRungItCanActuallyReach() throws {
        let capabilities = DictionaryBridge.capabilities()
        func rung(_ name: String) throws -> SenseKeyKind {
            let found = try #require(
                capabilities.first { $0.identity.name.contains(name) },
                "\(name) is not enabled in Dictionary.app on this Mac")
            #expect(found.probed, "no probe word was found in \(name), so its rung is a floor not a finding")
            return found.senseKeyKind
        }
        #expect(try rung("New Oxford American") == .publisher)
        #expect(try rung("牛津") == .publisher)
        #expect(try rung("譯典通") == .position)
        #expect(try rung("Collins COBUILD") == SenseKeyKind.none)
    }

    /// A dictionary whose identifier is empty — every sideloaded conversion — is keyed by name, and
    /// marked as having entry ids that do not survive re-import.
    @Test func aSideloadedDictionaryIsKeyedByNameAndSaysSo() throws {
        let capabilities = DictionaryBridge.capabilities()
        let collins = try #require(capabilities.first { $0.identity.name.contains("Collins COBUILD") })
        #expect(collins.identity.identifier == nil)
        #expect(collins.identity.key == "name:\(collins.identity.name)")
        #expect(!collins.identity.hasStableEntryIDs)
        let noad = try #require(capabilities.first { $0.identity.name.contains("New Oxford American") })
        #expect(noad.identity.identifier == "com.apple.dictionary.NOAD")
        #expect(noad.identity.hasStableEntryIDs)
        #expect(noad.identity.version != nil, "no content version, so a sense key has no version to be valid in")
    }

    /// Probed once per process: each probe parses a real entry, and Longman's *hold* is 625 KB.
    ///
    /// Counted, not timed. The old version asserted the second call took under 5 ms, which proves
    /// nothing twice over: the cache is process-wide, so if any other test probed first this one
    /// measured an already-warm cache and passed without exercising anything — and on a loaded
    /// machine a 5 ms bound measures the load instead of the cache.
    @Test func theProbeRunsOnce() {
        let first = DictionaryBridge.capabilities()
        let second = DictionaryBridge.capabilities()
        let runs = DictionaryBridge.probeRuns.withLock { $0 }

        // Process-wide, not a delta across these two calls. Other tests probe in parallel, and the
        // claim is exactly that the probe runs once for the whole process however many callers
        // arrive and in whatever order — which a delta cannot express and timing cannot see.
        #expect(runs == 1, "the probe ran \(runs) times in this process")
        #expect(first == second)
    }
}
