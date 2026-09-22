"""The Design as output bytes: the white layer SVGs, icon.json, and the menu-bar template.

Nothing is written to disk here; publish.py does that.

A layer asset is the designer's own markup with its paint set to white — see whitelist.py. The
geometry is never re-described, so it cannot drift; the only thing this module decides is colour,
and where the colour goes is icon.json, per appearance.
"""
from __future__ import annotations

import json

from . import fail
from .artwork import Design
from .sources import Art, Tray, repaint, svg_bytes
from .whitelist import rgb


def hex_to_srgb(colour: str) -> str:
    r, g, b = (c / 255 for c in rgb(colour))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


# --- writing layers ------------------------------------------------------------------------------


def white_svg(art: Art) -> bytes:
    """The designer's layer, painted white at full opacity. Colour lives in icon.json."""
    return svg_bytes(repaint(art.root, "#FFFFFF"))


def tray_svg(tray: Tray) -> bytes:
    """The menu-bar template, exactly as the designer drew it.

    Nothing is rewritten: it is a template image, so only its alpha is read and its ink is
    irrelevant. The previous glyph needed a rewrite because it cut its slots with a <mask>, which
    CoreSVG rasterises at 1x; sources.read_tray refuses a mask so this stays a copy.
    """
    return svg_bytes(tray.root)


# --- the document --------------------------------------------------------------------------------

# The tinted fill every mark layer carries. See the layer builder for why it is white and why
# leaving it out is not a neutral default.
TINTED = "#FFFFFF"

# Flat, deliberately, and this is the whole of that decision. Tahoe composes glass, a specular
# bevel and a shadow over a layered icon by default, and on a mark that is nothing but two strokes
# the result is chrome piping: the bevel is a fixed width, so on an 8-unit stroke it is most of the
# stroke. Measured against the system's own icons on this Mac — Calculator, Notes, Reminders,
# Terminal, Font Book — none of them reads as bevelled, so the default is not the platform idiom
# here, it is what the default does to thin art.
#
# The switch that does the work is `glass: false` on each layer, below: from a document carrying no
# treatment keys at all, it alone lands exactly on this render, while `specular` gets 33 of the way
# (of 113), `translucency` 98 and `shadow` 116. `specular` and `glass` are AND-ed, so either one
# false is enough. The other three are still written, because a document that states its intent is
# cheaper to read than one that relies on knowing which key subsumes which.
#
# What none of them reaches is the ground's edge lighting — white along the top edge, darker down
# the left, applied to the document fill rather than to a group. That is the platform's, it is on
# every icon, and there is no key for it: `edge-lighting`, `glass` and `specular` at the document
# root are all accepted and all change nothing, as is a deliberately invented key. ictool does not
# refuse an unknown root key, so one appearing to "work" there is no evidence that it did anything.
FLAT_GROUP = {
    "translucency": {"enabled": False, "value": 0.5},
    "specular": False,
    "shadow": {"kind": "none", "opacity": 0.5},
}


def build_document(d: Design) -> dict:
    """icon.json: the ground as the document's fill, and the mark as one group of flat layers."""

    def solid(colour: str) -> dict:
        return {"solid": hex_to_srgb(colour)}

    def layer(name: str, art: dict[str, Art]) -> dict:
        return {
            "name": name,
            "image-name": f"{name}.svg",
            # Off for the same reason the group is flat, and separately from it: `glass` is the
            # per-layer half of the treatment, and a layer keeps its own bevel when the group's
            # specular is already off.
            "glass": False,
            # Light and dark are the designer's. The third is not, and it is not optional either:
            # left to derive the tinted fill itself, the system renders this mark at a WCAG contrast
            # of 1.13:1 against its own ground in TintedDark, 1.47 in ClearLight and 1.57 in
            # TintedLight — measured 2026-09-22, and 1.13:1 is not a faint mark, it is no mark.
            # White takes those to 2.36, 3.86 and 5.01.
            #
            # White rather than a colour from the art, because the value is a LUMINANCE and its hue
            # is thrown away: a garish green tinted fill renders pale lavender, and a sweep across
            # six fills tracks luminance monotonically and ignores hue entirely. So this is not a
            # design decision the designer could make differently — it is the top of the one scale
            # the system reads, the same reason the layer assets themselves are white.
            #
            # One entry covers four renditions: the appearance enum is light/dark/tinted, there is
            # no "clear", and `tinted` governs TintedLight, TintedDark, ClearLight and ClearDark
            # alike. It goes on the layers and never on the document fill, where it is ignored —
            # the system replaces the ground outright in those appearances.
            "fill-specializations": [
                {"value": solid(art["light"].colour)},
                {"appearance": "dark", "value": solid(art["dark"].colour)},
                {"appearance": "tinted", "value": solid(TINTED)},
            ],
        }

    return {
        # The ground is the document's fill, not a layer. A layer would draw an opaque plate in the
        # tinted and clear appearances too, where the system means to draw its own ground — and in
        # clear that plate is the whole point of the appearance, covered over.
        "fill-specializations": [
            {"value": solid(d.ground["light"].colour)},
            {"appearance": "dark", "value": solid(d.ground["dark"].colour)},
        ],
        # TOP-FIRST: groups[0] is drawn in front, and likewise layers within a group. The sparkle
        # is the designer's layer 3 and the contour layer 2, so the sparkle comes first.
        #
        # One group, not two. The two shapes are the same colour in every appearance and they
        # touch — the sparkle's points die into the contour — so two groups would give one mark two
        # independent treatments and a seam along the join.
        "groups": [
            {
                "name": "mark",
                **FLAT_GROUP,
                "layers": [layer("sparkle", d.sparkle), layer("contour", d.contour)],
            }
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }


def build_outputs(d: Design) -> dict[str, bytes]:
    """Every output file, keyed by its path under the Resources dir. Nothing is written here."""
    assets = {"contour.svg": white_svg(d.contour["light"]),
              "sparkle.svg": white_svg(d.sparkle["light"])}
    doc = build_document(d)
    named = {layer["image-name"] for group in doc["groups"] for layer in group["layers"]}
    if named != assets.keys():
        fail(f"internal: icon.json names {sorted(named)}, but the assets made are {sorted(assets)}")
    files = {f"XiaolaiDict.icon/Assets/{name}": data for name, data in assets.items()}
    files["XiaolaiDict.icon/icon.json"] = (json.dumps(doc, indent=2) + "\n").encode()
    files["MenuBarIcon.svg"] = tray_svg(d.tray)
    return files
