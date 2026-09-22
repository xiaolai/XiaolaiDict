"""Art the generator cannot reproduce faithfully is refused, by name, never approximated."""
from __future__ import annotations

import subprocess
import unittest

from fixtures import (
    BG_DARK,
    BG_LIGHT,
    CONTOUR_LIGHT,
    CONTOUR_MONO,
    CONTOUR_PATH,
    SPARKLE_DARK,
    SPARKLE_LIGHT,
    SPARKLE_PATH,
    GROUND_LIGHT,
    GROUP_OPEN,
    SCRIPT,
    TRAY,
    TRAY_PATH,
    Workspace,
    run,
)

CONTOUR_GROUP = GROUP_OPEN + CONTOUR_PATH + "</g>"
SPARKLE_GROUP = GROUP_OPEN + SPARKLE_PATH + "</g>"

# (file, text, replacement, what the error must say). Each is one way the designer's art can stop
# being something the script reproduces faithfully; every one must be refused, by name, with the
# script's own error line rather than a traceback.
REJECTIONS = [
    # Anything that paints, other than the two attributes the generator rewrites. These are the
    # dangerous ones: the art is emitted verbatim, so a paint the whitelist did not recognise would
    # ride through into the layer and cover the colour icon.json assigns per appearance.
    (CONTOUR_LIGHT, CONTOUR_PATH, CONTOUR_PATH.replace("<path ", '<path opacity="0.5" '),
     "unsupported attribute opacity"),
    (CONTOUR_LIGHT, CONTOUR_PATH, CONTOUR_PATH.replace("<path ", '<path style="stroke:red" '),
     "unsupported attribute style"),
    (CONTOUR_LIGHT, CONTOUR_PATH, CONTOUR_PATH.replace("<path ", '<path filter="url(#f)" '),
     "unsupported attribute filter"),
    (CONTOUR_LIGHT, CONTOUR_PATH, CONTOUR_PATH.replace("<path ", '<path clip-path="url(#c)" '),
     "unsupported attribute clip-path"),
    (CONTOUR_LIGHT, CONTOUR_PATH, CONTOUR_PATH.replace("<path ", '<path stroke-opacity="0.5" '),
     "unsupported attribute stroke-opacity"),
    (CONTOUR_LIGHT, GROUP_OPEN, GROUP_OPEN.replace("<g ", '<g opacity="0.5" '),
     "unsupported attribute opacity"),
    (BG_LIGHT, GROUND_LIGHT, GROUND_LIGHT.replace("<rect ", '<rect fill-opacity="0.5" '),
     "unsupported attribute fill-opacity"),
    (BG_LIGHT, "<svg xmlns=", '<svg style="opacity:.5" xmlns=', "unsupported attribute style"),
    # Colour: exactly #RRGGBB, so a gradient reference cannot stand in for one.
    (CONTOUR_LIGHT, 'stroke="#23407A"', 'stroke="url(#g)"', "stroke='url(#g)' is not a #RRGGBB colour"),
    (BG_LIGHT, 'fill="#FBFAF6"', 'fill="url(#bg)"', "fill='url(#bg)' is not a #RRGGBB colour"),
    (BG_DARK, 'fill="#1B2A4A"', 'fill="###1B2A4A"', "'###1B2A4A' is not a #RRGGBB colour"),
    # A mark is a stroke and nothing else. A filled one floods the layer, and icon.json would then
    # be colouring a solid square.
    (CONTOUR_LIGHT, 'fill="none"', 'fill="#23407A"',
     'a <path> is either stroked, with fill="none", or filled — not both'),
    (CONTOUR_LIGHT, 'stroke-width="8"', 'stroke-dasharray="8"',
     "unsupported attribute stroke-dasharray"),
    (CONTOUR_LIGHT, ' stroke-width="8"', "", "<path> is missing stroke-width"),
    # ...and a FILLED mark has its own rules, reached by the fill not being "none".
    (SPARKLE_LIGHT, SPARKLE_PATH, SPARKLE_PATH.replace(' fill="#23407A"', ""),
     "<path> is missing fill"),
    (SPARKLE_LIGHT, 'fill="#23407A"', 'fill="url(#g)"', "fill='url(#g)' is not a #RRGGBB colour"),
    # Reached from the other side: a filled path handed a stroke, rather than a stroked path
    # handed a fill. Both land on the same refusal, and both are worth a row because the check is
    # entered by a different branch each way.
    (SPARKLE_LIGHT, SPARKLE_PATH, SPARKLE_PATH.replace("<path ", '<path stroke="#23407A" '),
     'a <path> is either stroked, with fill="none", or filled — not both'),
    (SPARKLE_LIGHT, SPARKLE_PATH, SPARKLE_PATH.replace("<path ", '<path fill-rule="evenodd" '),
     "unsupported attribute fill-rule"),
    # A ground is the whole canvas: art that stops short leaves a transparent border, and Tahoe
    # answers that by wrapping the icon in its own grey squircle and shrinking it.
    (BG_LIGHT, GROUND_LIGHT, '<rect width="50" height="100" fill="#FBFAF6"></rect>',
     "cover the whole 100x100 canvas"),
    (BG_DARK, '<rect width="100"', '<rect x="10" width="100"', "cover the whole 100x100 canvas"),
    (BG_LIGHT, GROUND_LIGHT, GROUND_LIGHT.replace("<rect ", '<rect transform="scale(2)" '),
     "unsupported attribute transform"),
    # Structure: one thing drawn per file, and the layer it is drawn for decides which.
    (SPARKLE_LIGHT, "</svg>", '<circle cx="9" cy="9" r="9" fill="#000000"></circle></svg>',
     "expected one <rect> ground or one <path> mark"),
    (CONTOUR_LIGHT, CONTOUR_PATH, CONTOUR_PATH * 2, "expected one <path> inside the <g>, not 2"),
    (BG_LIGHT, GROUND_LIGHT, CONTOUR_GROUP, "draws a mark, but the background layer is a ground"),
    (CONTOUR_LIGHT, CONTOUR_GROUP, GROUND_LIGHT, "draws a ground, but the contour layer is a mark"),
    (SPARKLE_LIGHT, SPARKLE_GROUP, '<rect width="100" height="100" fill="#23407A"></rect>',
     "draws a ground, but the sparkle layer is a mark"),
    # The canvas every layer shares. A layer on another grid is not a smaller layer — it is the
    # same drawing at the wrong scale, composited over the others.
    (SPARKLE_LIGHT, 'viewBox="0 0 100 100"', 'viewBox="0 0 200 200"', "not on one canvas"),
    (CONTOUR_LIGHT, 'viewBox="0 0 100 100"', 'viewBox="0 0 100 50"',
     "viewBox='0 0 100 50' is not a viewBox at the origin, square"),
    (SPARKLE_DARK, 'width="1024"', 'width="512"', "is 512x1024, not 1024x1024"),
    # One geometry across every appearance. The outputs are built from the light files alone, so a
    # dark or mono file that has drifted would ship its drift into the appearance nobody looked at.
    (SPARKLE_DARK, "L82 50", "L83 50",
     "the sparkle layer's appearances draw different shapes"),
    (CONTOUR_MONO, 'stroke-width="8"', 'stroke-width="9"',
     "the contour layer's appearances draw different shapes"),
    # One mark, one colour, and never the colour of its own ground.
    (SPARKLE_LIGHT, 'fill="#23407A"', 'fill="#FF0000"',
     "the light contour is #23407A and its sparkle #FF0000"),
    (BG_LIGHT, 'fill="#FBFAF6"', 'fill="#23407A"', "the light mark and ground are both #23407A"),
    # Malformed input: the script's own error line, never a traceback.
    (CONTOUR_LIGHT, 'stroke-width="8"', 'stroke-width="wide"',
     "stroke-width='wide' is not a non-negative number"),
    (CONTOUR_LIGHT, GROUP_OPEN, '<g transform="skew(2)">',
     "transform='skew(2)' is not a list of SVG transform functions"),
    (BG_DARK, "</svg>", "", "not well-formed XML"),
    # Encodings the parser cannot decode: each is refused with the file's name, whatever the codec
    # machinery raises (LookupError for unknown and non-text codecs, ValueError for multi-byte ones).
    (BG_LIGHT, "<svg xmlns=", '<?xml version="1.0" encoding="x-bogus"?>\n<svg xmlns=',
     f"{BG_LIGHT}: its character encoding cannot be used (unknown encoding: x-bogus)"),
    (BG_LIGHT, "<svg xmlns=", '<?xml version="1.0" encoding="hex"?>\n<svg xmlns=',
     f"{BG_LIGHT}: its character encoding cannot be used ('hex' is not a text encoding"),
    (BG_LIGHT, "<svg xmlns=", '<?xml version="1.0" encoding="shift_jis"?>\n<svg xmlns=',
     f"{BG_LIGHT}: its character encoding cannot be used (multi-byte encodings are not supported)"),
    (BG_LIGHT, "<svg xmlns=", '<!DOCTYPE svg [<!ENTITY size "1024">]>\n<svg xmlns=',
     "a DOCTYPE is not supported"),
    (BG_LIGHT, "<svg xmlns=", '<?xml-stylesheet href="restyle.css"?>\n<svg xmlns=',
     "processing instruction <?xml-stylesheet?>"),
    # The menu-bar glyph, which is emitted as drawn — so what may be in it is the whole of what
    # makes that safe.
    (TRAY, TRAY_PATH, '<mask id="m"></mask>' + TRAY_PATH, "a <mask> is not supported"),
    (TRAY, TRAY_PATH, TRAY_PATH + '<circle cx="9" cy="9" r="9" fill="#000000"></circle>',
     "unsupported element <circle>"),
    (TRAY, TRAY_PATH, TRAY_PATH.replace("<path ", '<path transform="scale(2)" '),
     "unsupported attribute transform"),
    (TRAY, TRAY_PATH, TRAY_PATH.replace("<path ", '<path opacity="0.5" '),
     "unsupported attribute opacity"),
    (TRAY, TRAY_PATH, TRAY_PATH.replace(' fill-rule="evenodd"', ' fill-rule="nonzero"'),
     "fill-rule='nonzero', expected 'evenodd'"),
    (TRAY, TRAY_PATH, TRAY_PATH + TRAY_PATH.replace("#000000", "#FF0000"),
     "a template image is one ink"),
    (TRAY, 'width="22"', 'width="11"', "is 11x22, not 22x22"),
]


class RejectsWhatItCannotReproduce(unittest.TestCase):
    def assert_refused(self, proc: subprocess.CompletedProcess, says: str) -> None:
        self.assertEqual(proc.returncode, 1, f"expected a refusal saying {says!r}; stderr:\n{proc.stderr}")
        self.assertNotIn("Traceback", proc.stderr)
        self.assertRegex(proc.stderr, r"\Amake-icon\.py: error: ")
        self.assertIn(says, proc.stderr)

    def test_every_rejection_is_a_named_error(self) -> None:
        for name, old, new, says in REJECTIONS:
            with self.subTest(file=name, says=says):
                ws = Workspace(self)
                ws.mutate(name, old, new)
                self.assert_refused(run(ws.src, ws.resources), says)
                self.assertEqual(ws.listing(), [], "a refused run wrote something")

    def test_missing_source_file(self) -> None:
        ws = Workspace(self)
        (ws.src / CONTOUR_MONO).unlink()
        self.assert_refused(run(ws.src, ws.resources), "missing source file")

    def test_usage_names_this_script(self) -> None:
        self.assert_refused(run(), f"usage: {SCRIPT.name} <Tools/icon dir> <Resources dir>")

    def test_missing_resources_dir(self) -> None:
        ws = Workspace(self)
        self.assert_refused(run(ws.src, ws.resources / "nope"), "no such directory")


if __name__ == "__main__":
    unittest.main()
