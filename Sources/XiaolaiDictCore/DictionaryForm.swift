import DictionaryModel
import Foundation

/// **The term's dictionary form worth offering, and what makes the offer defensible** (plan-card-refinements WI-3; the
/// guards are D1 of 2026-10-10, ADR-0054). An offer, never a substitution: the card draws "Look up “X” as “Y”?" and the
/// reader decides.
///
/// **A lemma the dictionaries have is not a relationship to the term.** They have *pride*, and *prideed* is still none
/// of its forms. On the WI-3 spike's 1,221 recoveries the bare lemma was offered for 55 that the labels called wrong,
/// and every one was in a class with a mechanical tell: a suffix spelled against English (*prideed*, *gobes*,
/// *tengees*), a consonant doubled against the base or left single where it doubles (*propoundded*, *tiped*), an *-ie*
/// noun read as a *-y* adjective (*hedgiest*), and a name or abbreviation read as an inflection (*Frances*, *Hans*,
/// *Jos*, *hrses*). So a form is a candidate only where one of two things holds, decided with no model:
///
/// - **printed** — the reader's own dictionaries print the term as an inflection of the form (`FormTable`, ADR-0051);
/// - **regular** — the term is the form's regular inflection by English spelling (`RegularSpelling`, stricter than
///   `RegularInflection`, whose concatenations accept *prideed*), the form prints nothing in that slot to say
///   otherwise, and the term is written in lowercase with a vowel in its form — and, once the form is looked up, an
///   entry headed by it in lowercase has a part of speech that inflects so (`isSupported(by:)`).
///
/// Anything else is no candidate, and the checker's verified correction is offered as if the term had no form.
public struct DictionaryForm: Equatable, Sendable {
    /// The form, in the lemmatiser's spelling: what is looked up, and what the card offers.
    public let word: String
    public let evidence: Evidence

    /// Why the form is the term's.
    public enum Evidence: Equatable, Sendable {
        /// The dictionaries print the term under the form.
        case printed
        /// The term is the form's regular inflection in this slot; the form's entry must license it.
        case regular(InflectionSlot)
    }

    public init(word: String, evidence: Evidence) {
        self.word = word
        self.evidence = evidence
    }

    /// The form worth asking the dictionaries about, or nil. `lemma` must be one the lemmatiser stands by — the
    /// tagger's, a rule's or the usual reading of an irregular, never one it called `ambiguous` or none at all — and
    /// not the term again up to case; `printed` is the reader's form table, nil where none has been read.
    public static func candidate(_ lemma: Lemma?, for term: String, printed table: FormTable?) -> DictionaryForm? {
        guard let lemma, lemma.basis <= .likely else { return nil }
        let form = lemma.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !form.isEmpty, form.compare(asked, options: .caseInsensitive) != .orderedSame else { return nil }
        let written = Lemmatizer.canonical(asked)
        // **What the dictionaries print outranks every rule below.** A term they print is offered only a form they
        // print it under — *judies* is printed under *judy*, so *judie* is not its form whatever the spelling says.
        if let printed = table?.entry(for: written) {
            return printed.readings.contains { $0.lemma == form } ? DictionaryForm(word: form, evidence: .printed) : nil
        }
        // **A capital anywhere is a name, an abbreviation or a brand** — *Frances*, *Hans*, *HRSes* — and none is a
        // regular inflection; ADR-0051's rule for the same table. A sentence's first word loses a rare inflection to
        // this, which is the cheaper error: the checker is still asked.
        guard !asked.contains(where: \.isUppercase), RegularSpelling.hasVowel(form) else { return nil }
        // **A headword that prints its forms in a slot prints all of them**: *tip* prints *tipped*, so *tiped* is not
        // its past whatever a rule would allow, and *pretzel* prints *pretzeled*, so *pretzelled* is not offered.
        let printedSlots = Set((table?.printed(under: form) ?? []).compactMap {
            RegularSpelling.slot(ofPrinted: $0.form, as: $0.partOfSpeech)
        })
        let slot = RegularSpelling.slots(of: written, from: form).first { !printedSlots.contains($0) }
        return slot.map { DictionaryForm(word: form, evidence: .regular($0)) }
    }

    /// **Whether the form's lookup bears the offer out.** Printed: the dictionaries have the form (`SpellingCorrection`'s
    /// rule). Regular: an entry headed by the form **in lowercase** — *France* is a proper noun, and a proper noun takes
    /// no regular inflection — whose blocks name a part of speech that takes the slot. An entry that names none (a
    /// dictionary with no sense structure) has said nothing, and is no licence.
    public func isSupported(by outcome: LookupOutcome) -> Bool {
        guard SpellingCorrection.isVerified(outcome) else { return false }
        guard case .regular(let slot) = evidence else { return true }
        guard case .entries(let entries, _) = outcome else { return false }
        return entries.contains { entry in
            entry.match == .exact && !entry.headword.contains(where: \.isUppercase)
                && Lemmatizer.canonical(entry.headword) == word
                && entry.blocks.contains { !WordClass.of($0.partOfSpeech).isDisjoint(with: slot.licensedBy) }
        }
    }
}

/// **Where a regular inflection sits**, by its ending.
public enum InflectionSlot: String, Sendable, CaseIterable {
    /// A noun's plural, a verb's third person.
    case s
    /// A verb's past and past participle.
    case ed
    /// A verb's present participle.
    case ing
    /// A comparative.
    case er
    /// A superlative.
    case est

    /// **The classes whose entries license the slot.** A verbal ending also takes a noun or an adjective, because
    /// English converts freely — *heavied*, *whinned*, *folated* were each judged right — and a comparative takes an
    /// adjective or an adverb, never a noun: *hedgie* has no *hedgiest*.
    var licensedBy: Set<WordClass> {
        switch self {
        case .s: [.noun, .verb]
        case .ed, .ing: [.verb, .noun, .adjective]
        case .er, .est: [.adjective, .adverb]
        }
    }
}

/// The four classes an entry's part-of-speech label can grant an inflection to.
enum WordClass: Sendable {
    case noun, verb, adjective, adverb

    /// **By whole word, never by prefix or substring** (AGENTS.md), so *pronoun* is not a noun and *transitive verb,* is
    /// a verb; a **proper** noun is not a noun here, since it takes no regular inflection.
    static func of(_ label: String?) -> Set<WordClass> {
        guard let label else { return [] }
        let words = Set(label.lowercased().split { !$0.isLetter }.map(String.init))
        var classes: Set<WordClass> = []
        if words.contains("noun"), !words.contains("proper") { classes.insert(.noun) }
        if words.contains("verb") { classes.insert(.verb) }
        if words.contains("adjective") { classes.insert(.adjective) }
        if words.contains("adverb") { classes.insert(.adverb) }
        return classes
    }
}

/// **English's regular inflections of a word, spelled strictly** — one answer per slot where `RegularInflection` takes
/// every concatenation, because there a wrong "regular" only kept the tagger's lemma, and here it puts a word in front of
/// the reader.
///
/// The rules: *-es* after a sibilant, *-ies*/*-ied*/*-ier*/*-iest* after a consonant and *y*, a final *e* shared
/// (*prided*, never *prideed*), *-ck-* after *c*, and a final consonant **doubled after one vowel in a word of one
/// syllable** (*tipped*, *whinned*) and **never in a longer one** (*hollering*, *pretzeled*): whether a longer word
/// doubles depends on stress, which spelling does not show, and Oxford prints the forms of every word that does
/// (*unzipped*, *inspanned*), which `DictionaryForm.candidate` asks first.
enum RegularSpelling {
    /// The slots in which `term` is `base`'s regular inflection, in `InflectionSlot` order.
    static func slots(of term: String, from base: String) -> [InflectionSlot] {
        let forms = forms(of: base)
        return InflectionSlot.allCases.filter { forms[$0]?.contains(term) == true }
    }

    /// Whether a word has a vowel letter. An abbreviation — *hrs*, *sb*, *chf* — has none, and inflects no regular way.
    static func hasVowel(_ word: String) -> Bool {
        word.lowercased().contains { "aeiouy".contains($0) }
    }

    /// The slot a form printed under a headword sits in — by its ending first, by the class it was printed under for
    /// an irregular one (*dalesmen* is a noun's, so a plural). Nil for an irregular printed under no class.
    static func slot(ofPrinted form: String, as partOfSpeech: String) -> InflectionSlot? {
        for (ending, slot) in [("ing", InflectionSlot.ing), ("est", .est), ("ed", .ed), ("er", .er), ("s", .s)]
        where form.hasSuffix(ending) {
            return slot
        }
        let classes = WordClass.of(partOfSpeech)
        if classes.contains(.noun) { return .s }
        if classes.contains(.verb) { return .ed }
        if !classes.isDisjoint(with: [.adjective, .adverb]) { return .er }
        return nil
    }

    /// Every regular inflection of `base`, by slot.
    static func forms(of base: String) -> [InflectionSlot: Set<String>] {
        let word = base.lowercased()
        let letters = Array(word)
        guard let last = letters.last, letters.count >= 2 else { return [:] }
        let stem = String(word.dropLast())
        let consonantY = last == "y" && !isVowel(at: letters.count - 2, in: letters)
        let doubles = endsInOneVowelAndADoublingConsonant(letters)
        let oneSyllable = syllables(in: letters) == 1
        func regular(_ suffix: String) -> Set<String> {
            guard doubles else { return [word + suffix] }
            return [oneSyllable ? word + String(last) + suffix : word + suffix]
        }

        var forms: [InflectionSlot: Set<String>] = [:]
        if ["s", "x", "z", "ch", "sh"].contains(where: word.hasSuffix) {
            // *quizzes*, *busses*: a one-syllable word may double its sibilant as well.
            forms[.s] = doubles && oneSyllable ? [word + "es", word + String(last) + "es"] : [word + "es"]
        } else if consonantY {
            forms[.s] = [stem + "ies"]
        } else if last == "o" {
            forms[.s] = [word + "s", word + "es"]
        } else {
            forms[.s] = [word + "s"]
        }

        if last == "e" {
            forms[.ed] = [word + "d"]
        } else if consonantY {
            forms[.ed] = [stem + "ied"]
        } else if last == "c" {
            forms[.ed] = [word + "ked", word + "ed"]
        } else {
            forms[.ed] = regular("ed")
        }

        if word.hasSuffix("ie") {
            // *dying*, *tying*: only a word of one syllable turns *ie* into *y*; a longer one keeps it — *stymieing*.
            forms[.ing] = [oneSyllable ? String(word.dropLast(2)) + "ying" : word + "ing"]
        } else if ["ee", "oe", "ye"].contains(where: word.hasSuffix) {
            forms[.ing] = [word + "ing"]
        } else if last == "e" {
            forms[.ing] = [stem + "ing"]
        } else if last == "c" {
            forms[.ing] = [word + "king", word + "ing"]
        } else {
            forms[.ing] = regular("ing")
        }

        if last == "e" {
            forms[.er] = [word + "r"]
            forms[.est] = [word + "st"]
        } else if consonantY {
            forms[.er] = [stem + "ier"]
            forms[.est] = [stem + "iest"]
        } else {
            forms[.er] = regular("er")
            forms[.est] = regular("est")
        }
        return forms
    }

    /// A vowel letter at `index`: *a e i o u*, and *u* only where no *q* stands before it — *quit* has one vowel.
    private static func isVowel(at index: Int, in letters: [Character]) -> Bool {
        guard letters.indices.contains(index), "aeiou".contains(letters[index]) else { return false }
        return !(letters[index] == "u" && index > 0 && letters[index - 1] == "q")
    }

    /// **One vowel, then one consonant that English doubles** — not *h*, *w*, *x* or *y*, which it never doubles, nor
    /// *c*, which takes *k* — with no vowel before the vowel: *tip*, *whin*, *ad*, *holler*; not *superheat*, *relax*.
    private static func endsInOneVowelAndADoublingConsonant(_ letters: [Character]) -> Bool {
        let count = letters.count
        guard count >= 2, let last = letters.last, last.isLetter, !"aeiouchwxy".contains(last),
              isVowel(at: count - 2, in: letters) else { return false }
        return count == 2 || !isVowel(at: count - 3, in: letters)
    }

    /// Runs of vowel letters, with *y* a vowel after a consonant: *tip* 1, *holler* 2, *quit* 1.
    private static func syllables(in letters: [Character]) -> Int {
        var count = 0
        var previousWasVowel = false
        for index in letters.indices {
            let vowel = isVowel(at: index, in: letters)
                || (letters[index] == "y" && index > 0 && !isVowel(at: index - 1, in: letters))
            if vowel, !previousWasVowel { count += 1 }
            previousWasVowel = vowel
        }
        return count
    }
}
