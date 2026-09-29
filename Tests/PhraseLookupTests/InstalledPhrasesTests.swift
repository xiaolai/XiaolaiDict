import AppleDictionaryFormat
import DictionaryModel
import Foundation
import Synchronization
import Testing

@testable import PhraseLookup

/// **The detector the service actually builds, against the dictionaries on this machine.**
///
/// `PhraseReaderTests` proves the translations against a fixture. This proves what the service wires: that
/// the reader's own dictionaries yield an inventory with **meanings**, that it costs what it is claimed to
/// cost, and that the sentence which raised the whole question is answered.
///
/// Gated on `XIAOLAIDICT_BUNDLES` and prints "not measured" when unset — a green suite is not a suite that
/// ran. Nothing here is committed: the figures are about a licensed dictionary's structure, and the text
/// stays on the reader's own Mac.
@Suite struct InstalledPhrasesTests {
    private static var configured: Bool { ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] != nil }

    /// **The scope, by the predicate ADR-0027 already settled.** A second, wider predicate of this module's
    /// own admitted 34 dictionaries here — including a Korean pair contributing 1 English key out of 28,522.
    @Test func theScopeIsTheDictionariesThisReaderStudiesFrom() {
        guard Self.configured else { print("InstalledPhrasesTests: not measured"); return }
        let all = DictionaryLocator.installed()
        for reader in ["en-US", "zh-Hans", "zh-Hant"] {
            let serving = all.filter { $0.serves(reader: reader) }
            print("IP serves(\(reader)) \(serving.count) of \(all.count) — \(Set(serving.map(\.displayName)).sorted())")
            #expect(serving.count < all.count, "every installed dictionary cannot serve one reader")
            #expect(!serving.isEmpty, "no dictionary serves \(reader) — the phrase feature would find nothing")
        }
    }

    /// **The inventory, with its meanings, and what it costs.**
    ///
    /// Measured 2026-09-29: the body walk is ~7 s for NOAD, against 109 s through `EntryIndexer` — 102 of
    /// those seconds spent on sense keys and hashes a phrase list has no use for. The bound here is generous
    /// and guards the *kind* of cost: a minute means something started walking with the heavy tool again.
    @Test func theInventoryCarriesMeaningsAndIsReadOnce() throws {
        guard Self.configured else { print("InstalledPhrasesTests: not measured"); return }
        let scratch = TemporaryDirectory()
        let store = PhraseInventoryStore(directory: scratch.url)
        let reported = Mutex<[String]>([])
        let reader = PhraseReader.forReader("zh-Hans", store: store) { why in
            reported.withLock { $0.append(why) }
        }
        #expect(reader.isReady == false, "nothing is ready before it is read")

        var started = Date.now
        let cold = reader.read()
        let coldSeconds = Date.now.timeIntervalSince(started)
        for line in reported.withLock({ $0 }) { print("IP \(line)") }
        print("""
            IP cold: \(cold.phrases) phrases, \(cold.explained) explained, \
            \(cold.read.count) read, \(cold.failed.count) unread, \(String(format: "%.1f", coldSeconds))s
            """)
        #expect(reader.isReady)
        #expect(cold.failed.isEmpty, "every dictionary serving this reader must read")
        #expect(cold.phrases > 50_000, "an inventory this small means the keys were not read")
        #expect(cold.explained > 5_000, "the body walk did not happen — no phrase would have a meaning")
        #expect(coldSeconds < 120, "\(coldSeconds)s is the heavy walk, not the narrow one")

        // **Read once.** The second pass reads files instead of bodies, and that is the whole reason the
        // store exists — so it is asserted against the first rather than against a clock.
        started = Date.now
        let warm = PhraseReader.forReader("zh-Hans", store: store).read()
        let warmSeconds = Date.now.timeIntervalSince(started)
        print("IP warm: \(warm.phrases) phrases, \(warm.explained) explained, \(String(format: "%.1f", warmSeconds))s")
        #expect(warm.phrases == cold.phrases, "the stored inventory is not the one that was read")
        #expect(warm.explained == cold.explained)
        #expect(warmSeconds < coldSeconds, "the stored inventory was not used")
    }

    /// **The sentence that raised the question, end to end, with its meaning.**
    @Test func theSentenceThatRaisedTheQuestionIsAnswered() throws {
        guard Self.configured else { print("InstalledPhrasesTests: not measured"); return }
        let scratch = TemporaryDirectory()
        let reader = PhraseReader.forReader("zh-Hans", store: PhraseInventoryStore(directory: scratch.url))
        reader.read()

        let sentence = "take what people think and other possible edge cases all into account"
        let found = reader.phrase(in: sentence, at: NSRange(location: 0, length: 4))
        print("IP \(found.map { "\($0.phrase) | \($0.separation)" } ?? "NO MATCH")")
        #expect(found?.phrase == "take something into account")
        #expect(found?.separation == .marked(9))
        // The half no index and no parser change was needed for.
        let meaning = reader.meaning(of: "take something into account")
        print("IP meaning: \(meaning ?? "«none»")")
        #expect(meaning?.contains("consider") == true, "got \(meaning ?? "nil")")

        // A key-index phrase, which the body walk is not needed for, must still be found.
        let plain = "the review was full of purple passage nobody could follow"
        #expect(reader.phrase(in: plain, at: NSRange(location: 22, length: 6))?.phrase == "purple passage")
    }
}

/// A directory of the test's own. `XiaolaiDictTestSupport` is not linked by this target, and linking it for
/// one class would widen the target to narrow a duplication.
final class TemporaryDirectory {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appending(path: "phrase-lookup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
