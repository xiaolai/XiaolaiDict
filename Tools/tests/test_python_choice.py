"""`Tools/python.sh` — which Python the tool suites run on.

The tool code needs 3.12 or later: the suites 3.10 (`zip(strict=)`, the WAL behaviour of the `sqlite3` module the ledger
tests drive), and `e2e.sh`'s validators 3.12 (a multi-line f-string, PEP 701).
`make test-tools` ran `python3`, whichever came first on PATH: a Homebrew upgrade on 2026-10-10 left its new Python
unlinked, macOS's 3.9.6 answered instead, and three tests failed on the interpreter, not on the code — a red gate that
said nothing about the repository. So the choice is made in one place, by version, and none is said, never guessed.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "python.sh"


class ThePythonTheSuitesRunOn(unittest.TestCase):
    def setUp(self):
        self.bin = Path(tempfile.mkdtemp(prefix="python-choice-"))
        self.addCleanup(shutil.rmtree, self.bin, True)

    def interpreter(self, name: str, version: tuple[int, int]):
        """A stand-in answering the version check the way that version would."""
        major, minor = version
        tool = self.bin / name
        tool.write_text("#!/bin/bash\n"
                        f'[ "$1" = -c ] && exit $(( {major} * 100 + {minor} >= 312 ? 0 : 1 ))\n'
                        f'echo "Python {major}.{minor}"\n')
        tool.chmod(tool.stat().st_mode | stat.S_IXUSR)

    def choose(self) -> subprocess.CompletedProcess:
        # Only the stand-ins and what the script itself needs: nothing of this Mac's own Pythons.
        return subprocess.run(["/bin/bash", str(SCRIPT)], capture_output=True, text=True, timeout=60, check=False,
                              env={"PATH": f"{self.bin}:/bin"})

    def test_python3_of_a_supported_version_is_chosen(self):
        self.interpreter("python3", (3, 14))
        self.interpreter("python3.11", (3, 11))
        done = self.choose()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), str(self.bin / "python3"))

    def test_an_older_python3_gives_way_to_a_versioned_one(self):
        self.interpreter("python3", (3, 9))
        self.interpreter("python3.11", (3, 11))
        self.interpreter("python3.12", (3, 12))
        self.interpreter("python3.13", (3, 13))
        done = self.choose()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), str(self.bin / "python3.13"), "not the newest supported one")

    def test_none_supported_is_a_failure_that_says_so(self):
        self.interpreter("python3", (3, 9))
        self.interpreter("python3.11", (3, 11))
        done = self.choose()
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")
        self.assertIn("3.12", done.stderr)

    def test_the_makefile_runs_the_suites_on_the_chosen_python(self):
        makefile = (SCRIPT.parents[1] / "Makefile").read_text()
        self.assertIn("Tools/python.sh", makefile)
        recipe = makefile[makefile.index("\ntest-tools:"):]
        recipe = recipe[:recipe.index("\n\n")]
        self.assertNotIn("\tpython3 ", recipe, "a suite still runs on whichever python3 comes first")


if __name__ == "__main__":
    unittest.main()


class TheHarnessRunsOnTheChosenPython(unittest.TestCase):
    """`e2e.sh` makes `python3` the chosen interpreter on both Macs: sourced here, sent with every remote script there, and
    the provider's stand-in launcher — a script of its own, where no shell function reaches — given its path."""

    def test_sourced_it_defines_the_choice_and_answers_nothing(self):
        done = subprocess.run(["/bin/bash", "-c", f". {SCRIPT}; type -t xiaolaidict_python"], capture_output=True,
                              text=True, timeout=60, check=False)
        self.assertEqual(done.stdout.strip(), "function", done.stderr)

    def test_sent_as_a_remote_script_under_set_u_it_chooses_without_running(self):
        """As `e2e.sh` sends it: on stdin to `bash -s`, where `BASH_SOURCE` is empty, under `set -euo pipefail`."""
        stand_ins = Path(tempfile.mkdtemp(prefix="python-remote-"))
        self.addCleanup(shutil.rmtree, stand_ins, True)
        tool = stand_ins / "python3.13"
        tool.write_text('#!/bin/bash\n[ "$1" = -c ] && exit 0\n')
        tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
        script = "set -euo pipefail\n" + SCRIPT.read_text() + '\necho "chose $(xiaolaidict_python)"\n'
        done = subprocess.run(["/bin/bash", "-s"], input=script, capture_output=True, text=True, timeout=60,
                              check=False, env={"PATH": f"{stand_ins}:/bin"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), f"chose {tool}")

    def test_both_macs_python3_is_the_choice(self):
        text = (SCRIPT.parent / "e2e.sh").read_text()
        self.assertEqual(text.count('python3() { "$XIAOLAIDICT_PYTHON" "$@"; }'), 2, "here and on the E2E Mac")
        self.assertIn('cat Tools/python.sh >>"$remote_scripts/common.sh"', text)
        self.assertIn("python=${XIAOLAIDICT_PYTHON:-}", text)
        self.assertNotIn("python=$(command -v python3)", text, "the launcher would run whichever python3 is first")
