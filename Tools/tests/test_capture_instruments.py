"""`verify_capture_instruments`, the check that a release carries none of the development instruments and a development
bundle carries all of them, run exactly as `Tools/build-bundle.sh` writes it against a stand-in binary and a stand-in
`nm`.

**An instrument that captures the screen or posts an input event is a deputy** for whoever runs it, with the reader's
grants (ADR-0010; the audit of 2026-10-10 found `--placement-report` able to write any screen region to a file the
caller named and to post a drag, in a release). So a release must refuse each instrument **by its own sentence** — one
sentence shared by all of them was satisfied by any one gate — and must not hold the two capabilities at all: no mouse
event made or posted, no capture of a whole display. A development bundle must hold every one of them, or the gate is
inverted and the stages cannot run.

The stand-ins are positive controls as well: a bundle as each build makes it passes, and each way it can be wrong is
refused.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import pathlib
import re
import stat
import subprocess
import tempfile
import unittest

from ledger_schema import REPO

SCRIPT = REPO / "Tools" / "build-bundle.sh"
PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

# What a release says for each development instrument, one sentence each.
REFUSALS = {flag: f"{flag} is a development instrument and is not built into a release" for flag in (
    "--read-point", "--read-selection", "--reminder-report", "--provider-status", "--spelling-report",
    "--history-report", "--panel-report", "--placement-report")}

# A sentence only each instrument's live code holds.
LIVE = {
    "capture": "is not running, or has no window to find its process by",
    "reminder": "reminder-report: reading this app's requests from the notification center",
    "provider": "provider-status: asking the chosen language-model source one trivial question",
    "spelling": "spelling-report: asking the spell checker about each term the dictionaries miss",
    "developer": "ledger.sqlite.dev-before-clear-",
}

# The selector a capture of a whole display is made with — the instruments' alone; hover captures one window.
DISPLAY_CAPTURE = "initWithDisplay:excludingWindows:"
# What every Swift binary imports, so an import list without it was not read.
ALWAYS_IMPORTED = "_swift_release"
POSTING = ("_CGEventPost", "_CGEventCreateMouseEvent")

# `nm -u`: the imports in STUB_IMPORTS, one a line, or a failure.
NM = """#!/bin/bash
[ "$1" = -u ] || { echo "stub nm: unexpected $*" >&2; exit 64; }
[ "${STUB_NM:-ok}" = fail ] && { echo "nm: error: $2: The file was not recognized as a valid object file" >&2; exit 1; }
for symbol in ${STUB_IMPORTS:-}; do echo "$symbol"; done
exit 0
"""


def function(name: str) -> str:
    """One shell function, as `build-bundle.sh` defines it: from `name() {` to the first line that is `}`."""
    found = re.search(rf"^{name}\(\) {{.*?^}}$", SCRIPT.read_text(), re.MULTILINE | re.DOTALL)
    assert found, f"build-bundle.sh defines no {name}()"
    return found.group(0)


class CaptureInstrumentGateTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.scratch.name)
        self.stubs = root / "stubs"
        self.stubs.mkdir()
        nm = self.stubs / "nm"
        nm.write_text(NM)
        nm.chmod(nm.stat().st_mode | stat.S_IXUSR)
        self.bundle = root / "XiaolaiDict.app"
        self.binary = self.bundle / "Contents/MacOS/XiaolaiDict"
        self.binary.parent.mkdir(parents=True)

    def tearDown(self):
        self.scratch.cleanup()

    def verify(self, release: bool, strings: list[str], imports: list[str], nm: str = "ok") -> subprocess.CompletedProcess:
        # Each string on a line of its own, between filler, as `strings -a` finds them in a binary.
        self.binary.write_text("\n".join(["filler-start", *strings, "filler-end"]) + "\n")
        script = "\n".join([
            "set -euo pipefail",
            "readonly APP_NAME=XiaolaiDict",
            f"is_release() {{ {'true' if release else 'false'}; }}",
            function("verify_capture_instruments"),
            'verify_capture_instruments "$1"',
        ])
        env = {"PATH": f"{self.stubs}:{PATH}", "STUB_IMPORTS": " ".join(imports), "STUB_NM": nm}
        return subprocess.run(["bash", "-c", script, "verify", str(self.bundle)], text=True, capture_output=True,
                              env=env, check=False, timeout=60)

    @staticmethod
    def release_strings() -> list[str]:
        return list(REFUSALS.values())

    @staticmethod
    def development_strings() -> list[str]:
        return [*LIVE.values(), DISPLAY_CAPTURE]

    @staticmethod
    def release_imports() -> list[str]:
        return [ALWAYS_IMPORTED, "_objc_msgSend"]

    @staticmethod
    def development_imports() -> list[str]:
        return [ALWAYS_IMPORTED, "_objc_msgSend", *POSTING]

    def assertPasses(self, done: subprocess.CompletedProcess):
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def assertRefused(self, done: subprocess.CompletedProcess, because: str):
        self.assertNotEqual(done.returncode, 0, f"passed, though {because}: {done.stdout}")

    # The two bundles as their builds make them.

    def test_a_release_as_built_passes(self):
        self.assertPasses(self.verify(True, self.release_strings(), self.release_imports()))

    def test_a_development_bundle_as_built_passes(self):
        self.assertPasses(self.verify(False, self.development_strings(), self.development_imports()))

    # A release.

    def test_a_release_must_refuse_each_instrument_by_its_own_sentence(self):
        for flag, sentence in REFUSALS.items():
            with self.subTest(flag=flag):
                strings = [s for s in self.release_strings() if s != sentence]
                self.assertRefused(self.verify(True, strings, self.release_imports()), f"{flag} is not refused")

    def test_a_release_carrying_any_instruments_own_code_is_refused(self):
        for name, sentence in LIVE.items():
            with self.subTest(live=name):
                done = self.verify(True, [*self.release_strings(), sentence], self.release_imports())
                self.assertRefused(done, f"{name}'s own code is in a release")

    def test_a_release_that_can_post_a_mouse_event_is_refused(self):
        for symbol in POSTING:
            with self.subTest(symbol=symbol):
                done = self.verify(True, self.release_strings(), [*self.release_imports(), symbol])
                self.assertRefused(done, f"a release imports {symbol}")

    def test_a_release_that_can_capture_a_whole_display_is_refused(self):
        done = self.verify(True, [*self.release_strings(), DISPLAY_CAPTURE], self.release_imports())
        self.assertRefused(done, "a release captures a whole display")

    def test_an_import_list_that_was_not_read_says_nothing(self):
        """`nm` failing, or answering with nothing every Swift binary imports, is a scan that read nothing — and a scan
        for an absent symbol that read nothing passes, so it is refused instead."""
        self.assertRefused(self.verify(True, self.release_strings(), self.release_imports(), nm="fail"), "nm failed")
        self.assertRefused(self.verify(True, self.release_strings(), []), "nm listed nothing")

    # A development bundle.

    def test_a_development_bundle_refusing_any_instrument_is_inverted(self):
        for flag, sentence in REFUSALS.items():
            with self.subTest(flag=flag):
                done = self.verify(False, [*self.development_strings(), sentence], self.development_imports())
                self.assertRefused(done, f"a development bundle refuses {flag}")

    def test_a_development_bundle_missing_any_instruments_code_is_refused(self):
        for name, sentence in LIVE.items():
            with self.subTest(live=name):
                strings = [s for s in self.development_strings() if s != sentence]
                self.assertRefused(self.verify(False, strings, self.development_imports()), f"{name} is missing")

    def test_a_development_bundle_that_cannot_post_or_capture_cannot_run_its_stages(self):
        strings = [s for s in self.development_strings() if s != DISPLAY_CAPTURE]
        self.assertRefused(self.verify(False, strings, self.development_imports()), "no display capture")
        self.assertRefused(self.verify(False, self.development_strings(), self.release_imports()), "no posting")
        self.assertRefused(self.verify(False, self.development_strings(), self.development_imports(), nm="fail"),
                           "nm failed")


if __name__ == "__main__":
    unittest.main()
