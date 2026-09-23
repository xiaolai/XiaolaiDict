"""The D6 gate's judgement, exercised before it decides a release.

The report it judges takes ten minutes to produce on the E2E Mac, so a gate that was wrong could
only be found out by a run that had already happened. These reports are built by hand instead: the
numbers actually measured pass, and each way the ladder could be wrong is refused by name.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import copy
import importlib.util
import pathlib
import unittest

GATE = pathlib.Path(__file__).resolve().parents[1] / "e2e" / "ladder-gate.py"
_spec = importlib.util.spec_from_file_location("ladder_gate", GATE)
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

# What was measured on the E2E Mac on 2026-09-23, inside the signed bundle: Qwen3.5-4B 6 right and
# 0 wrong, Apple's on-device model 5 and 1, `NLEmbedding` 3 and 1. Six cases decide the order.
WORDS = ["hold", "charge", "run", "fine", "sanction", "content"]


def report(local=("right",) * 6, apple=("right",) * 5 + ("wrong",),
           embedding=("right",) * 3 + ("wrong",) + ("abstained (tooClose)",) * 2,
           ladder=None, order=("localModel", "onDevice", "embedding")):
    """A sense report, one verdict per word per rung. The ladder follows its top rung unless a
    caller says otherwise, which is what makes a ladder that drifts from it expressible here."""
    rows = []
    for index, word in enumerate(WORDS):
        row = {"word": word, "localModel": local[index], "onDevice": apple[index],
               "embedding": embedding[index]}
        for rung in ("localModel", "onDevice", "embedding"):
            row[rung + "Key"] = f"{word}.{rung}" if row[rung].split(" ")[0] in ("right", "wrong") else None
        decided = ladder[index] if ladder else None
        if decided is None:
            for rung in order:
                if row[rung].split(" ")[0] in ("right", "wrong"):
                    decided, row["ladderKey"] = row[rung], row[rung + "Key"]
                    break
            else:
                decided, row["ladderKey"] = "abstained (unavailable)", None
        else:
            row["ladderKey"] = row.get(decided[1] + "Key") if isinstance(decided, tuple) else row["localModelKey"]
            decided = decided[0] if isinstance(decided, tuple) else decided
        row["ladder"] = decided
        rows.append(row)

    scores = {}
    for rung in ("localModel", "onDevice", "embedding", "ladder"):
        counted = {}
        for row in rows:
            counted[row[rung].split(" ")[0]] = counted.get(row[rung].split(" ")[0], 0) + 1
        scores[rung] = counted
    return {"cases": len(WORDS), "localModelInstalled": True, "order": list(order),
            "answers": rows, "scores": scores}


class LadderGateTests(unittest.TestCase):
    def test_the_measured_ladder_passes(self):
        self.assertEqual(gate.judge(report()), [])

    def test_a_rung_that_scored_fewer_cases_than_the_set_is_refused(self):
        broken = report()
        broken["scores"]["embedding"] = {"right": 2}
        self.assertIn("embedding scored 2 of 6 cases", gate.judge(broken))

    def test_a_model_that_is_not_installed_measures_nothing(self):
        broken = report()
        broken["localModelInstalled"] = False
        self.assertIn("the local model is not installed, so its rung measured nothing", gate.judge(broken))

    def test_an_embedding_first_order_is_refused(self):
        refusals = gate.judge(report(order=("embedding", "onDevice", "localModel")))
        self.assertTrue(refusals and "does not run the local model first" in refusals[0], refusals)

    def test_a_middle_rung_no_better_than_the_one_below_is_refused(self):
        # Apple at 3 right, the same as the embedding rung: it has not earned the place above it.
        refusals = gate.judge(report(apple=("right",) * 3 + ("wrong",) * 3))
        self.assertTrue(any("onDevice does not earn its place above embedding" in why for why in refusals), refusals)

    def test_an_apple_rung_that_is_absent_is_skipped(self):
        # Not on this Mac at all: every case abstains because it is unavailable, and the order is
        # then read without it.
        absent = report(apple=("abstained (unavailable)",) * 6)
        self.assertEqual(gate.judge(absent), [])

    def test_an_apple_rung_that_refused_everything_is_not_skipped(self):
        # A rung that ran and declined every sentence is a rung that was measured, and it has not
        # earned its place. This is the case that reads exactly like absence and is not.
        refusals = gate.judge(report(apple=("abstained (refused)",) * 6))
        self.assertTrue(any("onDevice does not earn its place" in why for why in refusals), refusals)

    def test_a_ladder_that_dropped_a_wrong_answer_from_its_top_rung_is_refused(self):
        # The local model got *fine* wrong; the ladder answered it right. That means the ladder is
        # not the ladder that was measured, however much better the answer looks.
        drifted = report(local=("right", "right", "right", "wrong", "right", "right"),
                         ladder=("right", "right", "right", "right", "right", "right"))
        refusals = gate.judge(drifted)
        self.assertTrue(any("did not carry the local model answer on fine" in why for why in refusals), refusals)

    def test_a_ladder_that_answered_with_a_different_sense_is_refused(self):
        same_bucket = report()
        same_bucket["answers"][0]["ladderKey"] = "hold.somewhere-else"
        refusals = gate.judge(same_bucket)
        self.assertTrue(any("a different sense from the local model" in why for why in refusals), refusals)

    def test_a_ladder_that_did_not_fall_through_is_refused(self):
        # The top rung abstained on *sanction*; Apple answered it. A ladder that reported something
        # else there answered from a rung it had already passed, or from nowhere — and until this
        # check existed, every case the top rung declined asserted nothing at all.
        # Apple is weakened to 4 right here so the top rung, now at 5, still earns its place: this
        # test is about the fall-through, and a report that failed D6 as well would pass it for the
        # wrong reason.
        abstained = report(local=("right",) * 4 + ("abstained (undecided)", "right"),
                           apple=("right", "right", "right", "wrong", "right", "abstained (refused)"),
                           embedding=("right",) * 2 + ("wrong",) + ("abstained (tooClose)",) * 3)
        self.assertEqual(gate.judge(abstained), [], "the honest fall-through must pass")

        drifted = copy.deepcopy(abstained)
        drifted["answers"][4]["ladder"] = "wrong"
        refusals = gate.judge(drifted)
        self.assertTrue(any("did not fall through to onDevice on sanction" in why for why in refusals), refusals)

    def test_a_ladder_that_fell_through_to_a_sense_no_rung_gave_is_refused(self):
        abstained = report(local=("right",) * 4 + ("abstained (undecided)", "right"),
                           apple=("right", "right", "right", "wrong", "right", "abstained (refused)"),
                           embedding=("right",) * 2 + ("wrong",) + ("abstained (tooClose)",) * 3)
        abstained["answers"][4]["ladderKey"] = "sanction.nowhere"
        refusals = gate.judge(abstained)
        self.assertTrue(any("a sense no rung gave" in why for why in refusals), refusals)


if __name__ == "__main__":
    unittest.main()
