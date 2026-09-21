"""The Design as output bytes: white layer SVGs, the dark glow as a PNG, icon.json, the tray SVG.

Nothing is written to disk here; publish.py does that.
"""
from __future__ import annotations

import json
import math
import struct
import xml.etree.ElementTree as ET
import zlib
from collections.abc import Sequence

from . import CANVAS, SVG_NS, TRAY, fail
from .artwork import Design
from .sources import Gradient, Radial, Tray
from .whitelist import GEOMETRY_ATTRS, polygon, rgb


def hex_to_srgb(colour: str) -> str:
    r, g, b = (c / 255 for c in rgb(colour))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


# --- Icon Composer's gradient, measured ---------------------------------------------------------


def smoothstep(u: float) -> float:
    u = min(1.0, max(0.0, u))
    return u * u * (3 - 2 * u)


def solve_orientation(g: Gradient, top: float, bottom: float) -> tuple[float, float, float]:
    """Place Icon Composer's gradient so it reproduces the SVG's LINEAR ramp over [top, bottom].

    Measured on Icon Composer 27.0, identically for --design-generation 26 and 27: a `linear-gradient`
    fill is interpolated in sRGB-encoded space with SMOOTHSTEP easing (3u^2 - 2u^3), and u runs 0..1
    across the layer's alpha bounding box (the canvas, for the document fill). Orientation start/stop
    are in those box units and may lie outside 0..1. Fit residual 0.7 of a level.

    The designer's SVG gradient is linear in canvas space. Keeping the designer's two stop colours,
    this picks the canvas rows (ya, yb) where the eased ramp starts and stops so that it tracks the
    linear one across the shape with the smallest worst-case deviation. Returns (start, stop, worst):
    start/stop in box units; worst as a fraction of the stop-to-stop colour span.
    """
    ys = [top + (bottom - top) * i / 400 for i in range(401)]

    def target(y: float) -> float:
        return min(1.0, max(0.0, (y - g.y1) / (g.y2 - g.y1)))

    def worst(ya: float, yb: float) -> float:
        return max(abs(smoothstep((y - ya) / (yb - ya)) - target(y)) for y in ys)

    best = (worst(g.y1, g.y2), g.y1, g.y2)
    span = (g.y2 - g.y1) / 2
    for _ in range(6):  # coarse-to-fine grid search: deterministic, dependency-free
        _, ca, cb = best
        for i in range(-20, 21):
            for j in range(-20, 21):
                ya, yb = ca + span * i / 20, cb + span * j / 20
                if yb - ya > 1:
                    e = worst(ya, yb)
                    if e < best[0]:
                        best = (e, ya, yb)
        span /= 8
    e, ya, yb = best
    return (ya - top) / (bottom - top), (yb - top) / (bottom - top), e


def gradient_fill(g: Gradient, top: float, bottom: float, label: str) -> dict:
    start, stop, worst = solve_orientation(g, top, bottom)
    print(f"  {label:14s} box y {top:g}..{bottom:g}  orientation {start:+.5f}..{stop:+.5f}  "
          f"worst deviation from the SVG ramp {worst * 100:.2f}% of the stop-to-stop span")
    return {
        "linear-gradient": [hex_to_srgb(g.top), hex_to_srgb(g.bottom)],
        "orientation": {"start": {"x": 0.5, "y": round(start, 5)},
                        "stop": {"x": 0.5, "y": round(stop, 5)}},
    }


# --- writing layers --------------------------------------------------------------------------


def white_svg(elements: Sequence[ET.Element]) -> str:
    """The same shapes, painted white at full opacity. Colour lives in icon.json."""
    body = []
    for el in elements:
        tag = el.tag.split("}")[1]
        attrs = {a: el.get(a) for a in GEOMETRY_ATTRS if el.get(a) is not None}
        attrs["fill"] = "#FFFFFF"
        if el.get("stroke") is not None:
            attrs["stroke"] = "#FFFFFF"
        body.append(f"  <{tag} " + " ".join(f'{k}="{v}"' for k, v in attrs.items()) + "/>")
    return (f'<svg xmlns="{SVG_NS}" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="0 0 {CANVAS} {CANVAS}">\n' + "\n".join(body) + "\n</svg>\n")


def radial_png(rg: Radial, size: int = CANVAS) -> bytes:
    """Rasterise a one-colour radial fade exactly as SVG defines it (pad spread, pixel centres) as
    8-bit RGBA, the whole canvas at `size` pixels square, PNG "Up"-filtered so the smooth fade
    compresses. Rendered against a 16-bit version the Dark ground differs by at most one level, so
    16-bit buys nothing."""
    scale = size / CANVAS  # the gradient is in canvas units; exactly 1 at the size actool gets
    cx, cy, r = rg.cx * scale, rg.cy * scale, rg.r * scale
    colour = rgb(rg.colour)
    out, prev = bytearray(), bytes(4 * size)
    for y in range(size):
        dy = y + 0.5 - cy
        raw = bytearray()
        for x in range(size):
            t = min(1.0, math.hypot(x + 0.5 - cx, dy) / r)
            raw += colour + bytes((round((rg.a0 + (rg.a1 - rg.a0) * t) * 255),))
        out += b"\x02" + bytes((a - b) & 0xFF for a, b in zip(raw, prev))  # filter 2 = Up
        prev = bytes(raw)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(out), 9)) + chunk(b"IEND", b""))


# --- the menu-bar template ---------------------------------------------------------------------


def rounded_rect_path(x: float, y: float, w: float, h: float, r: float) -> str:
    """A rounded rectangle as path data, clockwise, omitting straight runs of zero length."""
    def f(v: float) -> str:
        return f"{round(v, 4):g}"

    def arc(ex: float, ey: float) -> str:
        return f"A{f(r)} {f(r)} 0 0 1 {f(ex)} {f(ey)}"

    parts = [f"M{f(x + r)} {f(y)}"]
    if w > 2 * r:
        parts.append(f"H{f(x + w - r)}")
    parts.append(arc(x + w, y + r))
    if h > 2 * r:
        parts.append(f"V{f(y + h - r)}")
    parts.append(arc(x + w - r, y + h))
    if w > 2 * r:
        parts.append(f"H{f(x + r)}")
    parts.append(arc(x, y + h - r))
    if h > 2 * r:
        parts.append(f"V{f(y + r)}")
    parts.append(arc(x + r, y))
    return " ".join(parts) + " Z"


def tray_svg(tray: Tray) -> str:
    """The designer's tray glyph without its <mask>.

    The source cuts the entry slots out of the hexagon with an SVG <mask>. CoreSVG (NSImage, the
    path the app loads it through) rasterises that mask at 1x and scales it up, so on a Retina menu
    bar the slots are only partly cut (slot-centre alpha 90 of 255 at 2x, where it must be 0) and
    every edge is soft. Measured against rsvg-convert: max alpha error 233 at 2x.

    Same geometry, no mask: the hexagon's round-joined stroke on its own, plus the hexagon filled
    with the slots as even-odd holes. artwork.check_tray asserts the slots lie clear of the stroke and of
    each other, so the two constructions cover exactly the same area.
    """
    holes = " ".join(rounded_rect_path(*s) for s in tray.slots)
    return (
        f'<svg xmlns="{SVG_NS}" width="{TRAY}" height="{TRAY}" viewBox="0 0 {TRAY} {TRAY}">\n'
        f"  <!-- Generated from Tools/icon/xiaolaidict-tray-slots-Template.svg: the same shape, without its\n"
        f"       <mask>, which CoreSVG rasterises at 1x and blurs on Retina menu bars. Template image:\n"
        f"       only alpha is read. -->\n"
        f'  <path d="{tray.d}" fill="none" stroke="#000" stroke-width="{tray.stroke_width}" '
        f'stroke-linejoin="round"/>\n'
        f'  <path d="{tray.d} {holes}" fill="#000" fill-rule="evenodd"/>\n'
        f"</svg>\n"
    )


# --- the document ---------------------------------------------------------------------------------


def vertical_extent(path: ET.Element) -> tuple[float, float]:
    """Top and bottom of a stroked polygon with round joins: vertex extremes +/- half the stroke."""
    ys = [y for _, y in polygon(path.get("d"))]
    half = float(path.get("stroke-width", "0")) / 2
    if half and path.get("stroke-linejoin") != "round":
        fail("extent assumes round joins")
    return min(ys) - half, max(ys) + half


def build_document(d: Design) -> dict:
    """icon.json: the layer groups, top first, with every appearance's colours for each."""
    card_top, card_bottom = vertical_extent(d.card)

    def per_appearance(pick, make) -> list:
        return [
            {"value": make(pick(d.light), "light")},
            {"appearance": "dark", "value": make(pick(d.dark), "dark")},
            {"appearance": "tinted", "value": make(pick(d.tinted), "tinted")},
        ]

    def solid(hex_colour: str, _: str) -> dict:
        return {"solid": hex_to_srgb(hex_colour)}

    def card_gradient(g: Gradient, which: str) -> dict:
        return gradient_fill(g, card_top, card_bottom, f"card {which}")

    # Translucency off: at its default it lets the grey stack show through the honey card (measured
    # dE 10-12 on the card's lower half). Glass, specular and shadow stay at their defaults (on):
    # that is the Liquid Glass treatment the system is meant to add.
    opaque = {"enabled": False, "value": 0.5}
    return {
        # The ground has no tinted entry: the system draws its own tinted and clear grounds, and an
        # override there was measured to change no pixel, under either design generation.
        "fill-specializations": [
            {"value": gradient_fill(d.ground_light, 0, CANVAS, "ground light")},
            {"appearance": "dark", "value": gradient_fill(d.ground_dark, 0, CANVAS, "ground dark")},
        ],
        "groups": [  # TOP-FIRST: groups[0] is drawn in front, and likewise layers within a group
            {
                "name": "card",
                "translucency": opaque,
                "layers": [
                    {   # Ink printed on the card, as it is inside the designer's single card layer:
                        # no glass bevel of its own.
                        "name": "line-primary",
                        "image-name": "line-primary.svg",
                        "glass": False,
                        "fill-specializations": per_appearance(lambda a: a.ink, solid),
                    },
                    {
                        "name": "line-secondary",
                        "image-name": "line-secondary.svg",
                        "glass": False,
                        "fill-specializations": per_appearance(lambda a: a.ink, solid),
                        "opacity-specializations": per_appearance(
                            lambda a: a.secondary_opacity, lambda v, _: v),
                    },
                    {
                        "name": "card",
                        "image-name": "card.svg",
                        "fill-specializations": per_appearance(lambda a: a.card, card_gradient),
                    },
                ],
            },
            {
                "name": "stack",
                "translucency": opaque,
                "layers": [
                    {
                        "name": "stack-front",
                        "image-name": "stack-front.svg",
                        "fill-specializations": per_appearance(lambda a: a.stack_front, solid),
                    },
                    {
                        "name": "stack-back",
                        "image-name": "stack-back.svg",
                        "fill-specializations": per_appearance(lambda a: a.stack_back, solid),
                    },
                ],
            },
            {   # The dark ground's top glow from xiaolaidict-icon-dark.svg. Part of the ground, so no glass,
                # specular or shadow; drawn in the dark appearance only.
                "name": "ground-glow",
                "translucency": opaque,
                "specular": False,
                "shadow": {"kind": "none", "opacity": 0.5},
                "layers": [
                    {
                        "name": "dark-glow",
                        "image-name": "dark-glow.png",
                        "glass": False,
                        "fill": "none",
                        "hidden-specializations": [
                            {"value": True},
                            {"appearance": "dark", "value": False},
                        ],
                    }
                ],
            },
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }


def build_outputs(d: Design) -> dict[str, bytes]:
    """Every output file, keyed by its path under the Resources dir. Nothing is written here."""
    assets = {
        "line-primary.svg": white_svg(d.lines[:1]).encode(),
        "line-secondary.svg": white_svg(d.lines[1:]).encode(),
        "card.svg": white_svg([d.card]).encode(),
        "stack-front.svg": white_svg([d.stack_front]).encode(),
        "stack-back.svg": white_svg([d.stack_back]).encode(),
        # A radial fade is the one thing `fill` cannot express, so it is a raster layer: PNG, not an
        # SVG radialGradient, because actool has rendered gradient/filter SVG layers black without
        # a warning.
        "dark-glow.png": radial_png(d.glow),
    }
    doc = build_document(d)
    named = {layer["image-name"] for group in doc["groups"] for layer in group["layers"]}
    if named != assets.keys():
        fail(f"internal: icon.json names {sorted(named)}, but the assets made are {sorted(assets)}")
    files = {f"XiaolaiDict.icon/Assets/{name}": data for name, data in assets.items()}
    files["XiaolaiDict.icon/icon.json"] = (json.dumps(doc, indent=2) + "\n").encode()
    files["MenuBarIcon.svg"] = tray_svg(d.tray).encode()
    return files
