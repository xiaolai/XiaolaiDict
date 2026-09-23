#!/usr/bin/env python3
"""D6: does the labelled set back the order the shipped ladder actually runs?

Given a `--sense-report` JSON, this answers one question — whether every rung earns the place the
ladder gives it — and says why when it does not. It is a file rather than a heredoc inside `e2e.sh`
because a judgement that decides a release has to be exercised before it ships, and the report it
judges takes ten minutes to produce on the E2E Mac. `Tools/tests/test_ladder_gate.py` feeds it
reports built by hand: the measured numbers pass, a middle rung no better than the one below fails,
an Apple rung that is genuinely absent is skipped while one that refused everything is not, a ladder
that dropped a wrong answer from its top rung fails, and an embedding-first order fails.

Usage: ladder-gate.py <report.json>   — prints one line either way, exits 0 or 2.
"""
import json
import sys

# A rung must be at least this many points better, in top-1 accuracy over the labelled set, than any
# rung below it — and must be confidently wrong no more often. Ten points is the smallest gap the
# set can distinguish: at its size a one-case difference is already worth more than that.
MARGIN = 10
RUNGS = ("localModel", "onDevice", "embedding", "ladder")


def bucket(verdict):
    """The bucket alone. A verdict carries its reason — `abstained (unavailable)` — and the reason
    is what distinguishes an Apple rung that is not on this Mac from one that refused every
    sentence, so it is read separately rather than thrown away."""
    return verdict.split(" ")[0] if verdict else ""


def judge(report):
    """Every refusal the report earns, in the order they are found. Empty means the order stands."""
    refusals = []
    scores = report.get("scores", {})
    cases = report.get("cases", 0)

    def scored(rung, name):
        return scores.get(rung, {}).get(name, 0)

    for rung in RUNGS:
        total = sum(scores.get(rung, {}).values())
        if total != cases:
            refusals.append(f"{rung} scored {total} of {cases} cases")
    if not report.get("localModelInstalled"):
        refusals.append("the local model is not installed, so its rung measured nothing")
    if refusals:
        return refusals

    # **The shipped ladder, in its own order.** Scoring the local model beside the ladder says
    # nothing about where the ladder puts it: reordering it to embedding-first would still pass.
    order = report.get("order") or []
    answers = report.get("answers", [])

    # **`order` is the rungs, and the composite is not one of them.** It is scored beside them
    # (`SenseReport.swift`) so the ladder's answer can be held against its top rung's; a report that
    # named it here would have `earns` below ask whether the ladder earns its place above its own
    # top rung, which the labelled set cannot answer — the ladder's answers *are* the rungs'. There
    # used to be a `continue` inside that loop skipping any pair involving the ladder, which could
    # never run, so the shape it was written against went unchecked. Refused by name instead.
    if "ladder" in order:
        return [f"the report's order names the ladder among its own rungs: {order}"]

    # Apple is skipped only where it is genuinely not on this Mac — every case abstaining *because
    # it is unavailable*. A rung that abstained for any other reason is a rung that ran.
    apple = [row.get("onDevice", "") for row in answers]
    absent = bool(apple) and all("(unavailable)" in verdict for verdict in apple)
    rungs = [rung for rung in order if not (absent and rung == "onDevice")]
    if rungs[:1] != ["localModel"]:
        return [f"the shipped ladder does not run the local model first: {order}"]

    for row in answers:
        # What the ladder answered is what its top rung answered, on every case that rung decided at
        # all — **including the ones it got wrong**. Checking only its right answers let a ladder
        # that quietly dropped the top rung pass whenever that rung was mistaken, which is exactly
        # when the difference between rungs shows.
        top = bucket(row.get("localModel", ""))
        if top in ("right", "wrong"):
            if bucket(row.get("ladder", "")) != top:
                refusals.append(f"the ladder did not carry the local model answer on {row['word']}: "
                                f"{row.get('localModel')} became {row.get('ladder')}")
            # And the same *sense*, not merely the same bucket: two different wrong answers both
            # read as "wrong", so a ladder that dropped its top rung and got a wrong answer from a
            # lower one passed while doing exactly what this is here to catch.
            elif row.get("localModelKey") != row.get("ladderKey"):
                refusals.append(f"the ladder answered {row['word']} with a different sense from the "
                                f"local model: {row.get('ladderKey')} against {row.get('localModelKey')}")
            continue
        # **And where the top rung abstained, the ladder carries the rung below that did decide.**
        # Without this, every case the local model declined asserted nothing at all about the
        # ladder — a ladder that answered those out of thin air, or from a rung it had already
        # passed, read exactly like one falling through correctly.
        below = [rung for rung in rungs[rungs.index("localModel") + 1:]
                 if bucket(row.get(rung, "")) in ("right", "wrong")]
        if not below:
            continue
        first = below[0]
        if bucket(row.get("ladder", "")) != bucket(row.get(first, "")):
            refusals.append(f"the ladder did not fall through to {first} on {row['word']}: "
                            f"{row.get(first)} became {row.get('ladder')}")
        elif row.get("ladderKey") != row.get(first + "Key"):
            refusals.append(f"the ladder answered {row['word']} with a sense no rung gave: "
                            f"{row.get('ladderKey')} against {first}'s {row.get(first + 'Key')}")

    # **Every step of the order is earned, not just the top one.** Apple sits above the embedding
    # rung in the shipped ladder, and a middle rung no better than the one below it, or one that
    # refused every sentence, once passed unexamined.
    def earns(upper, lower):
        gain = (scored(upper, "right") - scored(lower, "right")) / cases * 100
        return gain >= MARGIN and scored(upper, "wrong") <= scored(lower, "wrong")

    # Every rung above every rung below it, not only the adjacent pairs: an order A, B, C where A
    # beats B and B beats C but A is no better than C is not an order anything measured.
    for i, upper in enumerate(rungs):
        for lower in rungs[i + 1:]:
            if not earns(upper, lower):
                refusals.append(f"{upper} does not earn its place above {lower}: "
                                f"{scored(upper, 'right')} right / {scored(upper, 'wrong')} wrong "
                                f"against {scored(lower, 'right')} / {scored(lower, 'wrong')}")
    return refusals


def summary(report):
    scores = report.get("scores", {})
    return "; ".join(f"{rung}: {scores.get(rung, {}).get('right', 0)} right, "
                     f"{scores.get(rung, {}).get('wrong', 0)} wrong"
                     for rung in ("localModel", "onDevice", "embedding"))


def main(argv):
    if len(argv) != 2:
        print("usage: ladder-gate.py <report.json>")
        return 2
    try:
        with open(argv[1]) as file:
            report = json.load(file)
    except (OSError, ValueError) as error:
        print(f"the sense report could not be read: {error}")
        return 2
    refusals = judge(report)
    if refusals:
        print(refusals[0])
        return 2
    print(summary(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
