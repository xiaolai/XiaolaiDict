import Foundation
import Testing

@testable import XiaolaiDictCore

/// **A ledger's handle is closed by one owner, once.**
///
/// `Ledger.init` closed its handle when a later step threw, and Swift then ran `deinit`, which
/// closed it again — the second `sqlite3_close` writing into a freed connection. When malloc handed
/// that block to another test's new connection, `openDatabase` read `db->aDb` as null and stored the
/// new B-tree through `0x8`: the `sqlite3BtreeOpen + 3104` segfault, one full run in nine.
///
/// Read from the source, because the defect cannot be caught by running it here: it only crashes
/// when the freed block is reused in the window before the stale write, and the one tool that makes
/// that deterministic — Guard Malloc — never reaches the test helper, which drops
/// `DYLD_INSERT_LIBRARIES` (measured: not one Guard Malloc banner from `swiftpm-testing-helper`).
/// The structure is what can be checked, so the structure is what is pinned.
///
/// A behavioural test sat beside this — fifty ledgers that must refuse to open, then one more — and
/// was removed after it **passed with the double close put back**: without Guard Malloc the stale
/// write lands in memory nobody is using yet, and nothing crashes. A check that cannot fail is
/// worse than none, because it reads as one.
struct LedgerConnectionTests {
    private func ledgerSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDictCore/Ledger.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        // Comment lines dropped: the note explaining the double close names `sqlite3_close` itself.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func onlyTheConnectionClosesAnOpenHandle() throws {
        let code = try ledgerSource()
        #expect(code.contains("deinit { sqlite3_close(handle) }"), "Connection no longer owns the close")
        // Closing through the ledger's `db` is the shape of the bug: it is the handle the owner will
        // close again when the ledger goes away.
        #expect(!code.contains("sqlite3_close(db)"), "the ledger closes the handle it does not own")
        // Two closes, both legitimate: the owner's, and a handle `sqlite3_open_v2` returned alongside a
        // failure — never wrapped, so nothing else will close it.
        let closes = code.components(separatedBy: "sqlite3_close(").count - 1
        #expect(closes == 2, "expected the owner's close and the failed-open close, found \(closes)")
    }
}
