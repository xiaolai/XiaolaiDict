import LLMProviders
import Testing

/// **A provider answers a sense question in prose, and the number is read out of it the way the lab read it** —
/// the 270-case measurement behind ADR-0053 scored answers with `answer_number`, so a reader that differed would
/// make the measured error rates describe a different parser. The rule: the first non-empty line, that line up to
/// its first full stop, the first run of digits in it. `0` is the model abstaining and is returned as `0`; a number
/// outside the list, or no number at all, is no answer.
///
/// **One deliberate difference, and it refuses rather than reads**: the lab's `\d` matched any decimal digit, so
/// `٣` was 3 there. Here a run that holds a digit outside ASCII is no answer — nothing in a sense prompt asks for
/// another script's digits, and reading one would turn a model's slip into a confident position in the list.
struct SenseAnswerTests {
    @Test(arguments: [
        // The plain answers.
        ("3", 3), ("3.", 3), (" 3 ", 3), ("12", 12),
        // Prose around the number, as hosted models write it.
        ("Answer: 2", 2), ("The answer is 4.", 4), ("Sense 7 fits best.", 7), ("I think 12", 12),
        ("**5**", 5), ("(1)", 1), ("#2 — the noun sense", 2),
        // The first non-empty line decides, whatever follows.
        ("\n\n  \n6\nbecause of 9", 6), ("\r\n2\r\n3", 2),
        // Up to the first full stop: "1.5" is sense 1, and a number after the stop is not read.
        ("1.5", 1), ("Sense 1. Not 8.", 1),
        // The first run, not the largest or the last.
        ("2 or 3", 2), ("between 3 and 4", 3),
        // Zero is the model abstaining, and is an answer.
        ("0", 0), ("0.", 0), ("00", 0), ("Answer: 0 — none fits", 0),
        // A keycap is a digit followed by marks, and the digit is read.
        ("3\u{FE0F}\u{20E3}", 3),
    ] as [(String, Int)])
    func aNumberInRangeIsRead(text: String, expected: Int) {
        #expect(SenseAnswer.parse(text, count: 12) == expected, "\(text.debugDescription)")
    }

    @Test(arguments: [
        // Nothing to read.
        "", "   ", "\n\n", "no digits", "none of these", "N/A",
        // A number past the end of the list.
        "13", "I think 99", "Sense 13.",
        // A number only after the first full stop, or only on a later line.
        "It is unclear. Maybe 3.", "Unclear\n3",
        // Digits outside ASCII: Arabic-Indic, full-width, Devanagari — and a non-ASCII run that comes first.
        "٣", "３", "३", "Answer: ٣", "٣ or 3",
        // A run too long for any integer is not a position.
        "99999999999999999999999999",
    ])
    func whatIsNotAPositionInTheListIsNoAnswer(text: String) {
        #expect(SenseAnswer.parse(text, count: 12) == nil, "\(text.debugDescription)")
    }

    /// **The bounds are the list's**: its last position is read, one past it is not, and a list of one admits 1.
    @Test func theBoundsAreTheLists() {
        #expect(SenseAnswer.parse("5", count: 5) == 5)
        #expect(SenseAnswer.parse("6", count: 5) == nil)
        #expect(SenseAnswer.parse("1", count: 1) == 1)
        #expect(SenseAnswer.parse("2", count: 1) == nil)
    }

    /// **An empty list still reads an abstention, and refuses every position** — never a trap on `1...0`.
    @Test func anEmptyListReadsOnlyAnAbstention() {
        #expect(SenseAnswer.parse("0", count: 0) == 0)
        #expect(SenseAnswer.parse("1", count: 0) == nil)
        #expect(SenseAnswer.parse("1", count: -3) == nil)
    }
}
