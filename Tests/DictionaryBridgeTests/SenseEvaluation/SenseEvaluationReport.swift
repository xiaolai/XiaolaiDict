import Foundation
import XiaolaiDictCore

/// The evaluator's report: accuracy, coverage, confidently wrong, the ambiguous favourites and saying nothing, **each
/// reported on its own**, per arm and per split, and the paired comparisons the verdict rests on.
enum SenseEvaluationReport {
    static func render(
        labelled: [SenseEvaluation.Labelled], outcomes: [SenseEvaluation.Variant: SenseEvaluation.Outcomes],
        chose: [SenseEvaluation.Variant: [String: Bool]], development: [String], heldOut: [String],
        weight: Double, verdict: SenseEvaluation.Verdict, versions: [String]
    ) -> String {
        var lines = ["", "embedding part-of-speech bonus — paired evaluation", ""]
        lines += versions.map { "  " + $0 }
        let groups = { (ids: Set<String>) in Set(labelled.filter { ids.contains($0.case.id) }.map(\.case.group)).count }
        lines.append("")
        lines.append("  cases \(labelled.count), headwords \(Set(labelled.map(\.case.group)).count)")
        lines.append("  development \(development.count) cases over \(groups(Set(development))) headwords;"
            + " held out \(heldOut.count) over \(groups(Set(heldOut)))")
        for kind in SenseEvaluation.Kind.allCases {
            let count = labelled.filter { $0.kinds.contains(kind) }.count
            lines.append("    \(kind.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)) \(count)")
        }
        let arms: [SenseEvaluation.Variant] = [.legacyNarrowing] + SenseEvaluation.weights.map { .bonus($0) }
        for (name, ids) in [("development", development), ("held out", heldOut)] {
            lines.append("")
            lines.append("  \(name) (\(ids.count) cases)")
            lines.append("    arm                    right   wrong   amb✓  amb✗  silent  coverage")
            for arm in arms {
                guard let outcome = outcomes[arm] else { continue }
                let tally = SenseEvaluation.Tally(outcome, choices: chose[arm] ?? [:], over: ids)
                let percent = { (count: Int) in String(format: "%5.1f%%", Double(count) / Double(max(ids.count, 1)) * 100) }
                lines.append("    \(arm.description.padding(toLength: 20, withPad: " ", startingAt: 0))"
                    + "  \(percent(tally.right)) \(percent(tally.wrong))  \(String(format: "%4d", tally.ambiguousRight))"
                    + "  \(String(format: "%4d", tally.ambiguousWrong))  \(String(format: "%6d", tally.abstained))"
                    + "  \(percent(tally.chose))")
            }
        }
        lines.append("")
        lines.append("  weight chosen on development: \(weight)")
        if weight > 0, let arm = outcomes[.bonus(weight)], let zero = outcomes[.bonus(0)],
           let legacy = outcomes[.legacyNarrowing] {
            let gain = SenseEvaluation.PairedDifference.of(arm, against: zero, over: heldOut) { $0 == .right }
            lines.append(String(format: "  held out, right vs w = 0: %+d (%d gained, %d lost), paired 95%% [%.4f, %.4f]",
                                gain.worse - gain.better, gain.worse, gain.better, gain.lower, gain.upper))
            for (name, comparator) in [("w = 0", zero), ("legacy narrowing", legacy)] {
                let extra = SenseEvaluation.PairedDifference.of(arm, against: comparator, over: heldOut) { $0 == .wrong }
                lines.append(String(
                    format: "  held out, additional confidently wrong vs %@: %+d (%d new, %d fixed), upper 95%% %.4f",
                    name, extra.worse - extra.better, extra.worse, extra.better, extra.upper))
            }
        }
        switch verdict {
        case .enable(let weight): lines.append("  VERDICT: enable w = \(weight)")
        case .zeroChosen: lines.append("  VERDICT: w = 0 — no weight beat zero on development")
        case .notShown(let reasons):
            lines.append("  VERDICT: not shown — w stays 0")
            lines += reasons.map { "    - " + $0 }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Case by case: every arm's bucket, beside what the case was labelled with.
    static func outcomes(
        labelled: [SenseEvaluation.Labelled], outcomes: [SenseEvaluation.Variant: SenseEvaluation.Outcomes],
        arms: [SenseEvaluation.Variant]
    ) -> String {
        var lines = [(["id", "split", "word", "tag", "label", "kinds"] + arms.map(\.description)).joined(separator: "\t")]
        for item in labelled {
            let fields = [item.case.id, item.split.rawValue, item.case.word, item.tag ?? "-", item.correctLabel ?? "-",
                          item.kinds.map(\.rawValue).sorted().joined(separator: ",")]
                + arms.map { outcomes[$0]?.buckets[item.case.id]?.rawValue ?? "-" }
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
