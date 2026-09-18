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
            #expect(!entry.dictionary.isEmpty)
            #expect(entry.headword.localizedCaseInsensitiveCompare("ephemeral") == .orderedSame, "\(entry.dictionary)")
            #expect(entry.match == .exact, "\(entry.dictionary)")
            #expect(entry.html.localizedCaseInsensitiveContains("ephemeral"), "\(entry.dictionary)")
        }
    }

    /// The panel shows one pane per dictionary, in the order the reader set in Dictionary.app.
    @Test func entriesFollowTheReadersDictionaryOrder() throws {
        let order = try DictionaryBridge.activeDictionaries().map(\.name)
        let answered = try DictionaryBridge.entries(for: "ephemeral").entries.map(\.dictionary)
        #expect(Set(answered).count == answered.count, "one entry per dictionary")
        let positions = answered.compactMap { order.firstIndex(of: $0) }
        #expect(positions == positions.sorted())
        #expect(positions.count == answered.count, "every entry names an active dictionary")
    }

    /// Each entry is a whole document with the dictionary's own stylesheet inlined, so it renders the
    /// way Dictionary.app shows it without reading anything from disk. Sideloaded dictionaries have no
    /// DefaultStyle.css where Apple's keep theirs, so a file-based approach would leave them unstyled.
    @Test func everyEntryIsAStyledDocument() throws {
        for entry in try DictionaryBridge.entries(for: "ephemeral").entries {
            #expect(DictionaryBridge.isStyledDocument(entry.html), "\(entry.dictionary) is not a styled XHTML document")
            #expect(entry.html.contains("{"), "\(entry.dictionary) has an empty stylesheet")
        }
    }

    /// An inflection is answered with whatever headword each installed dictionary chooses — "run"
    /// in some, "running" in others, and which depends on what is installed. What must hold in every
    /// case: each entry names a headword, and its match agrees with it.
    @Test func everyEntrysMatchAgreesWithItsHeadword() throws {
        let entries = try DictionaryBridge.entries(for: "running").entries
        try #require(!entries.isEmpty)
        for entry in entries {
            #expect(entry.match != .headwordUnknown, "\(entry.dictionary) reported no headword")
            let exact = entry.headword.lowercased() == "running"
            #expect((entry.match == .exact) == exact, "\(entry.dictionary): \(entry.headword) read as \(entry.match)")
            if entry.headword.lowercased() == "run" { #expect(entry.match == .dictionaryForm, "\(entry.dictionary)") }
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
        #expect(padded.entries.map(\.dictionary) == (try DictionaryBridge.entries(for: "ephemeral")).entries.map(\.dictionary))
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
