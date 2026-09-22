#!/usr/bin/env python3
"""Generate XiaolaiDict's app icon and menu-bar icon from the designer's art in Tools/icon/.

Writes two things into <Resources dir>:
  XiaolaiDict.icon/   the Icon Composer document the Makefile compiles with actool
  MenuBarIcon.svg     the menu-bar template image

Single source, and a narrow contract: **geometry is emitted verbatim, and only paint is rewritten.**
A layer asset is the designer's own markup with its fill and stroke set to white; the colour then
lives in icon.json, per appearance. Nothing re-describes the art, so there is no second description
for it to drift from.

The art is authored one file per layer per appearance — background, contour and cross, in light,
dark and (for the two marks) mono — so a layer's geometry is written down two or three times and
nothing in SVG makes those copies agree. This script makes them: a layer's appearances must be
byte-identical once colour is taken out, and that check is the only witness there is, because the
outputs are built from the light files alone.

Strict on purpose: every element and attribute in the sources is either understood or refused. Art
this script cannot reproduce faithfully stops the run; it is never quietly approximated. The one
thing that must not slip through is paint in a form the whitelist does not know — it would ride
into the layer unrewritten and cover the colour the system means to assign.

Both outputs are replaced together or not at all: a run that fails leaves the previous ones as they
were, and a run killed in the middle of replacing them is finished or undone by the next one.

The stages live in the makeicon package beside this file; its __init__ lists them. Standard library
only, and runs on macOS's own python3 (3.9) as well as newer ones.
Usage: Tools/make-icon.py <Tools/icon dir> <Resources dir>  (or `make icon`)
Tests: python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import signal
import sys
from pathlib import Path

# Named explicitly: Python puts a script's own directory on the path, but not under -P or
# PYTHONSAFEPATH, and the package must be found either way.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from makeicon import PROG, fail  # noqa: E402
from makeicon.artwork import validate_artwork  # noqa: E402
from makeicon.publish import publish_outputs, recover  # noqa: E402
from makeicon.render import build_outputs  # noqa: E402
from makeicon.sources import parse_sources  # noqa: E402


def main(argv: list[str]) -> None:
    if len(argv) != 2:
        fail(f"usage: {PROG} <Tools/icon dir> <Resources dir>")
    src, resources = Path(argv[0]), Path(argv[1])
    if not resources.is_dir():
        fail(f"no such directory {resources}")
    # First, before this run's art can be refused: a publish that died mid-swap left the pair
    # mixed, and that is repaired whether or not this run gets as far as publishing.
    recover(resources)
    files = build_outputs(validate_artwork(parse_sources(src)))
    publish_outputs(resources, files)
    print(f"wrote into {resources}")
    for rel in sorted(files):
        print(f"  {rel}  {(resources / rel).stat().st_size} B")


if __name__ == "__main__":
    # SIGTERM (a killed `make`, a timeout) interrupts like Ctrl-C, so a swap in progress is rolled
    # back rather than abandoned halfway.
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    try:
        main(sys.argv[1:])
    except KeyboardInterrupt:
        fail("interrupted")
