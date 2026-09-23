import Foundation
import Testing

/// The token system, enforced by reading the source rather than by remembering.
///
/// A design system that lives only in a convention decays quietly: one `padding(12)` added in a
/// hurry costs nothing on its own, and by the thirtieth the tokens describe a design the app no
/// longer has. So the rule is mechanical — **the view declares no values** — and this is what makes
/// it true rather than aspirational.
///
/// Every view in `XiaolaiDictUI`, with eight exemptions — the count is the file count, not the row
/// count, because two files share a reason — each of which is a reason rather than a convenience:
/// a long unexplained allow-list is how a rule like this dies. The prose said "four" for as long
/// as the table said eight, which is why `everyExemptionIsInTheTableAndEveryTableRowIsExempt`
/// now reads this comment rather than trusting it:
///
/// | File | Why |
/// |---|---|
/// | `DesignTokens.swift` | Where the values that do *not* scale live. |
/// | `Scale.swift` | Where the values that *do* scale live, and the sizes the reader can pick. |
/// | `CardSurface.swift`, `ReadingAccent.swift` | The semantic layer: a palette and four shades are declarations of value, not uses of one. |
/// | `CardPile.swift` | Arithmetic. What is left is structural — an off-by-one, a half, a both-sides — and its two design values, the pile's depth and its offsets, come from tokens. |
/// | `EntryPresentation.swift` | A formatting model with no SwiftUI in it at all. Its numbers are English grammar: `11...13` take "th", and no token will ever change that. |
/// | `PrivacySettings.swift` | `majorVersion >= 27` is a fact about macOS. |
/// | `AppIcons.swift` | A bitmap format. `bitsPerSample: 8, samplesPerPixel: 4` is RGBA, and no token will ever change that. Its one design value, the raster size, is in `Token.Panel`. |
struct NoMagicValuesTests {
    /// 0 and 1 stay legal: they are identities, not measurements. `opacity(… ? 1 : 0)` and
    /// `progress: expanded ? 1 : 0` are saying "all" and "none", and a token for either would be
    /// indirection with nothing on the other end.
    private static let identities: Set<String> = ["0", "1"]

    /// Numeric literals in one line of Swift, ignoring digits that are part of an identifier.
    ///
    /// Hand-written rather than a regex because Swift's engine has no lookbehind, and because the
    /// one thing this must get right — telling `padding(14)` from `.v26` — is exactly what the
    /// lookbehind was for.
    static func literals(in code: String) -> [String] {
        var found: [String] = []
        let characters = Array(code)
        var index = 0
        while index < characters.count {
            guard characters[index].isNumber else {
                index += 1
                continue
            }
            let insideIdentifier = index > 0
                && (characters[index - 1].isLetter || characters[index - 1] == "_")
            var end = index
            while end < characters.count, characters[end].isNumber { end += 1 }
            // A fractional part belongs to the number, so 0.12 is one literal and not a 0 and a 12.
            if end + 1 < characters.count, characters[end] == ".", characters[end + 1].isNumber {
                end += 1
                while end < characters.count, characters[end].isNumber { end += 1 }
            }
            if !insideIdentifier { found.append(String(characters[index..<end])) }
            index = end
        }
        return found
    }

    /// Comments and string literals are prose. A number in either is not a design value, and
    /// "241 → 229 → 217" in a doc comment is a measurement being recorded, not one being made.
    private static func stripped(_ line: String) -> String {
        var code = line
        if let comment = code.range(of: "//") { code = String(code[code.startIndex..<comment.lowerBound]) }
        var out = ""
        var inString = false
        var escaped = false
        for character in code {
            if escaped { escaped = false; continue }
            if character == "\\" && inString { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            if !inString { out.append(character) }
        }
        return out
    }

    private static let exempt: Set<String> = [
        "DesignTokens.swift", "Scale.swift", "CardSurface.swift", "ReadingAccent.swift",
        "CardPile.swift", "EntryPresentation.swift", "PrivacySettings.swift", "AppIcons.swift",
    ]

    private var viewLayer: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDictUI")
    }

    private func source(of file: URL) throws -> String {
        // Thrown, never defaulted to "": a scanner that silently finds nothing to scan passes
        // forever and guards nothing.
        let text = try String(contentsOf: file, encoding: .utf8)
        // Previews stop here. Sample data is full of honest numbers — row ids, minutes ago, a
        // canvas size — and none of them are the design.
        guard let end = text.range(of: "// MARK: - Previews") else { return text }
        return String(text[text.startIndex..<end.lowerBound])
    }

    @Test func noViewDeclaresValuesOfItsOwn() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: viewLayer, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !Self.exempt.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // A scan of nothing passes. Naming the count is what makes the pass mean something, and
        // what fails loudly the day the exemption list quietly swallows the view layer.
        #expect(files.count >= 6, "only \(files.count) view files were found to scan")

        var offenders: [String] = []
        for file in files {
            let text = try source(of: file)
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                for literal in Self.literals(in: Self.stripped(String(line)))
                where !Self.identities.contains(literal) {
                    offenders.append("\(file.lastPathComponent):\(offset + 1): \(literal)"
                        + " — \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            "views are declaring values instead of reading tokens:\n\(offenders.joined(separator: "\n"))")
    }

    /// The exemptions have to stay reasons. A file that no longer exists is how the rule turns
    /// into a formality.
    @Test func everyExemptionNamesAFileThatIsStillThere() throws {
        for name in Self.exempt {
            let path = viewLayer.appending(path: name)
            #expect(
                FileManager.default.fileExists(atPath: path.path),
                "\(name) is exempt from the scan but no longer exists")
        }
    }

    /// **And the table above says why, for each of them.**
    ///
    /// The check beside this one asked only whether the exempt files exist — never whether the
    /// documented reason had kept up. It had not: the prose claimed four exemptions while the set
    /// held eight, and a file could have been added to the set with no reason written anywhere.
    /// Both directions, because the drift runs both ways: a set entry with no row is an
    /// unexplained exemption, and a row with no set entry is a reason for a rule nobody applies.
    @Test func everyExemptionIsInTheTableAndEveryTableRowIsExempt() throws {
        let doc = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix("struct NoMagicValuesTests") }
            .filter { $0.hasPrefix("///") }
            .joined(separator: "\n")

        for name in Self.exempt {
            #expect(doc.contains("`\(name)`"), "\(name) is exempt with no reason written down")
        }
        // Every file the table names is one the scan actually skips. Read back out of the same
        // prose, so a row for a file that was un-exempted cannot linger as a false explanation.
        var named: Set<String> = []
        var rest = Substring(doc)
        while let open = rest.range(of: "`"), let close = rest[open.upperBound...].range(of: "`") {
            let quoted = String(rest[open.upperBound..<close.lowerBound])
            if quoted.hasSuffix(".swift") { named.insert(quoted) }
            rest = rest[close.upperBound...]
        }
        #expect(named == Self.exempt,
                "the table and the exemption list disagree: \(named.symmetricDifference(Self.exempt).sorted())")
    }

    /// The scanner has to be able to fail, or its passing says nothing. This feeds the real
    /// scanner — not a copy of it — the thing it is looking for, and the things it must not flag.
    @Test func theScannerCatchesAValueAndLeavesATokenAlone() {
        #expect(Self.literals(in: ".padding(14)") == ["14"])
        #expect(Self.literals(in: ".opacity(Token.Opacity.border)").isEmpty)
        #expect(Self.literals(in: ".shadow(radius: 0.125)") == ["0.125"])
        // A digit inside a name is not a value: `.v26` is a platform, not a measurement.
        #expect(Self.literals(in: "platforms: [.macOS(.v26)]").isEmpty)
    }

    @Test func commentsAndStringsAreProseNotValues() {
        #expect(Self.literals(in: Self.stripped("let x = y // was 241 → 229 → 217")).isEmpty)
        #expect(Self.literals(in: Self.stripped("Text(\"7 words · 2 days\")")).isEmpty)
        #expect(Self.literals(in: Self.stripped("code(12) // and 34")) == ["12"])
    }
}
