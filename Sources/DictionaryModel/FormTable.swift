import Foundation

/// The inflections the reader's own dictionaries **print**, as a lemmatiser can ask about them.
///
/// `NLTagger` is the source of a lemma (ADR-0002) and it has two failures no table of hand-picked forms
/// closes: it **answers nothing** for a word it has not met — measured 2026-10-06 against the 14,167 forms
/// Oxford prints, it left 3,786 unchanged in a sentence, `unravelled`, `marvelling`, `purees` and
/// `squirrelled` among them — and it sometimes **answers a different word**, `broke` → `brake`. A dictionary
/// states, entry by entry, which word each inflected form belongs to; this is that statement, held where a
/// lemma is decided (ADR-0051).
///
/// **A judge, not a replacement.** `judge` is asked after the tagger has answered and can only
/// *add* — fill a gap, or refuse a lemma the dictionary contradicts. A form the table does not list is the
/// tagger's alone, so a reader with no dictionary read yet is exactly where they were.
///
/// Built in the dictionary service, which links the container reader; read in the app and the service alike.
/// **Never distributed**: it is Oxford's content, derived on the reader's own Mac from what Apple licensed
/// to it.
public struct FormTable: Sendable, Equatable {
    /// One reading of a form: the headword it inflects and the class of the block it was printed in.
    public struct Reading: Sendable, Hashable, Comparable {
        public let lemma: String
        /// `verb`, `noun`, `adjective`, `adverb`, or empty where the block named none. **Empty is "unknown",
        /// and compatible with every class** — never a fifth class.
        public let partOfSpeech: String

        public init(lemma: String, partOfSpeech: String) {
            self.lemma = FormTable.canonical(lemma)
            self.partOfSpeech = partOfSpeech
        }

        public static func < (lhs: Reading, rhs: Reading) -> Bool {
            (lhs.lemma, lhs.partOfSpeech) < (rhs.lemma, rhs.partOfSpeech)
        }
    }

    public struct Entry: Sendable, Equatable {
        /// Every headword this form is printed under, in a stable order. Never empty.
        public let readings: [Reading]
        /// Whether the form is also a headword in its own right — *saw*, *found*, *left*. Such a form is an
        /// inflection of one word and the base of another, so only the sentence can say which, and the
        /// table never decides it.
        public let isOwnHeadword: Bool
    }

    /// What this table was read from: one `identifier\tcontentVersion` per dictionary, then the extraction's
    /// own version. **Compared, never interpreted** — equal means nothing it was built from has changed, so
    /// a service launch that finds the stored table current skips a body walk that costs seconds.
    public let sources: [String]
    private let entries: [String: Entry]
    /// The dictionary's own one-word titles. What a regular inflection it does not print is looked up in.
    private(set) var words: Set<String>

    /// `forms` carries one set of readings per form. A form with no reading, an empty lemma, or a lemma
    /// equal to itself says nothing and is dropped, so a caller cannot build an entry that judges nothing.
    public init(sources: [String], forms: [String: Set<Reading>], ownHeadwords: Set<String>,
                words: Set<String> = []) {
        var built: [String: Entry] = [:]
        built.reserveCapacity(forms.count)
        let own = Set(ownHeadwords.map(Self.canonical))
        for (form, readings) in forms {
            let key = Self.canonical(form)
            let useful = readings.filter { !$0.lemma.isEmpty && $0.lemma != key }
            guard !key.isEmpty, !useful.isEmpty else { continue }
            let merged = Set(built[key]?.readings ?? []).union(useful)
            built[key] = Entry(readings: merged.sorted(), isOwnHeadword: own.contains(key))
        }
        self.sources = sources
        self.entries = built
        // **Each title twice where it carries a diacritic.** `Boötes` is a title, and `bootes` — what a reader or a
        // recogniser writes — must find it, or `bootes` is read as the plural of `boot`.
        self.words = Self.withFolded(words.map(Self.canonical))
    }

    public var count: Int { entries.count }

    /// The dictionary's one-word titles. For a caller measuring detachment against them.
    public var wordList: Set<String> { words }

    /// Every form the table judges, sorted. For a caller measuring the table against its own contents.
    public var forms: [String] { entries.keys.sorted() }

    public func entry(for form: String) -> Entry? { entries[Self.canonical(form)] }

    /// `words` and, for each one carrying a non-ASCII character, its folded spelling. **Only those**: folding 76,000
    /// titles costs a second on this Mac and 99% of them are ASCII, where folding is the identity.
    static func withFolded(_ words: some Sequence<String>) -> Set<String> {
        var out = Set<String>()
        for word in words {
            out.insert(word)
            if !word.utf8.allSatisfy({ $0 < 0x80 }) { out.insert(folded(word)) }
        }
        return out
    }

    static func folded(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: nil)
    }

    /// **`Lemmatizer.canonical`, called and not copied**: a table keyed one way and asked the other finds nothing,
    /// and nothing says so.
    static func canonical(_ text: String) -> String { Lemmatizer.canonical(text) }

    // MARK: - The judgement

    /// What the table says about a lemma the tagger has already given.
    public enum Verdict: Sendable, Equatable {
        /// The table has nothing to add; the tagger's answer, or the grammar's, stands.
        case keep
        /// This is the lemma — the tagger gave none, or gave a word the dictionary contradicts.
        case lemma(String)
        /// The tagger's answer is wrong and the table cannot say what is right. The surface form stays, and
        /// is reported as unresolved: a wrong lemma is never confident (ADR-0002).
        case unresolved
    }

    /// Whether `tagged` — the lemma `NLTagger` gave `word`, nil for none — should stand.
    ///
    /// `partOfSpeech` is the class the word is being used as in its sentence, where there is one and the
    /// tagger committed to it; it chooses between printed readings and is otherwise ignored.
    ///
    /// **Four cases, and only the last two act.**
    /// 1. *The tagger agrees with a printed reading.* Kept.
    /// 2. *The tagger's word is a regular inflection of nothing printed but of the form* — `leaves` → `leave`
    ///    where Oxford prints only `leaf`. Oxford prints what is awkward, not what is regular, so silence about
    ///    `leave` is not a contradiction. Kept.
    /// 3. *The tagger gave a different word that is neither* — `broke` → `brake`. `brake`'s past is `braked`;
    ///    nothing leads there. If exactly one printed reading fits the word's class that is the lemma,
    ///    otherwise the answer is `unresolved`.
    /// 4. *The tagger gave nothing, or left the form unchanged*, and the form is not a word in its own right
    ///    — one reading that fits is the lemma.
    ///
    /// **A form that is also a headword is never filled**, which is what keeps `found` out of *find* in *they
    /// will found a company*: `AmbiguousPastForm` and the grammar around the word decide those.
    public func judge(_ word: String, tagged: String?, partOfSpeech: String?, isName: Bool = false) -> Verdict {
        guard let entry = entries[word] else {
            // **Not printed, and the tagger gave nothing or something the dictionary does not list**: the form may
            // still be a regular inflection of a word the dictionary lists — `abuelas` under *abuela* — which
            // Oxford does not print because it is regular. Never a name (`Barnes` is not `barn`). Where the
            // tagger answered a *listed* word it stands; where it answered one nothing lists (`cancelling` →
            // `canceling`) and a listed base exists, the listing wins.
            guard !isName, let base = detached(word) else { return .keep }
            let answered = tagged.flatMap { $0.isEmpty || $0 == word ? nil : $0 }
            guard let answered else { return .lemma(base) }
            return words.contains(answered) || words.contains(Self.folded(answered)) || answered == base
                ? .keep : .lemma(base)
        }
        // **The class narrows between readings and never removes the only one.** The tagger's class for a word
        // it does not know is poor — measured, it called `abuelas` an adjective and `swore` a noun — so a class
        // that fits nothing is ignored rather than trusted: a form printed under one headword is that
        // headword's whatever the class, and the class matters only where the dictionary printed several.
        let compatible = entry.readings.filter {
            partOfSpeech == nil || $0.partOfSpeech.isEmpty || $0.partOfSpeech == partOfSpeech
        }
        let fitting = Set((compatible.isEmpty ? entry.readings : compatible).map(\.lemma))

        if let tagged, !tagged.isEmpty, tagged != word {
            if entry.readings.contains(where: { $0.lemma == tagged }) { return .keep }
            if RegularInflection.isInflection(word, of: tagged) { return .keep }
            return fitting.count == 1 ? .lemma(fitting.first ?? word) : .unresolved
        }
        guard !entry.isOwnHeadword, fitting.count == 1, let lemma = fitting.first else { return .keep }
        return .lemma(lemma)
    }

    /// The one headword `word` is a regular inflection of, where the dictionary lists exactly one.
    ///
    /// **A word the dictionary lists is never detached** — `bus` is not `bu`, `lens` is not `len` — and a form
    /// that detaches to two headwords (`axed` → *ax*, *axe*) is left alone: a wrong lemma is never confident.
    /// Only the regular suffixes, and each candidate is checked by `RegularInflection` before it is looked up,
    /// so the spelling rules (doubling, `y → ie`, dropped `e`) cannot be bypassed by a loose strip. Comparatives
    /// are not detached: `-er` is as often an agent (`enjoyer`), which is a word and not an inflection.
    func detached(_ word: String) -> String? {
        guard !words.isEmpty, word.count >= 3, !words.contains(word), !words.contains(Self.folded(word)) else { return nil }
        let bases = RegularInflection.bases(of: word).union(RegularInflection.irregularBases(of: word))
            .filter { words.contains($0) }
        if bases.count == 1 { return bases.first }
        return bases.isEmpty ? compounded(word) : nil
    }

    /// A closed-class prefix on an irregular form the dictionary prints — `overran` is *over* + `ran`, and `ran`
    /// is printed under *run* — where the **compound is itself a listed word**. The listing is the check: `unfed`
    /// would be *unfeed*, which no dictionary lists, so it is refused. A form whose remainder is also a word of its
    /// own (`rebound`) is left to the grammar, as `found` is.
    func compounded(_ word: String) -> String? {
        for prefix in RegularInflection.prefixes where word.hasPrefix(prefix) {
            let rest = String(word.dropFirst(prefix.count))
            guard rest.count >= 3, let entry = entries[rest], !entry.isOwnHeadword else { continue }
            let lemmas = Set(entry.readings.filter { $0.partOfSpeech == "verb" }.map { prefix + $0.lemma })
            if lemmas.count == 1, let lemma = lemmas.first, words.contains(lemma) { return lemma }
        }
        return nil
    }

    // MARK: - On disk

    /// **Bump this whenever the extraction or the judgement's inputs change, not only the file's shape.**
    /// The sources line already carries the dictionaries' own versions, which say whether *they* changed;
    /// nothing says this code did, and a stored table built by older extraction would be accepted as current.
    /// `InflectionInventory.formatVersion` is the extraction's half and `FormTable` records both, so either
    /// moving rebuilds it.
    public static let formatVersion = "forms/2"

    /// A counted header, then the sources, then one form per line:
    /// `form`, `1` when it is also a headword, and one `class:lemma` per reading — class empty where unknown.
    ///
    /// **Flat tab-separated text, for the reason the phrase inventory is** — read whole on every launch, 14 k
    /// lines, and nothing queries it but a dictionary lookup in memory.
    public func encoded() -> String {
        // **A form or lemma carrying a tab or newline is skipped, not escaped.** None measured does, and an
        // escape scheme for a case that does not arise is a parser nobody has tested.
        let writable = entries.filter { form, entry in
            !Self.breaksTheFormat(form)
                && !entry.readings.contains { Self.breaksTheFormat($0.lemma) || Self.breaksTheFormat($0.partOfSpeech) }
        }
        let titles = words.filter { !Self.breaksTheFormat($0) }.sorted()
        var lines = ["\(Self.formatVersion)\t\(sources.count)\t\(writable.count)\t\(titles.count)"]
        lines.append(contentsOf: sources.map { $0.replacingOccurrences(of: "\n", with: " ") })
        for form in writable.keys.sorted() {
            guard let entry = writable[form] else { continue }
            let readings = entry.readings.map { "\($0.partOfSpeech):\($0.lemma)" }
            lines.append(([form, entry.isOwnHeadword ? "1" : "0"] + readings).joined(separator: "\t"))
        }
        lines.append(contentsOf: titles)
        return lines.joined(separator: "\n")
    }

    private static func breaksTheFormat(_ text: String) -> Bool {
        text.contains("\t") || text.contains("\n")
    }

    /// Nil where this is not a table of a version this build reads — **refused, never guessed at**, and
    /// refused when short of what its header promised, because a half-written table is worse than none.
    public init?(decoding text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first else { return nil }
        let fields = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == Self.formatVersion,
              let sourceCount = Int(fields[1]), let formCount = Int(fields[2]), let wordCount = Int(fields[3]),
              sourceCount >= 0, formCount >= 0, wordCount >= 0 else { return nil }
        // **Subtracted, never added**: a header claiming `Int.max` lines would trap on the sum in a process the
        // reader's lookups run in, where a bad cache must be refused, not fatal.
        var remaining = lines.count - 1
        for declared in [sourceCount, formCount, wordCount] {
            guard declared <= remaining else { return nil }
            remaining -= declared
        }
        let sources = lines[1 ..< 1 + sourceCount].map(String.init)
        var forms: [String: Set<Reading>] = [:]
        var own = Set<String>()
        for line in lines[(1 + sourceCount) ..< (1 + sourceCount + formCount)] {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, !parts[0].isEmpty, parts[1] == "0" || parts[1] == "1" else { return nil }
            var readings = Set<Reading>()
            for field in parts.dropFirst(2) {
                // The class is whatever precedes the first colon; no class contains one and no lemma is
                // empty, so the split is unambiguous.
                guard let colon = field.firstIndex(of: ":"), field.index(after: colon) < field.endIndex else { return nil }
                readings.insert(Reading(lemma: String(field[field.index(after: colon)...]),
                                        partOfSpeech: String(field[..<colon])))
            }
            forms[parts[0], default: []].formUnion(readings)
            if parts[1] == "1" { own.insert(parts[0]) }
        }
        let titles = Set(lines[(1 + sourceCount + formCount) ..< (1 + sourceCount + formCount + wordCount)].map(String.init))
        guard titles.count == wordCount, !titles.contains("") else { return nil }
        // The titles were canonical when they were written, so they are not canonicalised again: that was most of
        // the 1.5 s a launch spent reading 76,000 of them. A hand-edited file that breaks this finds nothing.
        var table = FormTable(sources: sources, forms: forms, ownHeadwords: own)
        table.words = Self.withFolded(titles)
        // A line that decoded to nothing useful was dropped by the initialiser; the count says so.
        guard table.count == formCount else { return nil }
        self = table
    }
}

/// Whether a form is the **regular** inflection of a lemma — added by rule, which a dictionary does not
/// print and `NLTagger` handles.
///
/// Used only to tell *a tagger answer the table does not list* from *a tagger answer the table
/// contradicts*: `leaves` is `leave` regularly and `leaf` irregularly, and Oxford prints only the second.
/// It is deliberately a short list of suffix rules and not a lemmatiser: wrongly saying "regular" keeps the
/// tagger's answer, which is where the table started, and wrongly saying "not regular" lets the table
/// override with a reading the dictionary printed — so both directions fail towards a defensible lemma.
enum RegularInflection {
    /// Every base `form` could be the regular inflection of by stripping a suffix — a candidate, not an answer:
    /// the caller asks whether the dictionary lists it. Each is checked against `isInflection`, so a base that
    /// does not give the form back by the spelling rules is never offered.
    /// Closed-class prefixes that make a compound of an irregular verb: *overran*, *undid*, *withdrew*.
    static let prefixes = ["counter", "inter", "under", "fore", "with", "over", "out", "mis", "pre", "sub", "up", "down", "re", "un"]

    /// Bases for the **patterned irregular** forms a dictionary lists and does not print: *calves*, *cacti*,
    /// *bacteria*, *larvae*, *indices*, *analyses*, *firemen*, *lying*. Candidates only, and not checked by
    /// `isInflection` — they are irregular — so the caller's lookup in the title list is the whole check.
    static func irregularBases(of form: String) -> Set<String> {
        let rules: [(suffix: String, becomes: [String])] = [
            ("ves", ["f", "fe"]), ("i", ["us", "o", "e"]), ("a", ["um", "on"]), ("ae", ["a"]), ("ices", ["ex", "ix"]),
            ("ses", ["sis"]), ("men", ["man"]), ("ying", ["ie"]), ("ata", ["a"]), ("e", ["a"]),
        ]
        var out = Set<String>()
        for rule in rules where form.hasSuffix(rule.suffix) && form.count > rule.suffix.count + 1 {
            let stem = String(form.dropLast(rule.suffix.count))
            for replacement in rule.becomes { out.insert(stem + replacement) }
        }
        return out
    }

    static func bases(of form: String) -> Set<String> {
        var out = Set<String>()
        func add(_ base: String) {
            if base.count >= 2, isInflection(form, of: base) { out.insert(base) }
        }
        func dropping(_ count: Int) -> String { String(form.dropLast(count)) }
        let letters = Array(form)
        func doubled(before suffixLength: Int) -> Bool {
            letters.count > suffixLength + 1 && letters[letters.count - suffixLength - 1] == letters[letters.count - suffixLength - 2]
        }
        // Superlatives, and the comparative that ends `-ier`: no agent noun ends `-est`, and `-ier` from a `y` word is
        // a comparative far more often than an agent. Plain `-er` is left out, as `enjoyer` is why.
        if form.hasSuffix("iest") { add(dropping(4) + "y") }
        if form.hasSuffix("ier") { add(dropping(3) + "y") }
        if form.hasSuffix("est") {
            add(dropping(3)); add(dropping(2))
            if doubled(before: 3) { add(dropping(4)) }
        }
        if form.hasSuffix("ies") { add(dropping(3) + "y"); add(dropping(1)) }
        if form.hasSuffix("ied") { add(dropping(3) + "y") }
        if form.hasSuffix("es") { add(dropping(2)) }
        if form.hasSuffix("s"), !form.hasSuffix("ss") { add(dropping(1)) }
        if form.hasSuffix("ed") {
            add(dropping(2)); add(dropping(1))
            if doubled(before: 2) { add(dropping(3)) }
            if form.hasSuffix("cked") { add(dropping(3)) }
        }
        if form.hasSuffix("ing") {
            add(dropping(3)); add(dropping(3) + "e")
            if doubled(before: 3) { add(dropping(4)) }
            // The `k` a hard `c` takes — `picnicking` — is taken out again.
            if form.hasSuffix("cking") { add(dropping(4)) }
        }
        return out
    }

    static func isInflection(_ form: String, of lemma: String) -> Bool {
        guard form != lemma, !lemma.isEmpty else { return false }
        var candidates: Set<String> = [
            lemma + "s", lemma + "es", lemma + "ed", lemma + "d", lemma + "ing", lemma + "er", lemma + "est",
        ]
        let stem = String(lemma.dropLast())
        if lemma.hasSuffix("e") {
            // `nice` → `nicer`, `nicest`, `making`: the `e` is dropped or shared.
            candidates.formUnion([stem + "ing", lemma + "r", lemma + "st"])
        }
        if lemma.hasSuffix("y") {
            candidates.formUnion([stem + "ies", stem + "ied", stem + "ier", stem + "iest"])
        }
        if let last = lemma.last, !"aeiouyw".contains(last) {
            // Doubling — *abet* → *abetted*, British *travel* → *travelled*, *bus* → *busses* — and the
            // `k` a hard `c` takes, *picnic* → *picnicking*.
            let doubled = lemma + String(last)
            candidates.formUnion([doubled + "ed", doubled + "ing", doubled + "er", doubled + "est", doubled + "es"])
            if last == "c" { candidates.formUnion([lemma + "ked", lemma + "king", lemma + "ker"]) }
        }
        return candidates.contains(form)
    }
}
