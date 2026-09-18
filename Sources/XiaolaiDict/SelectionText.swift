import CoreFoundation
import Foundation
import XiaolaiDictCore

/// The term a selection stands for: whitespace and the punctuation that only wraps or ends a word
/// come off — “ephemeral,” is ephemeral — while punctuation that belongs to the term stays: C#,
/// .NET, U.S., don't, word(s), -ish.
struct SelectedTerm: Equatable {
    let text: String
    /// Where `text` sits in the selection it came from, UTF-16.
    let range: NSRange

    /// Nil when nothing is left: the selection was only whitespace and punctuation.
    init?(from selection: String) {
        var lower = selection.startIndex
        var upper = selection.endIndex
        while lower < upper {
            let first = selection[lower]
            let last = selection[selection.index(before: upper)]
            let inner = selection[lower..<upper]
            if first.isWhitespace || (Self.isOpening(first) && !Self.closes(first, in: inner)) {
                lower = selection.index(after: lower)
            } else if last.isWhitespace || Self.isTrailing(last, in: inner) {
                upper = selection.index(before: upper)
            } else if inner.count > 1, Self.pairs(first, last, around: inner.dropFirst().dropLast()) {
                lower = selection.index(after: lower)
                upper = selection.index(before: upper)
            } else {
                break
            }
        }
        guard lower < upper else { return nil }
        text = String(selection[lower..<upper])
        range = NSRange(lower..<upper, in: selection)
    }

    private static let brackets: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "（": "）", "「": "」", "『": "』", "【": "】", "《": "》", "〈": "〉",
    ]
    /// Ends a sentence or clause, in Latin and CJK scripts.
    private static let sentencePunctuation: Set<Character> = [",", ";", ":", "!", "?", "…", "。", "，", "、", "；", "：", "！", "？"]
    private static let dashes: Set<Character> = ["—", "–"]

    /// Opening quotes and ¿ ¡ always come off the front; an opening bracket only when its closer is
    /// not in the term — "(word)" loses both, "(s)he" keeps its own.
    private static func isOpening(_ character: Character) -> Bool {
        guard let category = character.unicodeScalars.first?.properties.generalCategory else { return false }
        return category == .openPunctuation || category == .initialPunctuation
            || ["\"", "¿", "¡"].contains(character) || dashes.contains(character)
    }

    private static func closes(_ opener: Character, in term: Substring) -> Bool {
        guard let closer = brackets[opener] else { return false }
        return term.dropFirst().contains(closer)
    }

    /// Closing quotes, sentence punctuation and dashes come off the end; a closing bracket only when
    /// its opener is not in the term (word(s) keeps it); a final full stop unless the term is an
    /// abbreviation spelled with stops — "U.S.", "e.g.", "Ph.D." keep theirs; "etc.", ".NET." and
    /// "example.com." lose it, and "word..." loses all three.
    private static func isTrailing(_ character: Character, in term: Substring) -> Bool {
        if let opener = brackets.first(where: { $0.value == character })?.key { return !term.dropLast().contains(opener) }
        if character == "." { return !isDottedAbbreviation(term) }
        guard let category = character.unicodeScalars.first?.properties.generalCategory else { return false }
        return category == .closePunctuation || category == .finalPunctuation
            || character == "\"" || sentencePunctuation.contains(character) || dashes.contains(character)
    }

    /// Two or more short letter groups, each followed by a stop: U.S., e.g., a.m., Ph.D.
    private static func isDottedAbbreviation(_ term: Substring) -> Bool {
        let groups = term.split(separator: ".", omittingEmptySubsequences: false)
        guard term.hasSuffix("."), groups.count >= 3, groups.last?.isEmpty == true else { return false }
        return groups.dropLast().allSatisfy { (1...3).contains($0.count) && $0.allSatisfy(\.isLetter) }
    }

    /// Marks that come off only as a pair around the whole term. Straight quotes are both opening
    /// and closing — 'quoted' loses both, 'tis and dogs' keep theirs — and a bracket wrapping the
    /// term, "(word)", goes with its closer; "(a) or (b)" keeps both, being two groups, not one.
    private static func pairs(_ first: Character, _ last: Character, around inner: Substring) -> Bool {
        if first == "'" && last == "'" { return true }
        guard brackets[first] == last else { return false }
        return !inner.contains(first) && !inner.contains(last)
    }
}

/// The stretch of a document read to find a selection's sentence: a window, not the whole
/// document — a long document is megabytes over IPC for one sentence.
struct SelectionWindow: Equatable {
    /// The window, in the document's UTF-16 units.
    let location: Int
    let length: Int
    /// The selection, relative to the window.
    let selection: NSRange
    /// The document's reported length, when the app reports one.
    private let documentLength: Int?

    /// `selection` and `documentLength` come from another process and are validated, not trusted:
    /// nil for a negative range, one whose end overflows, or one past the reported length.
    init?(selection: CFRange, documentLength: Int?, radius: Int) {
        guard selection.location >= 0, selection.length >= 0, radius >= 0 else { return nil }
        let (selectionEnd, overflow) = selection.location.addingReportingOverflow(selection.length)
        guard !overflow else { return nil }
        if let documentLength { guard documentLength >= 0, selectionEnd <= documentLength else { return nil } }
        let start = selection.location - min(selection.location, radius)
        let (wanted, beyond) = selectionEnd.addingReportingOverflow(radius)
        let end = min(beyond ? Int.max : wanted, documentLength ?? Int.max)
        location = start
        length = end - start
        self.selection = NSRange(location: selection.location - start, length: selection.length)
        self.documentLength = documentLength
    }

    var cfRange: CFRange { CFRange(location: location, length: length) }

    /// Which ends of the text read are cuts in the document. The end is the document's own only
    /// when the text read reaches the reported length. A short answer is not taken for the end:
    /// with a length reported it is a truncation, and without one it cannot be told from one.
    func clipping(returnedLength: Int) -> TextSegmenter.Clipping {
        var clipped: TextSegmenter.Clipping = []
        if location > 0 { clipped.insert(.start) }
        let reachesEnd = documentLength.map { location + returnedLength >= $0 } ?? false
        if !reachesEnd { clipped.insert(.end) }
        return clipped
    }

    /// Whether `text`, read for this window, holds `selected` exactly where the selection range
    /// says. Text, range and window are separate reads; if the selection changed between them, or
    /// the app's ranges disagree with its text, this is where it shows.
    func holds(_ selected: String, in text: String) -> Bool {
        let units = text.utf16
        guard selection.location + selection.length <= units.count,
              let range = Range(selection, in: text)
        else { return false }
        return text[range] == selected
    }
}

/// What a bounded breadth-first search found.
enum SearchResult<Node> {
    case found(Node)
    /// Every reachable node was visited.
    case absent
    /// The limit ran out first: absence is not established.
    case limitReached
}

/// Breadth first, each node visited once however many parents list it, and at most `limit` nodes.
func breadthFirst<Node: Hashable, Failure: Error>(
    from root: Node, limit: Int,
    children: (Node) throws(Failure) -> [Node],
    matches: (Node) throws(Failure) -> Bool
) throws(Failure) -> SearchResult<Node> {
    var queue = [root]
    var seen: Set<Node> = [root]
    var head = 0
    while head < queue.count {
        guard head < limit else { return .limitReached }
        let node = queue[head]
        head += 1
        if try matches(node) { return .found(node) }
        for child in try children(node) where seen.insert(child).inserted { queue.append(child) }
    }
    return .absent
}
