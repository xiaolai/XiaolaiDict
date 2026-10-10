"""`Tools/python.sh` — which Python the tool suites run on.

The suites need 3.10 or later (`zip(strict=)`, and the WAL behaviour of the `sqlite3` module the ledger tests drive).
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
                        f'[ "$1" = -c ] && exit $(( {major} * 100 + {minor} >= 310 ? 0 : 1 ))\n'
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
        done = self.choose()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), str(self.bin / "python3.12"), "not the newest supported one")

    def test_none_supported_is_a_failure_that_says_so(self):
        self.interpreter("python3", (3, 9))
        done = self.choose()
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")
        self.assertIn("3.10", done.stderr)

    def test_the_makefile_runs_the_suites_on_the_chosen_python(self):
        makefile = (SCRIPT.parents[1] / "Makefile").read_text()
        self.assertIn("Tools/python.sh", makefile)
        recipe = makefile[makefile.index("\ntest-tools:"):]
        recipe = recipe[:recipe.index("\n\n")]
        self.assertNotIn("\tpython3 ", recipe, "a suite still runs on whichever python3 comes first")


if __name__ == "__main__":
    unittest.main()
