import CaptureModel
import DictionaryModel
import Foundation
import Testing
import XiaolaiDictCore
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **What the window tests share**, in one place.
///
/// Three copies of `settle` and two of the scratch-file cleanup had already drifted: the polling
/// bounds were 400 iterations in two of them and 2,000 in the third, so the same test was patient
/// in one suite and not in another, and nobody had decided which. A fixture with two spellings is
/// two fixtures.
enum Wiring {
    /// A scratch ledger path, and the cleanup that removes it **with everything beside it** — its
    /// write-ahead log, and the backups a migration takes. A ledger separated from its sidecars is the
    /// shape this project already has a rule about.
    static func scratch(_ label: String) -> (path: String, clean: () -> Void) {
        let path = ScratchFile.path(label)
        return (path, { ScratchFile.remove(path) })
    }

    /// Somewhere disposable for an export. **Never the reader's Downloads folder**, which a test
    /// once wrote into and then deleted from.
    static func exportScratch() -> (directory: URL, clean: () -> Void) {
        let directory = ScratchFile.unmade("export", file: "exports")
        return (directory, { ScratchFile.remove(directory.path) })
    }

    /// How long a model is given to reach a state. One number, because two suites disagreeing
    /// about patience is a flake that looks like a defect in whichever is stricter.

    /// A word the reader looked up and enrolled. **One spelling, parameterised** — three copies
    /// of this had drifted in their context text and their answer's origin, and a test reading
    /// one suite's rows against another's expectations could not be written at all.
    @discardableResult
    static func save(_ ledger: Ledger, _ word: String,
                     script: ProbeScript = .latin,
                     origin: StudyAnswer.Origin = .dictionary,
                     at when: Date) throws -> StudyNote {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word) in it.",
            lemmaBasis: .tagger, language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: when, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: script))
        return try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: origin, text: "what \(word) means"),
            lookupID: lookup, at: when)
    }

    /// **One store, opened once**, as the app has. Four suites each wrote
    /// `{ Task { try LedgerStore(path: path) } }`, which builds a new actor and a new SQLite
    /// connection per access — so none of them exercised the serialisation or the write-ahead
    /// log that production depends on.
    @MainActor
    static func store(_ path: String) -> @MainActor () -> Task<LedgerStore, any Error>? {
        let opening = Task { try LedgerStore(path: path) }
        return { opening }
    }

    /// **Opened on every access**, for the one test whose subject is a ledger that cannot be
    /// written: the permissions it sets take effect at `open`, so a connection opened before
    /// them goes on writing through its own descriptor. Everything else wants `store`.
    static func reopeningStore(_ path: String) -> @MainActor () -> Task<LedgerStore, any Error>? {
        { Task { try LedgerStore(path: path) } }
    }

    static let patience = 2_000

    /// Waits for `condition`, and **throws when it never holds**.
    ///
    /// Recording an issue and returning normally let every assertion after the wait run against a
    /// model still mid-flight, and let teardown delete the SQLite files while a task was still
    /// using them — so one missed state produced a cascade of failures that named the wrong
    /// thing, or a crash in cleanup. A wait that did not happen stops the test.
    @MainActor
    static func settle(_ what: String = "the model never reached the expected state",
                       _ condition: () -> Bool) async throws {
        for _ in 0..<patience {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WiringTimeout(what: what)
    }
}

/// Thrown by `Wiring.settle`, so a state that never arrived ends its test rather than letting
/// everything after it run and fail for reasons of its own.
struct WiringTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "\(what) (waited \(Wiring.patience * 5) ms)" }
}
