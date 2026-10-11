import CaptureModel
import DictionaryModel
import Foundation

/// **How far a correction is from what the reader wrote, and by what one change** — the checker's word is offered only
/// where it is one edit away (ADR-0054 part B, the owner's ruling of 2026-10-11).
///
/// Optimal string alignment over lowercase characters: a substitution, an insertion, a deletion or **an adjacent
/// transposition** each count one — *recieve* is one edit from *receive*. Case is not an edit: the checker keeps its
/// capitalisation and the reader may not have. Distance says a typo is plausible; it never says which of two words was
/// meant (*inducteed* is one edit from *inducted* and one from the inductee's regular past alike).
public struct SpellingEdit: Equatable, Sendable {
    /// The change that turns the term into the word, named from the term's side: *penetrateed* → *penetrated* is a
    /// deletion, *recieve* → *receive* a transposition.
    public enum Operation: String, Sendable, Hashable, CaseIterable {
        case substitution
        case insertion
        case deletion
        case transposition
    }

    public let distance: Int
    /// The one operation, where the distance is exactly one; nil otherwise.
    public let operation: Operation?

    public init(distance: Int, operation: Operation?) {
        self.distance = distance
        self.operation = operation
    }

    public static func between(_ term: String, _ word: String) -> SpellingEdit {
        let from = Array(term.lowercased()), to = Array(word.lowercased())
        let distance = alignment(from, to)
        return SpellingEdit(distance: distance, operation: distance == 1 ? operation(from, to) : nil)
    }

    /// Restricted Damerau–Levenshtein: no substring is edited twice, which is what "one typing slip" means.
    private static func alignment(_ from: [Character], _ to: [Character]) -> Int {
        if from.isEmpty || to.isEmpty { return max(from.count, to.count) }
        var table = Array(repeating: Array(repeating: 0, count: to.count + 1), count: from.count + 1)
        for row in 0...from.count { table[row][0] = row }
        for column in 0...to.count { table[0][column] = column }
        for row in 1...from.count {
            for column in 1...to.count {
                let cost = from[row - 1] == to[column - 1] ? 0 : 1
                var best = min(table[row - 1][column] + 1, table[row][column - 1] + 1, table[row - 1][column - 1] + cost)
                if row > 1, column > 1, from[row - 1] == to[column - 2], from[row - 2] == to[column - 1] {
                    best = min(best, table[row - 2][column - 2] + 1)
                }
                table[row][column] = best
            }
        }
        return table[from.count][to.count]
    }

    /// Which single change it was, given that there was exactly one.
    private static func operation(_ from: [Character], _ to: [Character]) -> Operation {
        if to.count == from.count + 1 { return .insertion }
        if to.count + 1 == from.count { return .deletion }
        let differing = from.indices.filter { from[$0] != to[$0] }
        return differing.count == 2 ? .transposition : .substitution
    }
}

/// **What the reader's form table prints the term as** — the strongest evidence a miss has, and the first rule
/// (`SpellingSuggester`): a term printed under one base is that base's, whatever the spelling rules or the checker say.
enum PrintedEvidence: Equatable, Sendable {
    /// Printed under one base, or under several of which the lookup's own lemma names one.
    case unique(String)
    /// Printed under several bases, and nothing in the lookup says which.
    case ambiguous([String])

    /// Nil where the table prints nothing for the term, or there is no table.
    static func of(_ term: String, lemma: Lemma?, in table: FormTable?) -> PrintedEvidence? {
        guard let entry = table?.entry(for: Lemmatizer.canonical(term)) else { return nil }
        var bases: [String] = []
        for reading in entry.readings where !bases.contains(reading.lemma) { bases.append(reading.lemma) }
        if bases.count == 1 { return .unique(bases[0]) }
        // **The context resolves it only where the lemmatiser stands by its reading**, as `DictionaryForm` requires.
        if let lemma, lemma.basis <= .likely, let chosen = bases.first(where: { $0 == Lemmatizer.canonical(lemma.text) }) {
            return .unique(chosen)
        }
        return .ambiguous(bases)
    }
}

/// **A base and every form the reader's dictionaries or English spelling give it** — what "outside that base's family"
/// means when a checker's word competes with a morphological explanation (rule 4).
///
/// Generous on purpose: membership only lets a correction through a guard, so a form in any slot, either doubling,
/// counts. The guard it serves blocks words that are none of these.
struct MorphologicalFamily: Sendable {
    let base: String
    private let members: Set<String>
    /// What the table prints under the base — the neighbours a near-miss of the term is measured against.
    let printed: [String]

    init(base: String, table: FormTable?) {
        self.base = Lemmatizer.canonical(base)
        printed = (table?.printed(under: base) ?? []).map { Lemmatizer.canonical($0.form) }
        var members: Set<String> = [self.base]
        members.formUnion(printed)
        for doubling in [true, false, nil] as [Bool?] {
            for forms in RegularSpelling.forms(of: self.base, doubling: doubling).values { members.formUnion(forms) }
        }
        self.members = members
    }

    func contains(_ word: String) -> Bool { members.contains(Lemmatizer.canonical(word)) }

    /// **Whether the term is one edit from a form printed under the base** — *proped* from *propped*, *gobes* from
    /// *gobs*: the term reads as a slip of that base's form, so a checker's word from another family is a rival
    /// explanation, not a correction.
    func hasPrintedNeighbour(of term: String) -> Bool {
        printed.contains { SpellingEdit.between(term, $0).distance == 1 }
    }
}

/// **A productive irregular inflection the reader's dictionaries support** — *dalesmen* is *dalesman*'s plural by the
/// *-men* pattern, whether or not a dictionary prints it — so the checker's *salesmen* is a rival, not a correction
/// (rule 4). An ambiguity guard and never an offer: nothing is offered by the pattern.
enum IrregularPattern: Sendable {
    /// A noun in *-man* makes its plural in *-men*.
    case menToMan

    static let all: [IrregularPattern] = [.menToMan]

    /// The base the pattern reads the term as, or nil where it does not apply.
    func base(of term: String) -> String? {
        switch self {
        case .menToMan:
            let word = Lemmatizer.canonical(term)
            guard word.hasSuffix("men"), word.count > "men".count + 1 else { return nil }
            return String(word.dropLast("men".count)) + "man"
        }
    }

    /// **Lexically supported**: an entry headed by the base in lowercase gives it the class the pattern inflects — a
    /// noun for *-men*. A base the dictionaries do not have, or have as something else, supports nothing.
    func isSupported(_ base: String, by outcome: LookupOutcome) -> Bool {
        guard case .entries(let entries, _) = outcome else { return false }
        return entries.contains { entry in
            entry.match == .exact && !entry.headword.contains(where: \.isUppercase)
                && Lemmatizer.canonical(entry.headword) == base
                && entry.blocks.contains { WordClass.of($0.partOfSpeech).contains(.noun) }
        }
    }
}

/// **Everything a miss's offer was decided from, and the rule that decided it** — what `--spelling-report` prints, so
/// an abstention is as explainable as an offer. The reader sees only `offer`; the rest is for the instrument and the
/// log, never a second line on the card.
public struct SpellingDecision: Equatable, Sendable {
    /// The term as the reader looked it up.
    public let term: String
    /// How it was captured — the same thresholds apply to every source; it is recorded, never weighed. Nil for a term
    /// typed or named rather than captured.
    public let capture: CaptureQuality.Source?
    /// What the card is offered: one suggestion, a refusal before anything was asked, or an abstention and why.
    public let offer: SpellingOffer
    /// The term's dictionary form as a rule proposed it, and whether its lookup bore it out — nil where none was.
    public let form: FormTrial?
    /// The base the lemmatiser proposed, kept for the ambiguity guards even where no rule made it a form.
    public let proposedBase: String?
    /// The checker's word and how it fared — nil where the checker was not asked or had nothing.
    public let correction: CorrectionTrial?

    /// A dictionary form tried.
    public struct FormTrial: Equatable, Sendable {
        public let word: String
        public let evidence: DictionaryForm.Evidence
        /// Whether the form's lookup bore it out; nil where it was never looked up.
        public let supported: Bool?
        public let edit: SpellingEdit

        public init(word: String, evidence: DictionaryForm.Evidence, supported: Bool?, edit: SpellingEdit) {
            (self.word, self.evidence, self.supported, self.edit) = (word, evidence, supported, edit)
        }
    }

    /// The checker's correction tried.
    public struct CorrectionTrial: Equatable, Sendable {
        public let word: String
        /// Whether the reader's dictionaries have it; nil where it was never looked up.
        public let verified: Bool?
        public let edit: SpellingEdit

        public init(word: String, verified: Bool?, edit: SpellingEdit) {
            (self.word, self.verified, self.edit) = (word, verified, edit)
        }
    }

    /// **The rule that decided**, by name — the deciding step of `SpellingSuggester.decide`: the offered evidence, the
    /// refusal, or the abstention.
    public var rule: String {
        switch offer {
        case .offered(let suggestion): suggestion.evidence.rule
        case .refused: "refused"
        case .abstained(let why): why.rawValue
        }
    }
}
