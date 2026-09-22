"""Reading the designer's files: each one parsed into what it draws and the colour it draws it in.

Exhaustive: every element is understood here or refused, and every attribute passes the whitelist.
Nothing is compared across files yet; that is artwork.py.

The art is authored per appearance — one file per layer per appearance — so a layer's geometry is
written down two or three times. This module keeps each file's tree intact so artwork.py can hold
those copies against each other; that cross-check is the only thing standing between the reader and
a dark icon whose contour has quietly drifted from the light one's.
"""
from __future__ import annotations

import copy
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from xml.parsers import expat

from . import CANVAS, SVG_NS, TRAY, fail
from .whitelist import (
    PAINT_ATTRS,
    FILLED_PATH_ATTRS,
    FILLED_RECT_ATTRS,
    GROUND_ATTRS,
    GROUP_ATTRS,
    NUMBER,
    STROKED_PATH_ATTRS,
    STROKED_PATH_OPTIONAL,
    TRAY_PATH_OPTIONAL,
    SVG_ATTRS,
    attrs,
    tag,
)


@dataclass(frozen=True)
class Canvas:
    """A source's canvas: the pixels it declares, and the coordinate system it is drawn in."""

    pixels: float
    units: float


def load(path: Path, pixels: int) -> tuple[ET.Element, Canvas]:
    """A source's root <svg>: well-formed XML, square, `pixels` points across.

    The viewBox may be in any square coordinate system — the art is 1024 pixels on a 100-unit grid —
    so the units are returned rather than assumed, and artwork.py holds every layer to the same one.
    """
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
    a = attrs(path.name, root, SVG_ATTRS)
    if float(a["width"]) != pixels or float(a["height"]) != pixels:
        fail(f"{path.name}: is {a['width']}x{a['height']}, not {pixels}x{pixels}")
    return strip_metadata(root), Canvas(float(a["width"]), float(a["viewBox"].split()[2]))


def strip_metadata(root: ET.Element) -> ET.Element:
    """The tree without its <metadata>: provenance (a C2PA manifest), never rendered, and not part
    of the geometry two appearances are compared on."""
    root = copy.deepcopy(root)
    for el in [el for el in root if el.tag.rpartition("}")[2] == "metadata"]:
        root.remove(el)
    return root


ET.register_namespace("", SVG_NS)


def repaint(root: ET.Element, colour: str) -> ET.Element:
    """The same tree with every paint attribute set to `colour`.

    `fill="none"` is geometry, not paint: it says a shape is a stroke and nothing else, and painting
    it would flood the layer.
    """
    out = ET.fromstring(ET.tostring(root))
    for el in out.iter():
        for a in PAINT_ATTRS:
            if el.get(a) not in (None, "none"):
                el.set(a, colour)
    return out


def svg_bytes(root: ET.Element) -> bytes:
    """A source tree as a standalone SVG file: two-space indent, one trailing newline.

    On a copy, because `ET.indent` rewrites the tree it is given: handed the Design's own tree —
    which `tray_svg` does, the tray being emitted unchanged — it would leave the parsed sources
    indented, and the next thing to read them would read something the designer did not write.
    """
    root = ET.fromstring(ET.tostring(root))
    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    return ET.tostring(root, encoding="utf-8", xml_declaration=False) + b"\n"


def geometry(art: Art) -> bytes:
    """Everything about a layer except the colour it is drawn in: what two appearances of the same
    layer must agree on, byte for byte."""
    return svg_bytes(repaint(art.root, "#000000"))


def full_canvas(name: str, a: dict[str, str], units: float) -> None:
    """A ground is the whole canvas, exactly: the generated document fills all of it, and art that
    stops short leaves a transparent border, which Tahoe answers by wrapping the icon in its own
    grey squircle and shrinking it."""
    x, y, w, h = (float(a.get(k, "0")) for k in ("x", "y", "width", "height"))
    if (x, y, w, h) != (0, 0, units, units):
        fail(f"{name}: <rect> at {x:g},{y:g} sized {w:g}x{h:g} must cover the whole "
             f"{units:g}x{units:g} canvas")


@dataclass(frozen=True)
class Art:
    """One layer source: the tree to emit, and the one colour it paints with.

    `kind` is "ground" — a full-canvas rect, which becomes the document's fill — or "mark", a
    stroked path, which becomes a layer.
    """

    name: str
    canvas: Canvas
    root: ET.Element
    kind: str
    colour: str


def mark_path(name: str, el: ET.Element) -> str:
    """A mark's <path>, stroked or filled, in one colour. Returns that colour.

    `fill="none"` is the whole of the distinction: it says the shape is an outline and its colour
    lives on `stroke`. Anything else means the shape is solid and its colour is the fill. The art
    uses both — the contour is an 8-unit stroke, the sparkle a filled star — and reading the fill
    first is what decides which table the attributes are checked against, so a stroked path missing
    its `stroke-width` is reported as that rather than as an unexpected attribute.
    """
    if tag(name, el) != "path":
        fail(f"{name}: unsupported element <{tag(name, el)}> where the mark's <path> belongs")
    if el.get("fill") == "none":
        return attrs(name, el, STROKED_PATH_ATTRS, STROKED_PATH_OPTIONAL)["stroke"]
    if el.get("stroke") is not None:
        fail(f"{name}: a <path> is either stroked, with fill=\"none\", or filled — not both; this "
             f"one has fill={el.get('fill')!r} and stroke={el.get('stroke')!r}. icon.json gives a "
             "layer one colour, so a shape that is painted twice cannot be reproduced")
    return attrs(name, el, FILLED_PATH_ATTRS)["fill"]


def read_art(name: str, root: ET.Element, canvas: Canvas) -> Art:
    """What one layer source draws: a full-canvas rect, or one path — stroked or filled —
    optionally inside one <g>. Anything else stops the run; art this generator cannot reproduce
    faithfully is never quietly approximated."""
    drawn = list(root)
    if len(drawn) != 1:
        drew = ", ".join(f"<{tag(name, el)}>" for el in drawn) or "nothing"
        fail(f"{name}: draws {drew}; expected one <rect> ground or one <path> mark")
    el = drawn[0]
    kind = tag(name, el)
    if kind == "rect":
        a = attrs(name, el, GROUND_ATTRS, {"x": NUMBER, "y": NUMBER})
        full_canvas(name, a, canvas.units)
        return Art(name, canvas, root, "ground", a["fill"])
    if kind == "g":
        attrs(name, el, GROUP_ATTRS)
        inside = list(el)
        if len(inside) != 1:
            fail(f"{name}: expected one <path> inside the <g>, not {len(inside)}")
        return Art(name, canvas, root, "mark", mark_path(name, inside[0]))
    if kind == "path":
        return Art(name, canvas, root, "mark", mark_path(name, el))
    fail(f"{name}: unsupported element <{kind}>")


@dataclass(frozen=True)
class Tray:
    """The menu-bar glyph: the tree to emit, and the ink every shape is drawn in."""

    canvas: Canvas
    root: ET.Element
    ink: str


def read_tray(name: str, root: ET.Element, canvas: Canvas) -> Tray:
    """The tray source: filled rects and paths in one ink, optionally inside one <g>.

    It is emitted as the designer drew it, which is only safe because there is no <mask> in it. A
    mask was how the previous glyph cut its slots, and CoreSVG — the renderer NSImage loads this
    through — rasterises a mask at 1x and scales it up: measured against rsvg-convert, slot-centre
    alpha 90 of 255 at 2x where it must be 0, max alpha error 233, every edge soft on a Retina menu
    bar. That cost a rewrite last time. Refusing one here is the assertion that keeps it gone.
    """
    shapes = list(root)
    if len(shapes) == 1 and tag(name, shapes[0]) == "g":
        attrs(name, shapes[0], GROUP_ATTRS)
        shapes = list(shapes[0])
    inks = set()
    for el in shapes:
        kind = tag(name, el)
        if kind == "mask":
            fail(f"{name}: a <mask> is not supported — CoreSVG rasterises one at 1x and the glyph "
                 "blurs on a Retina menu bar. Cut the shape in the path data instead")
        if kind == "rect":
            inks.add(attrs(name, el, FILLED_RECT_ATTRS)["fill"])
        elif kind == "path":
            inks.add(attrs(name, el, FILLED_PATH_ATTRS, TRAY_PATH_OPTIONAL)["fill"])
        else:
            fail(f"{name}: unsupported element <{kind}>")
    if not shapes:
        fail(f"{name}: draws nothing")
    if len(inks) != 1:
        fail(f"{name}: a template image is one ink, and this draws in {', '.join(sorted(inks))}")
    return Tray(canvas, root, inks.pop())


# What the designer ships, and what each file is for. The appearances are read even where their
# colour is never used — `mono` contributes geometry only (artwork.py holds it against light and
# dark), because a layer whose appearances have drifted apart is exactly what has no other witness.
LAYERS = (
    ("background", "layer1-background", ("light", "dark")),
    ("contour", "layer2-contour", ("light", "dark", "mono")),
    ("sparkle", "layer3-sparkle", ("light", "dark", "mono")),
)
TRAY_SOURCE = "menubarTemplate.svg"


@dataclass(frozen=True)
class Sources:
    """Every designer file, read and whitelist-checked; nothing compared across files yet."""

    art: dict[str, dict[str, Art]]  # layer key -> appearance -> art
    tray: Tray


def parse_sources(src: Path) -> Sources:
    art: dict[str, dict[str, Art]] = {}
    for key, stem, appearances in LAYERS:
        art[key] = {}
        for appearance in appearances:
            name = f"{stem}-{appearance}.svg"
            root, canvas = load(src / name, CANVAS)
            art[key][appearance] = read_art(name, root, canvas)
    root, canvas = load(src / TRAY_SOURCE, TRAY)
    return Sources(art, read_tray(TRAY_SOURCE, root, canvas))
