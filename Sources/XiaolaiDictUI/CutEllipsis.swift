import DictionaryModel
import Foundation

/// **An ellipsis on each side of the reader's sentence that the capture may have cut** — outside their words, so nothing
/// in them moves. The lookup card, History and the Library draw it the same way: on a known side only. A possible cut
/// whose side is unknown is said in words, never drawn as a cut at the end.
enum CutEllipsis {
    /// `text` with `…` on each side `cut` names. `startAlreadyCut` is a window that already begins with its own `…`,
    /// which says the same thing there.
    static func applied(to text: AttributedString, cut: TextSegmenter.Clipping, startAlreadyCut: Bool = false)
        -> AttributedString {
        var text = text
        if cut.contains(.start), !startAlreadyCut { text.insert(AttributedString("…"), at: text.startIndex) }
        if cut.contains(.end) { text.append(AttributedString("…")) }
        return text
    }
}
