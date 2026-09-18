"""Cross-checking the sources against each other, into the one Design the outputs are made from.

The flats must share the layers' geometry exactly (README: "One geometry across every appearance and
size"), the layer files and xiaolaidict-icon.svg must agree on the light colours, and the tray's slots must
sit where render.tray_svg's mask-free rewrite reproduces them exactly.
"""
from __future__ import annotations

import math
import xml.etree.ElementTree as ET
from dataclasses import dataclass

from . import fail
from .sources import FLATS, TRAY_SOURCE, Drawn, Gradient, Radial, Sources, Tray
from .whitelist import GEOMETRY_ATTRS, polygon


def geometry(el: ET.Element) -> tuple:
    return tuple(el.get(a) for a in GEOMETRY_ATTRS)


@dataclass(frozen=True)
class Appearance:
    """Every colour one flat reference assigns, keyed by role."""

    card: Gradient
    stack_back: str
    stack_front: str
    ink: str
    secondary_opacity: float


def appearance_of(name: str, drawn: list[Drawn]) -> Appearance:
    """The colours one appearance paints its stack, card and entry lines with."""
    back, front, card = (d for d in drawn if d.role == "shape")
    lines = [d for d in drawn if d.role == "line"]
    if not (isinstance(back.paint, str) and isinstance(front.paint, str)):
        fail(f"{name}: expected the stack painted with solid colours")
    if not isinstance(card.paint, Gradient):
        fail(f"{name}: expected the card painted with a linear gradient")
    if len({d.paint for d in lines}) != 1:  # more than one <g> could give them more than one
        fail(f"{name}: expected every entry line in one ink")
    if lines[0].opacity != 1.0 or lines[1].opacity != lines[2].opacity:
        fail(f"{name}: expected line 1 opaque and lines 2-3 sharing one opacity")
    return Appearance(card.paint, back.paint, front.paint, lines[0].paint, lines[1].opacity)


def grounds(drawn: list[Drawn]) -> list[Gradient | Radial]:
    return [d.paint for d in drawn if d.role == "ground"]


def convex(pts: list[tuple[float, float]]) -> bool:
    """Strictly convex: the outline turns the same way at every vertex, and goes round once."""
    n, turns = len(pts), []
    for i in range(n):
        (ax, ay), (bx, by), (cx, cy) = pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
        ux, uy, vx, vy = bx - ax, by - ay, cx - bx, cy - by
        turns.append(math.atan2(ux * vy - uy * vx, ux * vx + uy * vy))
    same_way = all(t > 0 for t in turns) or all(t < 0 for t in turns)
    return same_way and math.isclose(abs(sum(turns)), 2 * math.pi)


def inside_by(pts: list[tuple[float, float]], x: float, y: float) -> float:
    """Signed distance from (x, y) to the nearest edge of a convex polygon; positive inside."""
    n = len(pts)
    area = sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1] for i in range(n))
    sign = 1 if area > 0 else -1
    dists = []
    for i in range(n):
        (x1, y1), (x2, y2) = pts[i], pts[(i + 1) % n]
        cross = (x2 - x1) * (y - y1) - (y2 - y1) * (x - x1)
        dists.append(sign * cross / math.hypot(x2 - x1, y2 - y1))
    return min(dists)


def check_tray(tray: Tray) -> None:
    """The mask-free rewrite (see render.tray_svg) covers exactly the mask's area only if every slot lies
    clear of the hexagon's stroke and of every other slot. Measuring that clearance needs a convex
    hexagon."""
    pts = polygon(tray.d)
    if not convex(pts):
        fail(f"{TRAY_SOURCE}: the hexagon must be convex for the slot clearance check to hold")
    half = float(tray.stroke_width) / 2
    for x, y, w, h, rx in tray.slots:
        if rx * 2 > min(w, h):
            fail(f"{TRAY_SOURCE}: slot corner radius larger than half the slot")
        clearance = min(inside_by(pts, cx, cy) for cx in (x, x + w) for cy in (y, y + h))
        if clearance <= half:
            fail(f"{TRAY_SOURCE}: slot at ({x}, {y}) reaches the hexagon's stroke; "
                 "the even-odd rewrite would differ")
    for i, a in enumerate(tray.slots):
        for b in tray.slots[i + 1 :]:
            if a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]:
                fail(f"{TRAY_SOURCE}: slots overlap; even-odd would re-fill the overlap")


@dataclass(frozen=True)
class Design:
    """Everything the outputs are made from, cross-checked across the sources."""

    stack_back: ET.Element
    stack_front: ET.Element
    card: ET.Element
    lines: tuple[ET.Element, ...]
    light: Appearance
    dark: Appearance
    tinted: Appearance
    ground_light: Gradient
    ground_dark: Gradient
    glow: Radial
    tray: Tray


def validate_artwork(sources: Sources) -> Design:
    art = sources.art
    # Geometry, from the layer files. SVG paint order is back-to-front.
    layers = art["xiaolaidict-icon-layer-2-stack.svg"] + art["xiaolaidict-icon-layer-3-card.svg"]
    shapes = [geometry(d.el) for d in layers]
    for name in FLATS:
        got = [geometry(d.el) for d in art[name] if d.role != "ground"]
        if got != shapes:
            fail(f"{name}: geometry differs from the layer files\n  want {shapes}\n  got  {got}")

    # Colours per appearance. Light is read from the layer files and must agree with the flat.
    light = appearance_of("xiaolaidict-icon.svg", art["xiaolaidict-icon.svg"])
    layer_light = appearance_of("the layer files", layers)
    if layer_light != light:
        fail(f"layer files and xiaolaidict-icon.svg disagree on colour:\n  {layer_light}\n  {light}")
    dark = appearance_of("xiaolaidict-icon-dark.svg", art["xiaolaidict-icon-dark.svg"])
    tinted = appearance_of("xiaolaidict-icon-tinted.svg", art["xiaolaidict-icon-tinted.svg"])

    # Grounds; read_art has already held each to the full canvas. The tinted flat's is not used:
    # the system draws its own tinted ground (see render.build_document).
    (ground_light,) = grounds(art["xiaolaidict-icon-layer-1-background.svg"])
    if not isinstance(ground_light, Gradient):
        fail("xiaolaidict-icon-layer-1-background.svg: expected the ground painted with a linear gradient")
    if grounds(art["xiaolaidict-icon.svg"]) != [ground_light]:
        fail("layer-1-background and xiaolaidict-icon.svg disagree on the ground")
    ground_dark, glow = grounds(art["xiaolaidict-icon-dark.svg"])
    if not (isinstance(ground_dark, Gradient) and isinstance(glow, Radial)):
        fail("xiaolaidict-icon-dark.svg: expected two ground rects, the gradient then the radial glow")

    check_tray(sources.tray)
    stack_back, stack_front, card, *lines = (d.el for d in layers)
    return Design(stack_back, stack_front, card, tuple(lines), light, dark, tinted,
                  ground_light, ground_dark, glow, sources.tray)
