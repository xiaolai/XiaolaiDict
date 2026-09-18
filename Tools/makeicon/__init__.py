"""XiaolaiDict's icon generator, one module per stage. Tools/make-icon.py runs them in this order:

  sources    read each designer file into what it draws, refusing anything else
  artwork    cross-check the files against each other, into one Design
  render     turn the Design into output bytes: layer SVGs, the glow PNG, icon.json, the tray SVG
  publish    replace the outputs in the Resources dir, both or neither, crash-safe

whitelist holds what the sources may contain, and this module what every stage shares.
Standard library only, and runs on macOS's own python3 (3.9) as well as newer ones.
"""
from __future__ import annotations

import sys
from typing import NoReturn

PROG = "make-icon.py"  # the entry point; every error is reported under its name
SVG_NS = "http://www.w3.org/2000/svg"
CANVAS = 1024
TRAY = 22


def fail(msg: str) -> NoReturn:
    sys.exit(f"{PROG}: error: {msg}")
