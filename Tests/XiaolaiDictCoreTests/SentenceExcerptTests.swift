import Foundation
import XiaolaiDictCore
import Testing

/// A window onto the reader's sentence that is guaranteed to show the word.
///
/// The drawer card holds the sentence to two lines and truncates from the end, so a long sentence
/// with its word late showed two lines of the reader's own text **without the word they looked
/// up**. Measured on a real ledger row: "ticket" at character 114 of a 248-character sentence,
/// cut off at about 100. A card that exists to show a word in its sentence has to start its window
/// near the word, not at the sentence's first character.
struct SentenceExcerptTests {
    private func mark(_ word: String, in sentence: String) -> NSRange {
        (sentence as NSString).range(of: word)
    }

    /// Words, counted the way the excerpt counts them — ICU word boundaries, which is what makes
    /// Chinese measure in words rather than in characters.
    private func words(_ text: String) -> Int {
        var count = 0
        (text as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: (text as NSString).length),
            options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    /// Where the word is already near the start, nothing is cut and nothing is added.
    @Test func aWordNearTheStartLeavesTheSentenceWhole() {
        let sentence = "The beauty of morning frost."
        let excerpt = SentenceExcerpt(sentence: sentence, marks: [mark("beauty", in: sentence)])
        #expect(excerpt.text == sentence)
        #expect(excerpt.marks == [mark("beauty", in: sentence)])
        #expect(!excerpt.clippedBefore)
    }

    /// The row that was broken, as it was broken.
    @Test func aWordLateInALongSentenceIsBroughtIntoView() {
        let sentence = "Two new ones: a cached build reusing a bundle signed without a timestamp (#7), "
            + "and a rebuild discarding a stapled ticket (#8). workflow: look for an existing profile "
            + "and at your other projects first, and read reference.md before writing a pipeline."
        let original = mark("ticket", in: sentence)
        #expect(original.location == 114, "the fixture no longer matches the measured row")

        let excerpt = SentenceExcerpt(sentence: sentence, marks: [original])
        #expect(excerpt.clippedBefore)
        #expect(excerpt.text.hasPrefix("…"), "a cut start has to say so, or it reads as the sentence's own")
        #expect((excerpt.text as NSString).substring(with: excerpt.marks[0]) == "ticket")
        // Exactly the allowed number of words precede the word — the contract, not "fewer".
        let before = (excerpt.text as NSString).substring(to: excerpt.marks[0].location)
        #expect(words(before) == SentenceExcerpt.wordsBefore, "found \(words(before)) words before it")
    }

    /// Every mark moves with the cut: a phrasal verb is two marks, and both must still land on
    /// their own words.
    @Test func everyMarkMovesWithTheCut() {
        let sentence = "After a long and difficult year of quiet negotiation she finally took "
            + "the whole family company over."
        let marks = [mark("took", in: sentence), mark("over", in: sentence)]
        let excerpt = SentenceExcerpt(sentence: sentence, marks: marks)
        #expect(excerpt.clippedBefore)
        #expect(excerpt.marks.map { (excerpt.text as NSString).substring(with: $0) } == ["took", "over"])
    }

    /// Counted in words, not characters, so a Chinese sentence gets the same amount of context as
    /// an English one rather than a quarter of it.
    @Test func chineseIsCountedInWords() {
        let sentence = "我们今天在公园里看到了一只非常美丽的蝴蝶在花丛中飞舞"
        let excerpt = SentenceExcerpt(sentence: sentence, marks: [mark("蝴蝶", in: sentence)])
        #expect(excerpt.clippedBefore)
        #expect((excerpt.text as NSString).substring(with: excerpt.marks[0]) == "蝴蝶")
        let before = (excerpt.text as NSString).substring(to: excerpt.marks[0].location)
        #expect(words(before) == SentenceExcerpt.wordsBefore)
    }

    /// Offsets are UTF-16, as `NSRange` is. An emoji early in the sentence is two units, and a
    /// shift counted in characters would land every mark one unit short.
    @Test func surrogatePairsBeforeTheWordDoNotMoveTheMark() {
        let sentence = "🎉🎉 The party ran late and everyone stayed to finish the cake together."
        let excerpt = SentenceExcerpt(sentence: sentence, marks: [mark("cake", in: sentence)])
        #expect(excerpt.clippedBefore)
        #expect((excerpt.text as NSString).substring(with: excerpt.marks[0]) == "cake")
    }

    @Test func nothingMarkedLeavesTheSentenceWhole() {
        let sentence = "A sentence with nothing marked in it at all, however long it runs on for."
        let excerpt = SentenceExcerpt(sentence: sentence, marks: [])
        #expect(excerpt.text == sentence)
        #expect(!excerpt.clippedBefore)
    }

    // MARK: - The windows a card chooses between

    /// **The whole sentence comes first.** The card used to cut every sentence six words before its
    /// word, whether or not the whole of it fitted — so "He did not really mean to take the
    /// ticket." lost its negation, and a learner read the opposite of what was written. The view
    /// now shows the first of these that fits its lines, and the first is always all of it.
    @Test func theWholeSentenceIsOfferedFirst() {
        let sentence = "He did not really mean to take the ticket."
        let range = (sentence as NSString).range(of: "ticket")
        let windows = SentenceExcerpt.windows(sentence: sentence, marks: [range])
        #expect(windows.first?.text == sentence)
        #expect(windows.first?.clippedBefore == false)
        #expect(windows.count > 1, "a sentence with its word this late needs tighter windows to fall back on")
    }

    /// Then less and less context, so a sentence of long words still gets its word in view:
    /// counting words cannot know how long they are, and the card measures instead.
    @Test func eachWindowHasLessContextThanTheOneBefore() {
        let sentence = "Two new ones: a cached build reusing a bundle signed without a timestamp, and a ticket."
        let range = (sentence as NSString).range(of: "ticket")
        let windows = SentenceExcerpt.windows(sentence: sentence, marks: [range])
        let lengths = windows.map { ($0.text as NSString).length }
        #expect(lengths == lengths.sorted(by: >), "the windows should shrink: \(windows.map(\.text))")
        #expect(Set(windows.map(\.text)).count == windows.count, "a window was offered twice")
    }

    /// And every one still has the word where its marks say.
    @Test func everyWindowStillMarksTheWord() {
        let sentence = "He did not really mean to take the ticket, or the 🎟️ ticket stub."
        let whole = sentence as NSString
        let marks = [whole.range(of: "ticket"), whole.range(of: "ticket", options: .backwards)]
        for window in SentenceExcerpt.windows(sentence: sentence, marks: marks) {
            for mark in window.marks {
                #expect((window.text as NSString).substring(with: mark) == "ticket", "in \(window.text)")
            }
        }
    }

    /// **The last window starts at the word itself.** Every window with context before it can be
    /// defeated by what that context contains — one long word, a line break, an emoji — so the
    /// last one keeps none, and the word is the first thing on the first line.
    @Test func theLastWindowStartsAtTheWord() {
        let sentence = "Antidisestablishmentarianism notwithstanding, the supercalifragilistic ticket was torn."
        let range = (sentence as NSString).range(of: "ticket")
        let windows = SentenceExcerpt.windows(sentence: sentence, marks: [range])
        let last = windows[windows.count - 1]
        #expect(last.text.hasPrefix("…ticket"), "the last window reads \(last.text)")
        #expect((last.text as NSString).substring(with: last.marks[0]) == "ticket")
    }

    /// **Context with no words in it is still context.** Line breaks before the word push it down
    /// the card as surely as words do, and the window that keeps no words was skipped for them:
    /// counting words, there was nothing to cut.
    @Test func contextWithNoWordsIsStillCut() {
        let sentence = "\n\n\nticket was torn."
        let range = (sentence as NSString).range(of: "ticket")
        let last = SentenceExcerpt.windows(sentence: sentence, marks: [range]).last
        #expect(last?.text.hasPrefix("…ticket") == true, "the last window reads \(last?.text ?? "none")")
        #expect(last?.clippedBefore == true)
    }

    /// A word near the start is offered whole first, and the tighter windows after it are only
    /// ever *tighter* — a card at a large text size may still need one.
    @Test func aWordNearTheStartIsOfferedWholeFirst() {
        let sentence = "The ticket was never used."
        let windows = SentenceExcerpt.windows(sentence: sentence, marks: [(sentence as NSString).range(of: "ticket")])
        #expect(windows.first?.text == sentence)
        #expect(windows.dropFirst().allSatisfy { ($0.text as NSString).length < (sentence as NSString).length })
    }
}
