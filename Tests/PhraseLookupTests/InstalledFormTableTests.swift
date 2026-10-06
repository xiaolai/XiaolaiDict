import AppleDictionaryFormat
import DictionaryModel
import Foundation
import Testing
import XiaolaiDictTestSupport

@testable import PhraseLookup

/// **The table the service builds, against the dictionaries on this machine — and whether it earns its keep.**
///
/// Gated on `XIAOLAIDICT_BUNDLES` and prints "not measured" when unset: a green suite is not a suite that
/// ran, and nothing here is committed because the figures describe licensed dictionaries. The guard that
/// matters is the second test: **the table may add, and may never make a printed form worse.** Measured
/// 2026-10-06, 14,165 forms: the tagger agreed with Oxford's own lemma on 8,970 (63.3%) and with the table
/// in force on 13,834 (97.7%), and the table made none worse.
@Suite struct InstalledFormTableTests {
    private static var configured: Bool { ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] != nil }

    /// Built once for the suite: it is ~30 s cold (two body walks, two thesaurus walks, the content hashes), which is the cost being asserted bounded.
    private static let built: (reading: FormTableReader.Reading, seconds: Double)? = {
        guard configured else { return nil }
        let scratch = TemporaryDirectory()
        let started = Date.now
        let reading = FormTableReader.read(store: FormTableStore(directory: scratch.url))
        return (reading, Date.now.timeIntervalSince(started))
    }()

    @Test func theTableIsBuiltFromTheEnglishDictionariesWithinBound() throws {
        guard let (reading, seconds) = Self.built else { print("InstalledFormTableTests: not measured"); return }
        let table = try #require(reading.table, "no English dictionary yielded a table")
        print("IFT \(table.count) forms from \(reading.read) in \(String(format: "%.1f", seconds))s (idle ~30 s), \(table.encoded().utf8.count) bytes")
        #expect(reading.failed.isEmpty, "unread: \(reading.failed)")
        // A table of a few hundred forms is a walk that stopped finding the markup, and looks exactly like
        // a reader whose words are all the tagger's. Oxford prints ~14 k.
        #expect(table.count > 5_000, "only \(table.count) forms: the extraction stopped matching")
        // **The time is printed, not asserted**: 30 s on an idle Mac and 130–200 s on a loaded one, and a unit test
        // may not assert wall-clock time against an absolute bound.
        // The forms this exists for, and the ones it must never decide.
        #expect(table.entry(for: "swore")?.readings.map(\.lemma) == ["swear"])
        #expect(table.entry(for: "found")?.isOwnHeadword == true, "found is a headword and must be left to the grammar")
    }

    @Test func theTableNeverMakesAPrintedFormWorseAndFixesMost() throws {
        guard let (reading, _) = Self.built, let table = reading.table else { print("InstalledFormTableTests: not measured"); return }
        // The forms are the table's own, so the printed lemma is the oracle.
        let probes: [(form: String, lemmas: Set<String>, partOfSpeech: String)] = table.forms.compactMap { form in
            guard let entry = table.entry(for: form) else { return nil }
            return (form, Set(entry.readings.map(\.lemma)), entry.readings.first?.partOfSpeech ?? "")
        }
        func sentence(_ form: String, _ partOfSpeech: String) -> String {
            switch partOfSpeech {
            case "verb": "She quietly \(form) the thing."
            case "adjective": "It was very \(form) today."
            case "adverb": "She did it \(form) today."
            default: "We talked about the \(form) yesterday."
            }
        }
        var before = 0, after = 0, worse: [String] = []
        for probe in probes {
            let text = sentence(probe.form, probe.partOfSpeech)
            let range = (text as NSString).range(of: probe.form)
            let without = Lemmatizer.lemma(of: probe.form, in: text, at: range, using: nil).text
            let with = Lemmatizer.lemma(of: probe.form, in: text, at: range, using: table).text
            if probe.lemmas.contains(without) { before += 1 }
            if probe.lemmas.contains(with) { after += 1 }
            if probe.lemmas.contains(without), !probe.lemmas.contains(with) { worse.append("\(probe.form): \(without) → \(with)") }
        }
        print("IFT forms \(probes.count): agree before \(before), after \(after), worse \(worse.count)")
        #expect(worse.isEmpty, "the table made printed forms worse: \(worse.prefix(10))")
        #expect(after > before, "the table fixed nothing")
        #expect(Double(after) / Double(max(1, probes.count)) > 0.9, "agreement \(after)/\(probes.count)")
    }

    /// **The regular forms Oxford does not print, measured by leaving the printed ones out.** Each printed form
    /// the tagger fails on is asked of a table holding only the word list: did stripping a suffix find the
    /// lemma Oxford printed? Measured 2026-10-06, after superlatives, patterned irregulars and the tagger-word check: of 5,000, right 4,299, silent 682, wrong 19.
    @Test func detachmentFindsTheLemmaOxfordPrintedAndRarelyAnotherWord() throws {
        guard let (reading, _) = Self.built, let table = reading.table else { print("InstalledFormTableTests: not measured"); return }
        let bare = FormTable(sources: [], forms: [:], ownHeadwords: [], words: table.wordList)
        var failed = 0, right = 0, wrong = 0
        for form in table.forms where !table.wordList.contains(form) {
            guard let entry = table.entry(for: form) else { continue }
            let lemmas = Set(entry.readings.map(\.lemma))
            let text = "We talked about the \(form) yesterday."
            let range = (text as NSString).range(of: form)
            if lemmas.contains(Lemmatizer.lemma(of: form, in: text, at: range, using: nil).text) { continue }
            failed += 1
            let found = Lemmatizer.lemma(of: form, in: text, at: range, using: bare)
            if lemmas.contains(found.text) { right += 1 } else if found.basis == .inferred { wrong += 1 }
        }
        print("IFT detachment: tagger failed \(failed), right \(right), wrong \(wrong); \(table.wordList.count) words")
        #expect(failed > 1_000)
        #expect(Double(right) / Double(max(1, failed)) > 0.8, "right \(right) of \(failed)")
        #expect(Double(wrong) / Double(max(1, right + wrong)) < 0.02, "wrong \(wrong) of \(right + wrong) answers")
    }
}
