"""Shared fixtures for the make-icon tests. Standard library only.

Run the tests from the repository root:

    python3 -m unittest discover -s Tools/tests

Fixtures copy Tools/icon into a temporary directory and mutate the copy. Tools/icon and
Resources/ are only ever read: Resources/ is the golden output the real sources must reproduce.
"""
from __future__ import annotations

import contextlib
import functools
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
REPO = TOOLS.parent
SCRIPT = TOOLS / "make-icon.py"
DESIGN = REPO / "Tools" / "icon"
GOLDEN = REPO / "Resources"
# Sorted, because `Workspace.listing` is sorted and every test compares the two directly.
# Held in declaration order this matched only by luck of the name: the icon's old name sorted
# before "MenuBarIcon.svg" and "XiaolaiDict.icon" sorts after it, so renaming the app failed 25
# tests that were never about order at all.
OUTPUTS = sorted(["XiaolaiDict.icon", "MenuBarIcon.svg"])
# Outputs to publish where their content does not matter, only that they are a distinct pair.
SYNTHETIC = {
    "XiaolaiDict.icon/icon.json": b'{"synthetic": true}\n',
    "XiaolaiDict.icon/Assets/card.svg": b"<svg synthetic/>\n",
    "MenuBarIcon.svg": b"<svg synthetic tray/>\n",
}


# The package the entry point runs, imported the way the entry point imports it: from beside it.
sys.path.insert(0, str(TOOLS))
from makeicon import artwork, publish, render, sources, whitelist  # noqa: E402

__all__ = ["artwork", "publish", "render", "sources", "whitelist"]  # re-exported for the tests


def outputs(resources: Path) -> dict[str, bytes]:
    """The published outputs under `resources`, by path relative to it."""
    found = {}
    for name in OUTPUTS:
        path = resources / name
        if path.is_dir():
            found.update({str(f.relative_to(resources)): f.read_bytes()
                          for f in path.rglob("*") if f.is_file()})
        elif path.exists():
            found[name] = path.read_bytes()
    return found


@functools.cache
def build() -> dict[str, bytes]:
    """Every output file for the real sources, in memory, with the progress report swallowed.
    Built once for all the tests that need it: a build takes seconds. Never mutate the result."""
    with contextlib.redirect_stdout(io.StringIO()):
        return render.build_outputs(artwork.validate_artwork(sources.parse_sources(DESIGN)))


def run(*args: object) -> subprocess.CompletedProcess:
    """The script as `make icon` runs it: a separate interpreter, so a traceback is visible."""
    return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                          capture_output=True, text=True, timeout=300)


def failing_on_call(n: int, error: BaseException, real, calls: list):
    """A stand-in for `real` that records each call, raises `error` on the n-th and otherwise
    delegates: a fault injected at one exact step of a sequence of file operations."""
    def fake(*args, **kwargs):
        calls.append(args)
        if len(calls) == n:
            raise error
        return real(*args, **kwargs)
    return fake


class Workspace:
    """A private copy of Tools/icon to mutate, and an empty Resources dir to write into."""

    def __init__(self, test: unittest.TestCase) -> None:
        tmp = tempfile.TemporaryDirectory()
        test.addCleanup(tmp.cleanup)
        self.src = Path(tmp.name) / "icon"
        shutil.copytree(DESIGN, self.src)
        self.resources = Path(tmp.name) / "Resources"
        self.resources.mkdir()

    def mutate(self, name: str, old: str, new: str) -> None:
        """Replace the one occurrence of `old`. A fixture edit that matches nothing tests nothing."""
        path = self.src / name
        text = path.read_text()
        if text.count(old) != 1:
            raise AssertionError(f"fixture: {old!r} occurs {text.count(old)} times in {name}")
        path.write_text(text.replace(old, new))

    def seed(self) -> dict[str, bytes]:
        """Previous outputs, including a stale asset, that a failed run must leave exactly as is."""
        assets = self.resources / "XiaolaiDict.icon" / "Assets"
        assets.mkdir(parents=True)
        (self.resources / "XiaolaiDict.icon" / "icon.json").write_bytes(b'{"previous": true}\n')
        (assets / "card.svg").write_bytes(b"<svg previous/>\n")
        (assets / "stale.svg").write_bytes(b"<svg stale/>\n")
        (self.resources / "MenuBarIcon.svg").write_bytes(b"<svg previous tray/>\n")
        return outputs(self.resources)

    def listing(self) -> list[str]:
        """Everything in the Resources dir, hidden entries included: a leftover staging dir shows."""
        return sorted(os.listdir(self.resources))


DARK_CARD = 'fill="url(#front)" stroke='
DARK_BACK = 'fill="#2B2D32" stroke="#2B2D32"'
DARK_BG_RECT = '<rect width="1024" height="1024" fill="url(#bg)">'
DARK_GLOW_STOPS = ('<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.10"></stop>'
                   '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"></stop>')
LINE_1 = '<rect x="354" y="428" width="300" height="34" rx="17">'
SLOT_1 = '<rect x="5.9" y="8.8" width="8.2" height="1.6" rx="0.8"'
SLOT_2 = '<rect x="5.9" y="11.6" width="5.6" height="1.6" rx="0.8" fill="#000"></rect>'
TRAY = "xiaolaidict-tray-slots-Template.svg"
