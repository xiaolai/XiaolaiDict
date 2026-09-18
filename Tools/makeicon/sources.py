"""Reading the designer's files: each one parsed into what it draws, back to front.

Exhaustive: every element is understood here or refused, and every attribute passes the whitelist,
so nothing the designer drew can go missing further on. Nothing is compared across files yet; that
is artwork.py.
"""
from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from xml.parsers import expat

from . import CANVAS, TRAY, fail
from .whitelist import (
    COLOUR,
    GROUND_ATTRS,
    ID,
    LENGTH,
    LINE_ATTRS,
    NUMBER,
    PATH_ATTRS,
    POLYGON,
    STROKE_ATTRS,
    Kind,
    attrs,
    tag,
)


def opacity(what: str, a: dict[str, str], key: str) -> float:
    """An opacity attribute, 1 when absent. SVG would clamp one outside 0..1; art must not lean on it."""
    value = float(a.get(key, "1"))
    if not 0 <= value <= 1:
        fail(f"{what} {key}={a[key]!r} is outside 0..1")
    return value


def full_canvas(name: str, a: dict[str, str], canvas: int) -> None:
    """A background rect is the whole canvas, exactly: the generated document fills all of it."""
    x, y, w, h = (float(a.get(k, "0")) for k in ("x", "y", "width", "height"))
    if (x, y, w, h) != (0, 0, canvas, canvas):
        fail(f"{name}: <rect> at {x:g},{y:g} sized {w:g}x{h:g} must cover the whole "
             f"{canvas}x{canvas} canvas")


def load(path: Path, canvas: int = CANVAS) -> ET.Element:
    """A source's root <svg>: well-formed XML, `canvas` points square."""
    if not path.is_file():
        fail(f"missing source file {path}")
    try:
        data = path.read_bytes()
    except OSError as e:
        fail(f"cannot read {path}: {e.strerror}")
    # No DTD: the art never needs one, and an entity-expansion bomb in one takes gigabytes on the
    # expat in macOS's own python3 (2.2.8, from before expat limited expansion). This first pass
    # stops at the DOCTYPE itself, before any entity is expanded; ElementTree's own hook comes
    # too late to prevent that. Nor processing instructions, which ElementTree drops unseen: an
    # <?xml-stylesheet?> restyles the art.
    probe = expat.ParserCreate()
    probe.StartDoctypeDeclHandler = lambda *_: fail(f"{path.name}: a DOCTYPE is not supported")
    probe.ProcessingInstructionHandler = lambda target, _: fail(
        f"{path.name}: processing instruction <?{target}?> is not supported")
    try:
        probe.Parse(data, True)
        root = ET.fromstring(data)
    except (expat.ExpatError, ET.ParseError) as e:
        fail(f"{path.name}: not well-formed XML ({e})")
    except (LookupError, ValueError) as e:  # what the codecs raise for an encoding named in the
        # XML declaration: unknown or not text (LookupError), multi-byte (ValueError), undecodable
        fail(f"{path.name}: its character encoding cannot be used ({e})")
    if tag(path.name, root) != "svg":
        fail(f"{path.name}: the root element is <{tag(path.name, root)}>, not <svg>")
    size = str(canvas)
    attrs(path.name, root, {"width": size, "height": size, "viewBox": f"0 0 {size} {size}"})
    return root


@dataclass(frozen=True)
class Gradient:
    """A vertical linear gradient in canvas space, as the designer wrote it."""

    top: str
    bottom: str
    y1: float
    y2: float


@dataclass(frozen=True)
class Radial:
    cx: float
    cy: float
    r: float
    colour: str
    a0: float
    a1: float


def stops(name: str, g: ET.Element, gid: str,
          optional: dict[str, Kind | str] | None = None) -> list[dict[str, str]]:
    found = []
    for s in g:
        if tag(name, s) != "stop":
            fail(f"{name}: unsupported element <{tag(name, s)}> in #{gid}")
        found.append(attrs(name, s, {"offset": NUMBER, "stop-color": COLOUR}, optional))
    if [s["offset"] for s in found] != ["0", "1"]:
        fail(f"{name}: #{gid}: expected exactly two stops, at offsets 0 and 1")
    return found


def gradient(name: str, g: ET.Element) -> tuple[str, Gradient | Radial]:
    """One entry of <defs>: a vertical linear gradient, or a centred one-colour radial fade."""
    kind = tag(name, g)
    if kind == "linearGradient":
        a = attrs(name, g, {"id": ID, "gradientUnits": "userSpaceOnUse",
                            "x1": NUMBER, "y1": NUMBER, "x2": NUMBER, "y2": NUMBER})
        if float(a["x1"]) != float(a["x2"]) or float(a["y1"]) >= float(a["y2"]):
            fail(f"{name}: #{a['id']}: only vertical, top-to-bottom gradients are supported")
        top, bottom = stops(name, g, a["id"])
        return a["id"], Gradient(top["stop-color"], bottom["stop-color"], float(a["y1"]), float(a["y2"]))
    if kind == "radialGradient":
        a = attrs(name, g, {"id": ID, "gradientUnits": "userSpaceOnUse",
                            "cx": NUMBER, "cy": NUMBER, "r": LENGTH})
        if float(a["r"]) == 0:
            fail(f"{name}: #{a['id']}: a radial gradient needs a positive radius")
        s0, s1 = stops(name, g, a["id"], {"stop-opacity": NUMBER})
        if s0["stop-color"] != s1["stop-color"]:
            fail(f"{name}: #{a['id']}: expected one colour fading between offsets 0 and 1")
        return a["id"], Radial(float(a["cx"]), float(a["cy"]), float(a["r"]), s0["stop-color"],
                               opacity(f"{name}: <stop>", s0, "stop-opacity"),
                               opacity(f"{name}: <stop>", s1, "stop-opacity"))
    fail(f"{name}: unsupported element <{kind}> in <defs>")


@dataclass(frozen=True)
class Drawn:
    """One thing a 1024-point source draws, its paint resolved to a colour or a gradient."""

    role: str  # "ground" (a full-canvas rect), "shape" (a path) or "line" (an entry line)
    el: ET.Element
    paint: str | Gradient | Radial
    opacity: float = 1.0


# What each 1024-point source draws, back to front: (grounds, shapes, entry lines). Always in that
# order, which is the order the generated document stacks them in.
LAYOUT = {
    "xiaolaidict-icon-layer-1-background.svg": (1, 0, 0),
    "xiaolaidict-icon-layer-2-stack.svg": (0, 2, 0),
    "xiaolaidict-icon-layer-3-card.svg": (0, 1, 3),
    "xiaolaidict-icon.svg": (1, 3, 3),
    "xiaolaidict-icon-dark.svg": (2, 3, 3),  # the gradient, then the glow
    "xiaolaidict-icon-tinted.svg": (1, 3, 3),
}
FLATS = ("xiaolaidict-icon.svg", "xiaolaidict-icon-dark.svg", "xiaolaidict-icon-tinted.svg")
TRAY_SOURCE = "xiaolaidict-tray-slots-Template.svg"


def read_art(name: str, root: ET.Element) -> list[Drawn]:
    """Everything one 1024-point source draws, back to front. Exhaustive: each element is
    understood or refused here, so nothing the designer drew can go missing further on."""
    gradients: dict[str, Gradient | Radial] = {}
    drawing = []
    for el in root:
        kind = tag(name, el)
        if kind == "metadata":
            continue  # provenance (a C2PA manifest): never rendered
        if kind == "defs":
            attrs(name, el, {})
            for g in el:
                gid, grad = gradient(name, g)
                if gid in gradients:
                    fail(f"{name}: two gradients with id {gid!r}")
                gradients[gid] = grad
        elif kind in ("rect", "path", "g"):
            drawing.append(el)
        else:
            fail(f"{name}: unsupported element <{kind}>")

    used = set()

    def paint(value: str) -> str | Gradient | Radial:
        if COLOUR.ok(value):
            return value
        gid = value[len("url(#") : -1]
        if gid not in gradients:
            fail(f"{name}: {value} names no gradient in this file")
        used.add(gid)
        return gradients[gid]

    drawn = []
    for el in drawing:
        kind = tag(name, el)
        if kind == "rect":
            a = attrs(name, el, GROUND_ATTRS, {"x": NUMBER, "y": NUMBER})
            full_canvas(name, a, CANVAS)
            drawn.append(Drawn("ground", el, paint(a["fill"])))
        elif kind == "path":
            a = attrs(name, el, PATH_ATTRS, STROKE_ATTRS)
            stroked = [k for k in STROKE_ATTRS if k in a]
            if stroked and len(stroked) != len(STROKE_ATTRS):
                fail(f"{name}: a stroked <path> needs stroke, stroke-width and stroke-linejoin together")
            if stroked and a["stroke"] != a["fill"]:
                fail(f"{name}: a <path>'s stroke {a['stroke']} differs from its fill {a['fill']}; "
                     "each shape becomes one layer, painted with one fill")
            drawn.append(Drawn("shape", el, paint(a["fill"])))
        else:  # a <g> of entry lines, which take their ink from it
            ink = attrs(name, el, {"fill": COLOUR})["fill"]
            for line in el:
                if tag(name, line) != "rect":
                    fail(f"{name}: unsupported element <{tag(name, line)}> among the entry lines")
                a = attrs(name, line, LINE_ATTRS, {"fill-opacity": NUMBER})
                drawn.append(Drawn("line", line, ink, opacity(f"{name}: <rect>", a, "fill-opacity")))

    n_grounds, n_shapes, n_lines = LAYOUT[name]
    want = ["ground"] * n_grounds + ["shape"] * n_shapes + ["line"] * n_lines
    got = [d.role for d in drawn]
    if got != want:
        fail(f"{name}: draws {', '.join(got) or 'nothing'}; expected {', '.join(want)} (back to front)")
    unused = sorted(gradients.keys() - used)
    if unused:
        fail(f"{name}: {', '.join('#' + g for g in unused)} defined but never used")
    return drawn


@dataclass(frozen=True)
class Tray:
    """The menu-bar glyph as its source defines it: a hexagon, filled and round-stroked, with
    rounded-rect slots cut out of it through a mask."""

    d: str
    stroke_width: str
    slots: tuple[tuple[float, float, float, float, float], ...]  # x, y, width, height, corner radius


def read_tray(name: str, root: ET.Element) -> Tray:
    """Every element of the tray source, understood or refused: one black rect painted through one
    mask, and in the mask the hexagon in white, then the slots in black over it."""
    masks, painted = [], []
    for el in root:
        kind = tag(name, el)
        if kind == "metadata":
            continue
        if kind not in ("mask", "rect"):
            fail(f"{name}: unsupported element <{kind}>")
        (masks if kind == "mask" else painted).append(el)
    if len(masks) != 1 or len(painted) != 1:
        fail(f"{name}: expected one black rect painted through one mask")
    mask_id = attrs(name, masks[0], {"id": ID})["id"]
    a = attrs(name, painted[0], {"width": LENGTH, "height": LENGTH, "fill": "#000",
                                 "mask": f"url(#{mask_id})"}, {"x": NUMBER, "y": NUMBER})
    full_canvas(name, a, TRAY)

    inside = list(masks[0])
    kinds = [tag(name, el) for el in inside]
    for kind in kinds:
        if kind not in ("path", "rect"):
            fail(f"{name}: unsupported element <{kind}> in the <mask>")
    if kinds[:1] != ["path"] or "path" in kinds[1:]:
        fail(f"{name}: expected the <mask> to start with the hexagon <path>, then only <rect> slots")
    hexagon, *cutouts = inside
    h = attrs(name, hexagon, {"d": POLYGON, "fill": "#fff", "stroke": "#fff",
                              "stroke-width": LENGTH, "stroke-linejoin": "round"})
    slots = [attrs(name, r, {**LINE_ATTRS, "fill": "#000"}) for r in cutouts]  # shaped like entry lines
    return Tray(h["d"], h["stroke-width"],
                tuple(tuple(float(s[k]) for k in ("x", "y", "width", "height", "rx")) for s in slots))


@dataclass(frozen=True)
class Sources:
    """Every designer file, read and whitelist-checked; nothing compared across files yet."""

    art: dict[str, list[Drawn]]
    tray: Tray


def parse_sources(src: Path) -> Sources:
    art = {name: read_art(name, load(src / name)) for name in LAYOUT}
    return Sources(art, read_tray(TRAY_SOURCE, load(src / TRAY_SOURCE, TRAY)))
