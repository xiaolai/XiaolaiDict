"""The shortcut stage's card check, run as `Tools/e2e.sh` writes it, against a stand-in panel report.

**A check about the lookup panel reads the `Lookup` window alone** (AGENTS.md, end-to-end tests): an open
Library carries the same sentence on its cards. The shortcut stage's poll and its assertion both read
every window the app had, so a Library card holding "meeting" and the fixture's sentence passed the
stage with no lookup panel on screen at all (audit-fix round 3, #11).

The block from the failure markers to the verdict is read out of the stage and run in bash; `panel`
is a stand-in that prints the report the test wrote, `pass` and `flunk` are recorders, and the poll runs once.

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

SCRIPT = REPO / "Tools" / "e2e.sh"
PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
SENTENCE = "The meeting ended after we stopped meeting at noon."


def text() -> str:
    return SCRIPT.read_text()


def function(name: str) -> str:
    found = re.search(rf"^{name}\(\) {{.*?^}}$", text(), re.MULTILINE | re.DOTALL)
    assert found, f"e2e.sh defines no {name}()"
    return found.group(0)


def card_check() -> str:
    """The shortcut stage's poll and assertion: from the failure markers to the card's verdict."""
    stage = re.search(r"^if want shortcut; then\n(.*?)(?=^if want )", text(), re.MULTILINE | re.DOTALL)
    assert stage, "e2e.sh has no shortcut stage"
    found = re.search(r"^    card_failure_markers=.*?^    \); then pass \"shortcut: the card answers[^\n]*\n",
                      stage.group(1), re.MULTILINE | re.DOTALL)
    assert found, "the shortcut stage's card check was not found"
    return found.group(0)


def window(title: str, *texts: str) -> dict:
    return {"title": title, "texts": list(texts)}


class ShortcutCardTests(unittest.TestCase):
    def verdict(self, *windows: dict, frontmost: str = "com.apple.TextEdit") -> str:
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            report = root / "panel.json"
            report.write_text(json.dumps({"frontmost": frontmost, "windows": list(windows)}, ensure_ascii=False))
            panel = root / "panel"
            panel.write_text(f"#!/bin/bash\ncat '{report}'\n")
            panel.chmod(0o755)
            body = "\n".join([
                "set -uo pipefail",
                'pass() { echo "PASS  $*"; }',
                'flunk() { echo "FAIL  $*"; }',
                "sleep() { :; }",
                # One pass of the poll: what is under test is what it and the assertion read, not how long.
                "seq() { echo 1; }",
                f'helpers="{root}"',
                function("lookup_windows"),
                card_check(),
            ])
            done = subprocess.run(["bash", "-c", body], text=True, capture_output=True, env={"PATH": PATH},
                                  check=False, timeout=120)
            lines = [line for line in done.stdout.splitlines() if line.startswith(("PASS", "FAIL"))]
            self.assertEqual(len(lines), 1, f"one verdict expected: {done.stdout}\n{done.stderr}")
            return lines[0]

    def test_a_library_card_alone_is_not_the_lookup_panel(self):
        line = self.verdict(window("Library", "meeting", SENTENCE))
        self.assertTrue(line.startswith("FAIL"), f"a Library card passed for the lookup panel: {line}")

    def test_the_lookup_panel_answering_passes(self):
        """The positive control: the panel itself, headed by the word and carrying the sentence."""
        line = self.verdict(window("Lookup", "meet", SENTENCE))
        self.assertTrue(line.startswith("PASS"), line)

    def test_the_sentence_must_be_on_the_lookup_panel_not_beside_it(self):
        line = self.verdict(window("Library", "meeting", SENTENCE), window("Lookup", "meeting", "noon"))
        self.assertTrue(line.startswith("FAIL"), f"the sentence was taken from a Library card: {line}")
        self.assertIn("does not carry the sentence", line)

    def test_a_lookup_panel_still_waiting_beside_a_library_card_fails(self):
        line = self.verdict(window("Library", "meeting", SENTENCE),
                            window("Lookup", "Looking up “meeting” in your dictionaries…"))
        self.assertTrue(line.startswith("FAIL"), line)


if __name__ == "__main__":
    unittest.main()
