"""`Tools/e2e/keys.swift --hold`, the held key the `review` stage presses: when it posts each event.

The helper posts real keyboard events, which belong on the E2E Mac and never on the one that builds
(AGENTS.md), so it is not run for its events here. `--plan` prints the schedule the posting path
follows — the same function, read once — and posts nothing, which is what this checks:

- **a hold shorter than the keyboard's initial delay is released when asked**: a down and an up and no
  repeat between, as a keyboard sends it. The helper used to sleep the whole initial delay first, so a
  0.1 s hold was held 0.3 s while it reported 0.1;
- a long hold repeats from the initial delay at the interval while one more still fits, and is released
  at its own end;
- the stage's own hold posts enough repeats for its positive control (`review.py` asks for five).

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import json
import pathlib
import re
import subprocess
import tempfile
import unittest

from ledger_schema import REPO

SOURCE = REPO / "Tools" / "e2e" / "keys.swift"
REVIEW = REPO / "Tools" / "e2e" / "review.py"
# kVK_ANSI_2, the key the stage holds. Nothing is posted: `--plan` exits before any event is made.
KEY = "19"
INITIAL_DELAY, INTERVAL = 0.3, 0.033


class HoldScheduleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        cls.binary = pathlib.Path(cls.scratch.name) / "keys"
        built = subprocess.run(["xcrun", "swiftc", "-Onone", str(SOURCE), "-o", str(cls.binary)],
                               text=True, capture_output=True, check=False, timeout=300)
        assert built.returncode == 0, built.stderr

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def plan(self, seconds: str) -> dict:
        done = subprocess.run([str(self.binary), KEY, "--hold", seconds, "--plan"], text=True,
                              capture_output=True, check=False, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)

    def test_a_hold_shorter_than_the_initial_delay_is_released_when_asked(self):
        plan = self.plan("0.1")
        self.assertEqual(plan["repeatsAt"], [])
        self.assertAlmostEqual(plan["upAt"], 0.1)

    def test_a_long_hold_repeats_from_the_initial_delay_and_is_released_at_its_end(self):
        plan = self.plan("1.5")
        repeats = plan["repeatsAt"]
        self.assertAlmostEqual(repeats[0], INITIAL_DELAY)
        for earlier, later in zip(repeats, repeats[1:]):
            self.assertAlmostEqual(later - earlier, INTERVAL)
        self.assertLess(repeats[-1] + INTERVAL, 1.5)
        self.assertGreaterEqual(repeats[-1] + 2 * INTERVAL, 1.5, "the repeats stop more than an interval early")
        self.assertAlmostEqual(plan["upAt"], 1.5)

    def test_the_stages_hold_posts_enough_repeats_for_its_positive_control(self):
        seconds = re.search(r'^HOLD_SECONDS = "([0-9.]+)"$', REVIEW.read_text(), re.MULTILINE).group(1)
        self.assertGreaterEqual(len(self.plan(seconds)["repeatsAt"]), 5)

    def test_the_hold_reports_the_instant_the_stage_counts_a_grade_from(self):
        """The posting path posts real keys, so it is read rather than run: what it prints is what
        `review.py` reads `downAt` from, and a rename on either side would fail the drive there."""
        printed = re.findall(r'^print\("(\{.*\})"\)$', SOURCE.read_text(), re.MULTILINE)[-1]
        self.assertIn('\\"downAt\\":\\(downAt)', printed)
        self.assertIn('posted["downAt"]', REVIEW.read_text())

    def test_plan_needs_a_hold(self):
        done = subprocess.run([str(self.binary), KEY, "--plan"], text=True, capture_output=True,
                              check=False, timeout=30)
        self.assertEqual(done.returncode, 64)
        self.assertIn("--plan", done.stderr)


if __name__ == "__main__":
    unittest.main()
