"""MenuBarIcon.svg means what the designer's masked tray glyph means: same shape, same painted area.

Checked independently of the generator: the source and the output are both read here, with a small
path parser of the test's own, and compared as geometry and as paint sampled across the canvas. No
transform is involved; the one tolerance, TOL, covers the generator writing slot coordinates
rounded to 4 decimal places.
"""
from __future__ import annotations

import math
import re
import unittest
import xml.etree.ElementTree as ET

from fixtures import DESIGN, TRAY, build

SVG = "{http://www.w3.org/2000/svg}"
TOL = 1e-4  # the generator rounds slot coordinates to 4 decimal places
EDGE = 0.01  # a sample this close to an edge is skipped: either answer is fair there
STEP = 0.05  # sample spacing, in points of the 22-point canvas
COARSE = 0.1  # for the divergent trays, each wrong by at least 300 samples at this spacing
ARC_STEPS = 32  # segments per flattened arc: 0.8-point corners stay within 0.0004 of true


def arc(start, r, large, sweep, end):
    """Points along an SVG arc with equal radii and no rotation (SVG 1.1 F.6.5), start excluded."""
    (x1, y1), (x2, y2) = start, end
    hx, hy = (x1 - x2) / 2, (y1 - y2) / 2
    d2 = hx * hx + hy * hy
    r = max(r, math.sqrt(d2))  # radii too small for the chord are scaled up (F.6.6)
    k = math.sqrt(max(0.0, r * r - d2) / d2) * (-1 if large == sweep else 1)
    cx, cy = k * hy + (x1 + x2) / 2, -k * hx + (y1 + y2) / 2
    a0, a1 = math.atan2(y1 - cy, x1 - cx), math.atan2(y2 - cy, x2 - cx)
    turn = a1 - a0
    if sweep and turn < 0:
        turn += 2 * math.pi
    if not sweep and turn > 0:
        turn -= 2 * math.pi
    return [(cx + r * math.cos(a0 + turn * i / ARC_STEPS), cy + r * math.sin(a0 + turn * i / ARC_STEPS))
            for i in range(1, ARC_STEPS)] + [end]


def subpaths(d: str) -> list[dict]:
    """Absolute M/L/H/V/A/Z path data as closed subpaths: their points (arcs flattened) and the
    radius of every arc. Anything else is an error, not something to skip."""
    tokens = iter(re.findall(r"[A-Za-z]|[-+]?(?:\d+\.?\d*|\.\d+)", d))

    def num() -> float:
        return float(next(tokens))

    found, points, radii = [], [], []
    for token in tokens:
        if token == "M":
            points, radii = [(num(), num())], []
        elif token == "L":
            points.append((num(), num()))
        elif token == "H":
            points.append((num(), points[-1][1]))
        elif token == "V":
            points.append((points[-1][0], num()))
        elif token == "A":
            rx, ry, rotation, large, sweep, x, y = (num() for _ in range(7))
            if rx != ry or rotation:
                raise AssertionError(f"elliptical or rotated arc in {d!r}")
            points.extend(arc(points[-1], rx, large, sweep, (x, y)))
            radii.append(rx)
        elif token == "Z":
            found.append({"points": points, "radii": radii})
        else:
            raise AssertionError(f"unexpected path token {token!r} in {d!r}")
    return found


def winding(poly, x: float, y: float) -> int:
    """How many times the closed polygon winds around (x, y), signed by direction."""
    turns = 0
    for (ax, ay), (bx, by) in zip(poly, poly[1:] + poly[:1]):
        if (ay > y) != (by > y) and x < ax + (y - ay) * (bx - ax) / (by - ay):
            turns += 1 if by > ay else -1
    return turns


def edge_distance(poly, x: float, y: float) -> float:
    """Distance to the polygon's outline: round-joined strokes cover all points within w/2 of it."""
    best = math.inf
    for (ax, ay), (bx, by) in zip(poly, poly[1:] + poly[:1]):
        dx, dy = bx - ax, by - ay
        along = ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy) if dx or dy else 0.0
        t = max(0.0, min(1.0, along))
        best = min(best, math.hypot(x - ax - t * dx, y - ay - t * dy))
    return best


def slot_distance(slot, x: float, y: float) -> float:
    """Signed distance to a rounded rect (x, y, w, h, r): negative inside."""
    sx, sy, w, h, r = slot
    qx, qy = abs(x - sx - w / 2) - (w / 2 - r), abs(y - sy - h / 2) - (h / 2 - r)
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def source_tray(svg: bytes) -> dict:
    """The designer's glyph: a full-canvas rect painted through a mask of the hexagon (white,
    filled and stroked), then the slots (black) over it."""
    root = ET.fromstring(svg)
    (mask,), (painted,) = root.findall(f"{SVG}mask"), root.findall(f"{SVG}rect")
    hexagon, *slots = list(mask)
    return {
        "canvas": (root.get("width"), root.get("height"), root.get("viewBox")),
        "painted": [float(painted.get(k, "0")) for k in ("x", "y", "width", "height")],
        "hexagon": subpaths(hexagon.get("d"))[0]["points"],
        "stroke": float(hexagon.get("stroke-width")),
        "join": hexagon.get("stroke-linejoin"),
        "slots": [tuple(float(s.get(k)) for k in ("x", "y", "width", "height", "rx")) for s in slots],
    }


def generated_tray(svg: bytes) -> dict:
    """The generated glyph: the hexagon's outline stroked, then the hexagon filled even-odd with
    the slots as holes."""
    root = ET.fromstring(svg)
    outline, filled = root.findall(f"{SVG}path")
    shapes = subpaths(filled.get("d"))
    return {
        "canvas": (root.get("width"), root.get("height"), root.get("viewBox")),
        "paint": (outline.get("fill"), outline.get("stroke"), filled.get("fill"), filled.get("fill-rule")),
        "outline": subpaths(outline.get("d"))[0]["points"],
        "stroke": float(outline.get("stroke-width")),
        "join": outline.get("stroke-linejoin"),
        "hexagon": shapes[0]["points"],
        "holes": shapes[1:],
    }


def close(a, b) -> bool:
    return len(a) == len(b) and all(abs(p - q) <= TOL for p, q in zip(a, b))


def mismatches(source_svg: bytes, generated_svg: bytes, step: float = STEP) -> list[str]:
    """Every way the generated glyph differs from the source's meaning; empty when they agree."""
    src, found = source_tray(source_svg), []
    try:
        gen = generated_tray(generated_svg)
    except (ValueError, AssertionError, TypeError, IndexError) as e:  # not even the expected shape
        return [f"generated tray unreadable as outline + even-odd fill: {e}"]
    size = float(src["canvas"][0])
    if gen["canvas"] != src["canvas"] or src["painted"] != [0, 0, size, size]:
        found.append(f"canvas {gen['canvas']} vs source {src['canvas']}, painted rect {src['painted']}")
    if gen["paint"] != ("none", "#000", "#000", "evenodd"):
        found.append(f"paint (outline fill, outline stroke, fill, fill-rule) is {gen['paint']}")
    for label in ("outline", "hexagon"):
        if not close([c for p in gen[label] for c in p], [c for p in src["hexagon"] for c in p]):
            found.append(f"{label} points {gen[label]} vs source hexagon {src['hexagon']}")
    if abs(gen["stroke"] - src["stroke"]) > TOL or (gen["join"], src["join"]) != ("round", "round"):
        found.append(f"stroke {gen['stroke']} {gen['join']} vs source {src['stroke']} {src['join']}")
    if len(gen["holes"]) != len(src["slots"]):
        found.append(f"{len(gen['holes'])} holes for {len(src['slots'])} slots")
    for hole, slot in zip(gen["holes"], src["slots"]):
        xs, ys = [p[0] for p in hole["points"]], [p[1] for p in hole["points"]]
        rect = (min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys))
        if not close(rect, slot[:4]) or not all(abs(r - slot[4]) <= TOL for r in hole["radii"]):
            found.append(f"hole {rect} radii {hole['radii']} vs slot {slot}")
    found.extend(paint_differences(src, gen, size, step))
    return found


def paint_differences(src: dict, gen: dict, size: float, step: float) -> list[str]:
    """Sample the canvas: is each point painted in the source's mask and in the generated paths?"""
    half_src, half_gen = src["stroke"] / 2, gen["stroke"] / 2
    holes = [(h["points"], min(p[0] for p in h["points"]) - EDGE, max(p[0] for p in h["points"]) + EDGE,
              min(p[1] for p in h["points"]) - EDGE, max(p[1] for p in h["points"]) + EDGE)
             for h in gen["holes"]]
    counts, wrong = {"painted": 0, "slot": 0, "clear": 0}, []
    n = int(size / step)
    for j in range(n):
        for i in range(n):
            x, y = (i + 0.5) * step, (j + 0.5) * step
            ds, dg = edge_distance(src["hexagon"], x, y), edge_distance(gen["outline"], x, y)
            in_slots = [slot_distance(s, x, y) for s in src["slots"]]
            if abs(ds - half_src) < EDGE or abs(dg - half_gen) < EDGE or any(abs(d) < EDGE for d in in_slots):
                continue
            turns = winding(gen["hexagon"], x, y)
            for points, x0, x1, y0, y1 in holes:
                if x0 <= x <= x1 and y0 <= y <= y1:
                    if edge_distance(points, x, y) < EDGE:
                        break
                    turns += winding(points, x, y)
            else:
                white = winding(src["hexagon"], x, y) != 0 or ds <= half_src
                source = white and not any(d < 0 for d in in_slots)
                filled = turns % 2 == 1 if gen["paint"][3] == "evenodd" else turns != 0  # SVG's default
                generated = dg <= half_gen or filled
                counts["painted" if source else "slot" if white else "clear"] += 1
                if source != generated:
                    wrong.append((round(x, 3), round(y, 3)))
    found = [f"{len(wrong)} sample points painted differently, e.g. {wrong[:5]}"] if wrong else []
    if min(counts.values()) < 1000:  # a comparison that sampled nothing proves nothing
        found.append(f"too few samples of some kind to compare: {counts}")
    return found


class TrayMeansTheSource(unittest.TestCase):
    source = (DESIGN / TRAY).read_bytes()

    def test_generated_tray_matches_the_source_mask(self) -> None:
        self.assertEqual(mismatches(self.source, build()["MenuBarIcon.svg"]), [])

    def test_the_comparison_notices_a_divergent_tray(self) -> None:
        # A check that cannot fail proves nothing: each of these is a plausible generator bug.
        generated = build()["MenuBarIcon.svg"].decode()
        first_hole = "M6.7 8.8 H13.3 A0.8 0.8 0 0 1 14.1 9.6 A0.8 0.8 0 0 1 13.3 10.4 H6.7 " \
                     "A0.8 0.8 0 0 1 5.9 9.6 A0.8 0.8 0 0 1 6.7 8.8 Z"
        corruptions = {
            "stroke width": ('stroke-width="1"', 'stroke-width="1.2"'),
            "fill rule": ('fill-rule="evenodd"', 'fill-rule="nonzero"'),
            "a hole dropped": (" " + first_hole, ""),
            "a hole shifted": (first_hole, first_hole.replace("8.8", "9").replace("9.6", "9.8")
                               .replace("10.4", "10.6")),
            "sharper corners": (first_hole, first_hole.replace("A0.8 0.8", "A0.5 0.5")),
            "outline dropped": (generated.split("\n")[4] + "\n", ""),
        }
        for label, (old, new) in corruptions.items():
            with self.subTest(corruption=label):
                self.assertEqual(generated.count(old), 1, "fixture edit matches nothing")
                found = mismatches(self.source, generated.replace(old, new).encode(), COARSE)
                self.assertNotEqual(found, [])
                if label != "outline dropped":  # the rest must show in the paint itself, not only in form
                    self.assertTrue(any("painted differently" in m for m in found), found)


if __name__ == "__main__":
    unittest.main()
