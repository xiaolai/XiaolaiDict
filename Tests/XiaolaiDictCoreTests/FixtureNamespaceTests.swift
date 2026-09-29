import DictionaryModel
import Foundation
import Testing

/// **A fixture in the wrong namespace tests less than it looks like it tests.**
///
/// `EntryDocument` recognises `d:def`, `d:pos` and `d:prn` only when the `d` prefix resolves to
/// `EntryDocument.namespace` — `…/DictionaryService-1.0.rng`. Two test fixtures declared
/// `…/DictionaryService-1.0.rfc`, one character different, so every sense they produced carried
/// `definition == nil` while `text` held the words. Nothing failed: the tests using them asserted other
/// things, and a third file copied the typo from them before this was noticed.
///
/// A scan rather than a fix, because the fix lasts until the next copy-paste. Mechanical, like the
/// scratch-directory and defaults-suite rules, and for the same reason.
struct FixtureNamespaceTests {
    @Test func everyFixtureDeclaresTheNamespaceTheParserReads() throws {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        try #require(files.count > 20, "found only \(files.count) test files — the scan is not looking where the tests are")
        // Built from parts, and comments skipped, so this file does not match its own search — it has to
        // name both spellings to explain itself, and the first version flagged three of its own lines.
        let stem = "DictionaryService" + "-1.0."
        var offenders: [String] = []
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains(stem),
                      !code.contains(EntryDocument.namespace) else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty, """
            these fixtures declare a namespace the parser does not read, so d:def, d:pos and d:prn are \
            silently ignored in them: \(offenders.joined(separator: ", "))
            """)
    }
}
