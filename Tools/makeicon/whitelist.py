"""The whitelist: what the designer's SVGs may contain.

The generator exists to refuse art it cannot reproduce. An attribute it does not know (transform, ry,
opacity, clip-path, style, ...) changes the designer's picture and would vanish from the generated
layers without a word, so every attribute is checked against a list of the ones understood, and
every element against the structure expected (sources.py). Nothing else gets through.
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
_POINT = rf"{_NUM}[\s,]+{_NUM}"
NUMBER = Kind("a number", _NUM)
LENGTH = Kind("a non-negative number", r"\+?(?:\d+(?:\.\d*)?|\.\d+)")
COLOUR = Kind("a #RRGGBB colour", r"#[0-9A-Fa-f]{6}")
REF = Kind("a url(#id) reference", r"url\(#[A-Za-z_][\w.-]*\)")
PAINT = Kind("a #RRGGBB colour or url(#id)", rf"{COLOUR.pattern}|{REF.pattern}")
ID = Kind("an id", r"[A-Za-z_][\w.-]*")
POLYGON = Kind("an absolute M/L/Z polygon", rf"\s*M\s*{_POINT}(?:\s*L\s*{_POINT}){{2,}}\s*Z\s*")

# What may be drawn. Every attribute here that is not paint (fill, stroke, fill-opacity) is geometry,
# and GEOMETRY_ATTRS is exactly those, so two shapes with equal geometry() cover the same pixels.
PATH_ATTRS = {"d": POLYGON, "fill": PAINT}
STROKE_ATTRS = {"stroke": PAINT, "stroke-width": LENGTH, "stroke-linejoin": "round"}  # all or none
LINE_ATTRS = {"x": NUMBER, "y": NUMBER, "width": LENGTH, "height": LENGTH, "rx": LENGTH}
GROUND_ATTRS = {"width": LENGTH, "height": LENGTH, "fill": REF}  # x and y may be given, as 0
GEOMETRY_ATTRS = ("d", "x", "y", "width", "height", "rx", "stroke-width", "stroke-linejoin")


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


def polygon(d: str) -> list[tuple[float, float]]:
    """The vertices of an absolute M/L/Z polygon, the one kind of path the whitelist admits."""
    if not POLYGON.ok(d):
        fail(f"path {d!r} is not {POLYGON.what}")
    nums = [float(n) for n in re.findall(_NUM, d)]
    return list(zip(nums[0::2], nums[1::2]))
