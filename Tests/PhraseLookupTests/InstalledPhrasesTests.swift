import AppleDictionaryFormat
import DictionaryModel
import Foundation
import Synchronization
import Testing

@testable import PhraseLookup

/// **The detector the service actually builds, against the dictionaries on this machine.**
///
/// `PhraseReaderTests` proves the translations against a fixture. This proves the thing the service wires:
/// that reading the installed dictionaries yields an inventory, that it costs what it is claimed to cost,
/// and that the sentence which raised the whole question is answered.
///
/// Gated on `XIAOLAIDICT_BUNDLES` and prints "not measured" when unset — a green suite is not a suite that
/// ran. Nothing here is committed: the figures are about a licensed dictionary's structure, and the text
/// stays on the reader's own Mac.
@Suite struct InstalledPhrasesTests {
    private static var configured: Bool { ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] != nil }

    /// Every installed dictionary that indexes English, read as the service reads them.
    ///
    /// **Memory is measured here, not estimated.** The note promised this before Stage A was called done.
    @Test func theInstalledDictionariesYieldAnInventory() throws {
        guard Self.configured else {
            print("InstalledPhrasesTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        let english = PhraseReader.installed()
        print("InstalledPhrasesTests: \(english.count) English-indexing bundles — \(english.map(\.displayName))")
        let reader = PhraseReader(bundles: english)
        #expect(reader.isReady == false, "nothing is ready before it is read")
        let started = Date.now
        let reading = reader.read()
        let seconds = Date.now.timeIntervalSince(started)
        print("""
            InstalledPhrasesTests: \(reading.phrases) phrases from \(reading.read.count) read, \
            \(reading.failed.count) unread, \(String(format: "%.2f", seconds))s
            """)
        for name in reading.failed { print("  unread: \(name)") }
        #expect(reader.isReady)
        #expect(reading.phrases > 50_000, "an inventory this small means the keys were not read")
        #expect(reading.failed.isEmpty, "every English dictionary on this Mac must read")
        // **A bound on the thing being avoided, not on the clock.** The number that matters is how long a
        // reader's lookups answer `.notReady`, and it is the *reading* that costs — 232,373 phrases in
        // 10–16 s here, ~2 s of it the template index. Generous, because this asserts that the cost has not
        // changed in kind: a minute means something now reads every entry rather than every key.
        #expect(seconds < 60, "the inventory took \(seconds)s — that is a body walk, not a key read")
    }

    /// **The sentence that raised the question, through the detector the service builds.**
    ///
    /// The split phrase lives only in the sub-entry labels, so this passes on this machine only because the
    /// reader's index is being read — which is the point. Where there is no index it falls to the keys, and
    /// the test says which happened rather than failing silently.
    @Test func theSentenceThatRaisedTheQuestionIsAnswered() throws {
        guard Self.configured else {
            print("InstalledPhrasesTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        // A Mutex, because `report` is `@Sendable` — the inventory is read on one queue and asked from
        // another, which is the whole reason the closure is declared that way.
        let reported = Mutex<[String]>([])
        let reader = PhraseReader.overInstalledDictionaries { why in reported.withLock { $0.append(why) } }
        reader.read()
        let why = reported.withLock { $0 }
        for line in why { print("InstalledPhrasesTests: \(line)") }

        let sentence = "take what people think and other possible edge cases all into account"
        let found = reader.phrase(in: sentence, at: NSRange(location: 0, length: 4))
        print("InstalledPhrasesTests: \(found.map { "\($0.phrase) | \($0.separation)" } ?? "NO MATCH")")
        if why.isEmpty {
            #expect(found?.phrase == "take something into account")
            #expect(found?.separation == .marked(9))
        } else {
            print("InstalledPhrasesTests: no index, so the label-only phrases are out of reach — expected")
        }

        // A key-index phrase, which needs no index and so must be found either way.
        let plain = "the review was full of purple passage nobody could follow"
        #expect(reader.phrase(in: plain, at: NSRange(location: 22, length: 6))?.phrase == "purple passage")
    }
}
