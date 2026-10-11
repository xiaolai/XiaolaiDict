import CaptureModel
import DictionaryModel
import Foundation
@testable import XiaolaiDictCore

/// **The paired evaluator for the embedding rung's part-of-speech bonus** (ADR-0053 addendum, 2026-10-11).
///
/// Offline and test-only: nothing here is linked by the app or a service. It compares, on **identical candidates**, the
/// narrowing retired on 2026-10-11 (kept here as a comparator and nowhere else), the unfiltered embedding, and the bonus
/// at each weight of a grid declared before anything was measured.
///
/// **Its data is never committed.** A case names a NOAD sense key and is labelled at test time from the reader's own
/// NOAD — the part of speech the correct sense carries, the candidates, the tagger's reading — because dictionary
/// content and anything derived from it may not be distributed (AGENTS.md, "The tool ships; the data it derives does
/// not"). What is committed is this generator and its tests, over synthetic fixtures.
enum SenseEvaluation {
    /// The grid, **declared before the first measurement** and never edited to suit one. Zero is in it, so the
    /// unfiltered embedding is always one of the arms. A cosine distance between a sentence and a definition sits near
    /// 1; the margin the rung needs to choose is `EmbeddingSenseSelector.minimumMargin`, 0.03.
    static let weights: [Double] = [0, 0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15, 0.2]

    /// The bound the decision named: the paired 95% upper bound on the additional confidently-wrong rate must be below
    /// two percentage points against each comparator.
    static let additionalErrorBound = 0.02

    /// One case as it is written down: a sentence a reader might read, the word in it, and the NOAD sense it means —
    /// or nil where the right answer is to abstain.
    struct Case: Equatable, Sendable {
        let id: String
        /// The headword the case belongs to. **The split is by group**, so a headword's cases are never on both sides.
        let group: String
        /// The word as it appears in the sentence, which is what is looked up.
        let word: String
        let correct: String?
        let sentence: String
        let note: String
    }

    enum Split: String, Sendable { case development, heldOut }

    /// FNV-1a over the group's UTF-8 — never `Hasher`, which is seeded per process — so the split is the same on every
    /// run and on every Mac, and enlarging the set never moves a headword from one side to the other. One group in
    /// three is development: 200 of 600.
    static func split(of group: String) -> Split {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in group.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash % 3 == 0 ? .development : .heldOut
    }

    enum ParseError: Error, Equatable {
        case malformed(line: Int, reason: String)
        case duplicateID(String)
    }

    /// `id \t group \t word \t key-or-"-" \t sentence \t note`, one case a line; `#` starts a comment. Strict: a line
    /// that does not parse is an error naming it, never a case skipped.
    static func parse(_ text: String) throws -> [Case] {
        var cases: [Case] = []
        var seen = Set<String>()
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 6 else {
                throw ParseError.malformed(line: index + 1, reason: "\(fields.count) fields, not 6")
            }
            guard fields[0 ... 4].allSatisfy({ !$0.isEmpty }) else {
                throw ParseError.malformed(line: index + 1, reason: "an empty field")
            }
            guard seen.insert(fields[0]).inserted else { throw ParseError.duplicateID(fields[0]) }
            cases.append(Case(
                id: fields[0], group: fields[1], word: fields[2], correct: fields[3] == "-" ? nil : fields[3],
                sentence: fields[4], note: fields[5]))
        }
        return cases
    }

    /// What the reader's dictionary and the tagger say about one case, generated at test time.
    struct Labelled: Sendable {
        let `case`: Case
        let candidates: [SenseCandidate]
        let tag: String?

        var split: Split { SenseEvaluation.split(of: self.case.group) }

        /// The label the correct sense's block carries, nil for an abstention case or an unlabelled block.
        var correctLabel: String? {
            guard let correct = self.case.correct else { return nil }
            return candidates.first { $0.key == correct }?.partOfSpeech
        }

        /// The kinds the decision asked the set to include, read off the data rather than declared by its author.
        var kinds: Set<Kind> {
            var kinds = Set<Kind>()
            guard self.case.correct != nil else { return [.abstention] }
            if self.case.word.lowercased() != self.case.group.lowercased() { kinds.insert(.inflectedOrOtherForm) }
            let labels = Set(SenseCandidates.considered(candidates).compactMap(\.partOfSpeech))
            if labels.count > 1 { kinds.insert(.crossPartOfSpeech) }
            let label = correctLabel
            if label == nil { kinds.insert(.unlabelledSense) }
            if let label, !["noun", "verb", "adjective", "adverb"].contains(label.lowercased()) {
                kinds.insert(.otherOrSubtypeLabel)
            }
            let rivals = SenseCandidates.considered(candidates).filter { $0.partOfSpeech == label }
            if label != nil, rivals.count > 1 { kinds.insert(.samePartOfSpeechRivals) }
            switch (tag, label) {
            case (nil, _): kinds.insert(.untagged)
            case (_, nil): break
            case (let tag?, let label?):
                kinds.insert(PartOfSpeechLabel.matches(label, tag: tag) ? .tagAgrees : .tagDisagrees)
            }
            return kinds
        }
    }

    enum Kind: String, CaseIterable, Sendable {
        case abstention, inflectedOrOtherForm, crossPartOfSpeech, samePartOfSpeechRivals, unlabelledSense
        case otherOrSubtypeLabel, untagged, tagAgrees, tagDisagrees
    }

    /// The arms. `.bonus(0)` is the unfiltered embedding, the shipped rung before the bonus existed.
    enum Variant: Hashable, Sendable, CustomStringConvertible {
        case legacyNarrowing
        case bonus(Double)

        var description: String {
            switch self {
            case .legacyNarrowing: "legacy narrowing"
            case .bonus(let weight): weight == 0 ? "unfiltered (w = 0)" : "bonus w = \(weight)"
            }
        }

        /// The arm's answer, from the case's keyable senses **ranked once** — every arm sees the same distances, so a
        /// difference between arms is the arm and never the embedding answering twice. The preflight is the rung's own,
        /// and the decision is `EmbeddingSenseSelector.decide`, the half of `choose` after ranking; the run checks the
        /// whole of `choose` against this for the arms that matter (`theDecideShortcutIsTheRungsOwnAnswer`).
        func answer(
            _ labelled: Labelled, ranked: [(candidate: SenseCandidate, distance: Double)]
        ) -> SenseSelection {
            switch self {
            case .legacyNarrowing:
                // The retired preflight exactly: drop the unkeyable, then narrow; the rung then scores what is left.
                let narrowed = LegacyPartOfSpeechNarrowing.narrow(
                    SenseCandidates.considered(labelled.candidates), to: labelled.tag)
                let kept = Set(narrowed.map(Self.identity))
                return Self.decide(
                    narrowed, ranked: ranked.filter { kept.contains(Self.identity($0.candidate)) },
                    labelled: labelled, weight: 0)
            case .bonus(let weight):
                return Self.decide(labelled.candidates, ranked: ranked, labelled: labelled, weight: weight)
            }
        }

        private static func identity(_ candidate: SenseCandidate) -> String { candidate.entryID + "\u{1F}" + candidate.key }

        private static func decide(
            _ field: [SenseCandidate], ranked: [(candidate: SenseCandidate, distance: Double)],
            labelled: Labelled, weight: Double
        ) -> SenseSelection {
            switch SenseCandidates.preflight(field, reading: labelled.case.sentence, context: .complete) {
            case .settled(let answer): return answer
            case .ask:
                return EmbeddingSenseSelector(partOfSpeechWeight: weight).decide(ranked, partOfSpeech: labelled.tag)
            }
        }
    }

    /// One arm's outcomes, **case by case**: aggregate counts can hide two failures exchanged for each other.
    struct Outcomes: Sendable {
        var buckets: [String: LabelledSenses.Bucket] = [:]

        func count(_ bucket: LabelledSenses.Bucket, in ids: [String]) -> Int {
            ids.filter { buckets[$0] == bucket }.count
        }
    }

    /// Five buckets and the coverage, over one split.
    struct Tally: Equatable, Sendable {
        var cases = 0, right = 0, wrong = 0, ambiguousRight = 0, ambiguousWrong = 0, abstained = 0
        /// Answered with a sense — the share of cases on which a mark is drawn at all.
        var chose = 0

        init(_ outcomes: Outcomes, choices: [String: Bool], over ids: [String]) {
            cases = ids.count
            right = outcomes.count(.right, in: ids)
            wrong = outcomes.count(.wrong, in: ids)
            ambiguousRight = outcomes.count(.ambiguousRight, in: ids)
            ambiguousWrong = outcomes.count(.ambiguousWrong, in: ids)
            abstained = outcomes.count(.abstained, in: ids)
            chose = ids.filter { choices[$0] == true }.count
        }
    }

    /// A paired difference of two proportions on the same cases, from the discordant pairs alone.
    ///
    /// `worse` counts cases where the arm under test had the property and the comparator did not; `better` the reverse.
    /// The interval is the adjusted Wald interval of Agresti and Min (2005) — half a case added to each cell of the
    /// paired table — because the plain Wald interval collapses to a point when either discordant count is zero, which
    /// is exactly when a small set would most flatter an arm. Declared before measuring; two-sided 95%.
    struct PairedDifference: Equatable, Sendable {
        let worse: Int, better: Int, cases: Int

        var difference: Double { Double(worse - better) / Double(cases) }

        private var adjusted: (estimate: Double, standardError: Double) {
            let worse = Double(self.worse) + 0.5, better = Double(self.better) + 0.5, cases = Double(self.cases) + 2
            let estimate = (worse - better) / cases
            let variance = ((worse + better) - (worse - better) * (worse - better) / cases) / (cases * cases)
            return (estimate, variance.squareRoot())
        }

        var upper: Double { adjusted.estimate + 1.959_964 * adjusted.standardError }
        var lower: Double { adjusted.estimate - 1.959_964 * adjusted.standardError }

        /// Paired on `property`, over `ids`.
        static func of(
            _ arm: Outcomes, against comparator: Outcomes, over ids: [String],
            where property: (LabelledSenses.Bucket?) -> Bool
        ) -> PairedDifference {
            var worse = 0, better = 0
            for id in ids {
                let mine = property(arm.buckets[id]), theirs = property(comparator.buckets[id])
                if mine && !theirs { worse += 1 }
                if theirs && !mine { better += 1 }
            }
            return PairedDifference(worse: worse, better: better, cases: ids.count)
        }
    }

    /// **The rule that picks the weight on the development half**, declared before the first run: the weight with the
    /// most right answers among those that are wrong no more often than the unfiltered rung *and* the legacy narrowing;
    /// a tie goes to the smaller weight. Zero wins unless something beats it.
    static func chooseWeight(
        _ arms: [Variant: Outcomes], over ids: [String]
    ) -> Double {
        guard let zero = arms[.bonus(0)], let legacy = arms[.legacyNarrowing] else { return 0 }
        let ceiling = min(zero.count(.wrong, in: ids), legacy.count(.wrong, in: ids))
        var best = (weight: 0.0, right: zero.count(.right, in: ids))
        for weight in weights where weight > 0 {
            guard let arm = arms[.bonus(weight)], arm.count(.wrong, in: ids) <= ceiling else { continue }
            let right = arm.count(.right, in: ids)
            if right > best.right { best = (weight, right) }
        }
        return best.weight
    }

    enum Verdict: Equatable, Sendable {
        /// Every condition held: ship this weight.
        case enable(Double)
        /// The development half chose zero, so there is nothing to enable.
        case zeroChosen
        /// A condition failed; each reason is named.
        case notShown([String])
    }

    /// **The held-out gate**, as the decision states it: a measurable benefit over zero weight, no more confidently
    /// wrong answers than either comparator, and the paired 95% upper bound on the additional confidently-wrong rate
    /// below two points against each. "Measurable" is declared as a paired 95% lower bound on the gain in right answers
    /// above zero.
    static func verdict(for weight: Double, _ arms: [Variant: Outcomes], over ids: [String]) -> Verdict {
        guard weight > 0 else { return .zeroChosen }
        guard let arm = arms[.bonus(weight)], let zero = arms[.bonus(0)], let legacy = arms[.legacyNarrowing]
        else { return .notShown(["an arm was not measured"]) }
        var reasons: [String] = []
        // Paired the other way round: `worse` here counts the cases the weight got right and zero did not.
        let gain = PairedDifference.of(arm, against: zero, over: ids) { $0 == .right }
        if !(gain.lower > 0) {
            reasons.append(String(
                format: "no measurable gain over w = 0: %+d right, paired 95%% lower bound %.4f",
                gain.worse - gain.better, gain.lower))
        }
        for (name, comparator) in [("w = 0", zero), ("the legacy narrowing", legacy)] {
            let extra = PairedDifference.of(arm, against: comparator, over: ids) { $0 == .wrong }
            if extra.worse > extra.better {
                reasons.append("more confidently wrong than \(name): \(extra.worse) against \(extra.better)")
            }
            if !(extra.upper < additionalErrorBound) {
                reasons.append(String(
                    format: "additional error against %@ has a paired 95%% upper bound of %.4f, not below %.2f",
                    name, extra.upper, additionalErrorBound))
            }
        }
        return reasons.isEmpty ? .enable(weight) : .notShown(reasons)
    }
}

/// **Evaluation only — the narrowing retired on 2026-10-11 (ADR-0053), kept as a comparator and never in
/// production.** The code is the deleted `PartOfSpeechFilter.narrow` verbatim: keep the senses whose label names the
/// tag by whole word, and keep everything where the tag is absent or nothing matches.
enum LegacyPartOfSpeechNarrowing {
    static func narrow(_ candidates: [SenseCandidate], to partOfSpeech: String?) -> [SenseCandidate] {
        guard let partOfSpeech, !partOfSpeech.isEmpty else { return candidates }
        let wanted = partOfSpeech.lowercased()
        let matching = candidates.filter { candidate in
            candidate.partOfSpeech?.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .contains(Substring(wanted)) ?? false
        }
        return matching.isEmpty ? candidates : matching
    }
}

/// **Evaluation only**: rung 1b as it shipped until 2026-10-11 — the unkeyable dropped, the field narrowed to the tag,
/// and the embedding with no bonus deciding what is left. The six-case labelled set pins it at 3 right and 1 wrong, so
/// the trade the narrowing's retirement made stays visible beside the rung that replaced it.
struct LegacyNarrowingComparator: SenseSelecting {
    func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection {
        await EmbeddingSenseSelector(partOfSpeechWeight: 0).choose(
            from: LegacyPartOfSpeechNarrowing.narrow(SenseCandidates.considered(candidates), to: partOfSpeech),
            reading: sentence, context: context, partOfSpeech: partOfSpeech)
    }
}
