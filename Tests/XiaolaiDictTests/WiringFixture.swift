import Foundation
import Testing
import XiaolaiDictCore
@testable import XiaolaiDict

/// **What the window tests share**, in one place.
///
/// Three copies of `settle` and two of the scratch-file cleanup had already drifted: the polling
/// bounds were 400 iterations in two of them and 2,000 in the third, so the same test was patient
/// in one suite and not in another, and nobody had decided which. A fixture with two spellings is
/// two fixtures.
enum Wiring {
    /// A scratch ledger path, and the cleanup that removes it **with its write-ahead log**. A
    /// ledger separated from its sidecars is the shape this project already has a rule about.
    static func scratch(_ label: String) -> (path: String, clean: () -> Void) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-\(label)-\(UUID().uuidString).sqlite").path
        return (path, {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        })
    }

    /// Somewhere disposable for an export. **Never the reader's Downloads folder**, which a test
    /// once wrote into and then deleted from.
    static func exportScratch() -> (directory: URL, clean: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-export-\(UUID().uuidString)", isDirectory: true)
        return (directory, { try? FileManager.default.removeItem(at: directory) })
    }

    /// How long a model is given to reach a state. One number, because two suites disagreeing
    /// about patience is a flake that looks like a defect in whichever is stricter.
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
