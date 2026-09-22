"""Cross-checking the sources against each other, into the one Design the outputs are made from.

The art is authored once per appearance, so a layer's geometry exists in two or three files and
nothing in SVG makes them agree. This is where they are made to: a layer's appearances must be
byte-identical once colour is taken out of them (README: "One geometry across every appearance and
size"). It is the only check there is — the outputs are built from the light files alone, so a dark
file that has drifted would ship its drift silently into the appearance nobody was looking at.
"""
from __future__ import annotations

from dataclasses import dataclass

from . import fail
from .sources import LAYERS, Art, Canvas, Sources, Tray, geometry


@dataclass(frozen=True)
class Design:
    """Everything the outputs are made from, cross-checked across the sources."""

    canvas: Canvas
    ground: dict[str, Art]
    contour: dict[str, Art]
    sparkle: dict[str, Art]
    tray: Tray


def one_canvas(art: dict[str, dict[str, Art]]) -> Canvas:
    """Every layer is drawn on the same canvas. They are composited on top of one another, so a
    layer on a different grid is not a smaller layer — it is the same drawing at the wrong scale."""
    seen = {(a.canvas.pixels, a.canvas.units): a.name for per in art.values() for a in per.values()}
    if len(seen) != 1:
        drawn = "; ".join(f"{name} is {p:g}px on a {u:g}-unit grid" for (p, u), name in seen.items())
        fail(f"the layers are not on one canvas: {drawn}")
    (pixels, units), _ = seen.popitem()
    return Canvas(pixels, units)


def same_geometry(key: str, per: dict[str, Art]) -> None:
    """One layer's appearances, held against each other with colour taken out."""
    shapes: dict[bytes, list[str]] = {}
    for appearance, art in per.items():
        shapes.setdefault(geometry(art), []).append(appearance)
    if len(shapes) != 1:
        groups = " vs ".join("/".join(a) for a in shapes.values())
        fail(f"the {key} layer's appearances draw different shapes: {groups}. Every appearance is "
             "the same geometry in a different colour; re-export the ones that have drifted")


def kind_of(key: str, per: dict[str, Art], want: str) -> None:
    for art in per.values():
        if art.kind != want:
            fail(f"{art.name}: draws a {art.kind}, but the {key} layer is a {want}")


def validate_artwork(sources: Sources) -> Design:
    art = sources.art
    canvas = one_canvas(art)
    # Kinds before geometry: "this file draws the wrong sort of thing" is the more fundamental
    # complaint, and a file swapped for another sort also differs from its own other appearances —
    # so checked the other way round, every such mistake is reported as drift instead.
    kind_of("background", art["background"], "ground")
    kind_of("contour", art["contour"], "mark")
    kind_of("sparkle", art["sparkle"], "mark")
    for key, _, _ in LAYERS:
        same_geometry(key, art[key])

    # The two shapes are one mark, and icon.json puts them in one group on the strength of that.
    # Were they ever to differ, one group would paint them both in the contour's colour and the
    # sparkle would vanish into it without a word.
    for appearance in ("light", "dark"):
        contour, sparkle = art["contour"][appearance], art["sparkle"][appearance]
        if contour.colour != sparkle.colour:
            fail(f"the {appearance} contour is {contour.colour} and its sparkle {sparkle.colour}; "
                 "the two shapes are one mark and are drawn in one colour")
        # Only that they differ, not by how much: a mark the colour of its own ground is an icon
        # that renders as a blank square, and a blank square is indistinguishable from a working
        # one in every check downstream of here. How much contrast is enough is the designer's.
        ground = art["background"][appearance]
        if contour.colour.upper() == ground.colour.upper():
            fail(f"the {appearance} mark and ground are both {ground.colour}; the icon would be blank")

    return Design(canvas, art["background"], art["contour"], art["sparkle"], sources.tray)
