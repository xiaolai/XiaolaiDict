"""What the designer's SVGs may contain, and the one thing the generator rewrites.

The contract is narrow on purpose: **geometry is emitted verbatim, and only paint is rewritten.** A
layer asset is the designer's own markup with its paint attributes set to white; colour then lives
in icon.json, per appearance. Nothing re-describes the art, so there is no second description for it
to drift from — the guarantee the old generator bought by enumerating every geometry attribute, this
one gets by not touching them.

That holds only while paint is findable. An attribute carrying colour in a form this module does not
know — `style`, `opacity`, `fill-opacity`, a gradient `url(#...)`, `filter`, `mask`, `clip-path` —
would ride through unrewritten and repaint a layer the system means to colour itself. So every
element is checked against the structure expected (sources.py) and every attribute against a list
here, and anything else stops the run rather than being quietly approximated.
"""
from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass

from . import SVG_NS, fail


@dataclass(frozen=True)
class Kind:
    """What an attribute's value must look like, and what to call it when it does not."""

    what: str
    pattern: str

    def ok(self, value: str) -> bool:
        return re.fullmatch(self.pattern, value) is not None


_NUM = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"  # as the art writes numbers: no exponent, no unit
NUMBER = Kind("a number", _NUM)
LENGTH = Kind("a non-negative number", r"\+?(?:\d+(?:\.\d*)?|\.\d+)")
COLOUR = Kind("a #RRGGBB colour", r"#[0-9A-Fa-f]{6}")
VIEWBOX = Kind("a viewBox at the origin, square", rf"0[\s,]+0[\s,]+({_NUM})[\s,]+\1")
# Path data and transforms are emitted exactly as written, so neither is interpreted here. The
# patterns refuse the characters that would make them something other than what they claim to be:
# a `url(`, an entity, an attribute closed early. What they admit, SVG renders; what they draw is
# the designer's business.
PATH_DATA = Kind("SVG path data", r"[MmLlHhVvCcSsQqTtAaZz\d\s.,+-]+")
TRANSFORM = Kind("a list of SVG transform functions",
                 rf"\s*(?:(?:matrix|translate|scale|rotate|skewX|skewY)\(\s*{_NUM}"
                 rf"(?:[\s,]+{_NUM})*\s*\)\s*)+")

# The attributes rewritten, and the only ones: a layer asset is the source with these set to white.
PAINT_ATTRS = ("fill", "stroke")

SVG_ATTRS = {"width": LENGTH, "height": LENGTH, "viewBox": VIEWBOX}
# A ground is the whole canvas, so it carries no transform: one would move it off the edge and the
# full-canvas check below would still pass, since it reads the rect's own coordinates.
GROUND_ATTRS = {"width": LENGTH, "height": LENGTH, "fill": COLOUR}  # x and y may be given, as 0
GROUP_ATTRS = {"transform": TRANSFORM}
# A mark is drawn one of two ways, and `fill="none"` is what says which. Both are here because the
# art uses both: the contour is a stroke, the sparkle a filled shape. The pair is not interchangeable
# — a stroked path carries its colour on `stroke` and a filled one on `fill` — so sources.py reads
# the fill first and then knows which table applies.
STROKED_PATH_ATTRS = {"d": PATH_DATA, "fill": "none", "stroke": COLOUR, "stroke-width": LENGTH}
STROKED_PATH_OPTIONAL = {"stroke-linejoin": "round", "stroke-linecap": "round"}
FILLED_PATH_ATTRS = {"d": PATH_DATA, "fill": COLOUR}
# Only the tray. Its glyph is one path that cuts the sparkle out of the D, and a knockout needs
# even-odd; a mark is a single shape and has no business with a fill rule, so this is not offered
# to one — a mark that asked for even-odd would be a mark drawn as something this cannot reproduce.
TRAY_PATH_OPTIONAL = {"fill-rule": "evenodd"}
FILLED_RECT_ATTRS = {"x": NUMBER, "y": NUMBER, "width": LENGTH, "height": LENGTH,
                     "rx": LENGTH, "fill": COLOUR}


def tag(name: str, el: ET.Element) -> str:
    """The element's tag without the SVG namespace. An element from any other one is refused."""
    ns, _, local = el.tag.rpartition("}")
    if ns != "{" + SVG_NS:
        fail(f"{name}: unsupported element <{el.tag}>")
    return local


def attrs(name: str, el: ET.Element, required: dict[str, Kind | str],
          optional: dict[str, Kind | str] | None = None) -> dict[str, str]:
    """The element's attributes, each checked against its rule: a Kind, or the one literal value
    allowed. An attribute missing, malformed or in neither list is refused."""
    optional = optional or {}
    what = f"{name}: <{tag(name, el)}>"
    for a in el.attrib:
        if a not in required and a not in optional:
            fail(f"{name}: unsupported attribute {a} on <{tag(name, el)}>")
    missing = [a for a in required if a not in el.attrib]
    if missing:
        fail(f"{what} is missing {', '.join(missing)}")
    for a, value in el.attrib.items():
        rule = required[a] if a in required else optional[a]
        if isinstance(rule, Kind) and not rule.ok(value):
            fail(f"{what} {a}={value!r} is not {rule.what}")
        if isinstance(rule, str) and value != rule:
            fail(f"{what} {a}={value!r}, expected {rule!r}")
    return dict(el.attrib)


def rgb(colour: str) -> bytes:
    """The three 8-bit channels of a #RRGGBB colour; the one place a colour is decoded."""
    if not COLOUR.ok(colour):
        fail(f"{colour!r} is not {COLOUR.what}")
    return bytes.fromhex(colour[1:])
