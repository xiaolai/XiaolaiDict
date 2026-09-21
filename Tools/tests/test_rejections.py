"""Art the generator cannot reproduce faithfully is refused, by name, never approximated."""
from __future__ import annotations

import subprocess
import unittest

from fixtures import (
    DARK_BACK,
    DARK_BG_RECT,
    DARK_CARD,
    DARK_GLOW_STOPS,
    LINE_1,
    SCRIPT,
    SLOT_1,
    SLOT_2,
    TRAY,
    Workspace,
    run,
)

# (file, text, replacement, what the error must say). Each is one way the designer's art can stop
# being something the script reproduces faithfully; every one must be refused, by name, with the
# script's own error line rather than a traceback.
REJECTIONS = [
    # Attributes outside the whitelist change the picture and would vanish from the layers.
    ("xiaolaidict-icon-dark.svg", DARK_CARD, 'transform="translate(100 0)" ' + DARK_CARD,
     "unsupported attribute transform"),
    ("xiaolaidict-icon.svg", LINE_1, LINE_1[:-1] + ' ry="2">', "unsupported attribute ry"),
    ("xiaolaidict-icon-dark.svg", DARK_CARD, 'clip-path="url(#c)" ' + DARK_CARD, "unsupported attribute clip-path"),
    ("xiaolaidict-icon-dark.svg", DARK_CARD, 'stroke-linecap="square" ' + DARK_CARD,
     "unsupported attribute stroke-linecap"),
    ("xiaolaidict-icon-dark.svg", DARK_CARD, 'style="opacity:.5" ' + DARK_CARD, "unsupported attribute style"),
    ("xiaolaidict-icon-layer-3-card.svg", '<g fill="#241704">', '<g fill="#241704" opacity="0.5">',
     "unsupported attribute opacity"),
    ("xiaolaidict-icon-dark.svg", '<radialGradient id="top"', '<radialGradient id="top" fx="500"',
     "unsupported attribute fx"),
    ("xiaolaidict-icon-dark.svg", '<linearGradient id="bg"', '<linearGradient id="bg" spreadMethod="reflect"',
     "unsupported attribute spreadMethod"),
    ("xiaolaidict-icon-dark.svg", "<defs>", "<defs><style>path{opacity:.5}</style>", "unsupported element <style>"),
    ("xiaolaidict-icon.svg", "</svg>", '<circle cx="9" cy="9" r="9" fill="#000000"></circle></svg>',
     "unsupported element <circle>"),
    # Paint the generated document cannot carry: one layer has one fill.
    ("xiaolaidict-icon-dark.svg", DARK_BACK, 'fill="#2B2D32" stroke="#FF0000"', "differs from its fill"),
    ("xiaolaidict-icon.svg", 'fill="url(#front)" stroke="url(#front)"', 'fill="url(#front)" stroke="#EFAE3C"',
     "differs from its fill"),
    ("xiaolaidict-icon-dark.svg", 'fill="url(#front)" stroke="url(#front)"', 'fill="url(#front)"',
     "stroke, stroke-width and stroke-linejoin together"),
    ("xiaolaidict-icon.svg", LINE_1, LINE_1[:-1] + ' fill="#FF0000">', "unsupported attribute fill"),
    ("xiaolaidict-icon.svg", '<rect x="354" y="502"', '</g><g fill="#000000"><rect x="354" y="502"',
     "every entry line in one ink"),
    ("xiaolaidict-icon.svg", '<stop offset="0" stop-color="#EFAE3C">',
     '<stop offset="0" stop-color="#EFAE3C" stop-opacity="0.5">', "unsupported attribute stop-opacity"),
    ("xiaolaidict-icon-dark.svg", 'stop-color="#FFFFFF" stop-opacity="0"', 'stop-color="#000000" stop-opacity="0"',
     "one colour fading"),
    ("xiaolaidict-icon-dark.svg", 'stop-opacity="0.10"', 'stop-opacity="1.5"', "outside 0..1"),
    ("xiaolaidict-icon-dark.svg", 'rx="17" fill-opacity="0.55"></rect>\n    <rect x="354" y="576"',
     'rx="17" fill-opacity="1.5"></rect>\n    <rect x="354" y="576"', "outside 0..1"),
    ("xiaolaidict-icon-dark.svg", DARK_BACK, 'fill="url(#front)" stroke="url(#front)"', "stack painted with solid"),
    ("xiaolaidict-icon-layer-2-stack.svg", 'fill="#D5D5D0" stroke="#D5D5D0"', 'fill="#D5D5D1" stroke="#D5D5D1"',
     "disagree on colour"),
    ("xiaolaidict-icon-dark.svg", "</linearGradient>\n  </defs>",
     '</linearGradient>\n<linearGradient id="spare" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" '
     'y2="1"><stop offset="0" stop-color="#000000"></stop><stop offset="1" stop-color="#000000"></stop>'
     "</linearGradient>\n  </defs>", "never used"),
    ("xiaolaidict-icon-dark.svg", 'fill="url(#front)" stroke="url(#front)"', 'fill="url(#nope)" stroke="url(#nope)"',
     "names no gradient"),
    ("xiaolaidict-icon-dark.svg", 'x1="0" y1="0" x2="0" y2="1024">\n      <stop offset="0" stop-color="#1D1E21">',
     'x1="0" y1="0" x2="1024" y2="1024">\n      <stop offset="0" stop-color="#1D1E21">', "vertical"),
    # Colours: exactly #RRGGBB, nothing looser.
    ("xiaolaidict-icon-dark.svg", DARK_BACK, 'fill="###2B2D32" stroke="###2B2D32"',
     "'###2B2D32' is not a #RRGGBB colour"),
    ("xiaolaidict-icon-dark.svg", '<stop offset="0" stop-color="#1D1E21">',
     '<stop offset="0" stop-color="###1D1E21">', "'###1D1E21' is not a #RRGGBB colour"),
    ("xiaolaidict-icon-dark.svg", DARK_GLOW_STOPS, DARK_GLOW_STOPS.replace("#FFFFFF", "###FFFFFF"),
     "'###FFFFFF' is not a #RRGGBB colour"),
    # Grounds: the whole canvas, in the one order the document reproduces.
    ("xiaolaidict-icon-dark.svg", DARK_BG_RECT, '<rect width="1" height="1024" fill="url(#bg)">',
     "cover the whole 1024x1024 canvas"),
    ("xiaolaidict-icon.svg", '<rect width="1024" height="1024" fill="url(#bg)">',
     '<rect x="10" width="1024" height="1024" fill="url(#bg)">', "cover the whole 1024x1024 canvas"),
    ("xiaolaidict-icon-layer-1-background.svg", 'fill="url(#bg)">', 'fill="url(#bg)" opacity="0.5">',
     "unsupported attribute opacity"),
    ("xiaolaidict-icon-dark.svg", DARK_BG_RECT, '<rect width="1024" height="1024" fill="#000000">',
     "fill='#000000' is not a url(#id) reference"),
    ("xiaolaidict-icon-dark.svg", 'fill="url(#bg)"></rect>\n  <rect width="1024" height="1024" fill="url(#top)">',
     'fill="url(#top)"></rect>\n  <rect width="1024" height="1024" fill="url(#bg)">',
     "the gradient then the radial glow"),
    # Structure and geometry.
    ("xiaolaidict-icon-tinted.svg", 'L828 409', 'L829 409', "geometry differs from the layer files"),
    ("xiaolaidict-icon-layer-3-card.svg", 'L772 355', 'l772 355', "is not an absolute M/L/Z polygon"),
    ("xiaolaidict-icon-layer-3-card.svg", '<g fill="#241704">', '<g fill="#241704"><rect x="1" y="1" width="1" '
     'height="1" rx="0"></rect>', "(back to front)"),
    ("xiaolaidict-icon-tinted.svg", '<rect width="1024" height="1024" fill="url(#bg)"></rect>', "",
     "(back to front)"),
    ("xiaolaidict-icon.svg", 'viewBox="0 0 1024 1024"', 'viewBox="0 0 512 512"', "viewBox='0 0 512 512'"),
    # Malformed input: the script's own error line, never a traceback.
    ("xiaolaidict-icon-dark.svg", ' r="920"', "", "<radialGradient> is missing r"),
    ("xiaolaidict-icon-dark.svg", DARK_GLOW_STOPS, DARK_GLOW_STOPS + '<stop offset="1" stop-color="#FFFFFF"></stop>',
     "exactly two stops"),
    ("xiaolaidict-icon-dark.svg", 'x2="0" y2="1024">\n      <stop offset="0" stop-color="#1D1E21">',
     'x2="0" y2="bottom">\n      <stop offset="0" stop-color="#1D1E21">', "y2='bottom' is not a number"),
    ("xiaolaidict-icon-layer-2-stack.svg", 'stroke-width="56" stroke-linejoin="round"></path>\n</svg>',
     'stroke-width="wide" stroke-linejoin="round"></path>\n</svg>', "stroke-width='wide' is not"),
    ("xiaolaidict-icon-tinted.svg", "</svg>", "", "not well-formed XML"),
    # Encodings the parser cannot decode: each is refused with the file's name, whatever the codec
    # machinery raises (LookupError for unknown and non-text codecs, ValueError for multi-byte ones).
    ("xiaolaidict-icon.svg", "<svg xmlns=", '<?xml version="1.0" encoding="x-bogus"?>\n<svg xmlns=',
     "xiaolaidict-icon.svg: its character encoding cannot be used (unknown encoding: x-bogus)"),
    ("xiaolaidict-icon.svg", "<svg xmlns=", '<?xml version="1.0" encoding="hex"?>\n<svg xmlns=',
     "xiaolaidict-icon.svg: its character encoding cannot be used ('hex' is not a text encoding"),
    ("xiaolaidict-icon.svg", "<svg xmlns=", '<?xml version="1.0" encoding="shift_jis"?>\n<svg xmlns=',
     "xiaolaidict-icon.svg: its character encoding cannot be used (multi-byte encodings are not supported)"),
    ("xiaolaidict-icon.svg", "<svg xmlns=", '<!DOCTYPE svg [<!ENTITY size "1024">]>\n<svg xmlns=',
     "a DOCTYPE is not supported"),
    ("xiaolaidict-icon.svg", "<svg xmlns=", '<?xml-stylesheet href="restyle.css"?>\n<svg xmlns=',
     "processing instruction <?xml-stylesheet?>"),
    # The menu-bar glyph: every mask child understood, or refused.
    (TRAY, SLOT_2, SLOT_2 + '<circle cx="15" cy="12.4" r="0.8" fill="#000"></circle>',
     "unsupported element <circle>"),
    (TRAY, "</svg>", '<path d="M0 0 L1 0 L1 1 Z" fill="#000"></path></svg>', "unsupported element <path>"),
    (TRAY, '<mask id="slots">', '<mask id="slots" mask-type="alpha">', "unsupported attribute mask-type"),
    (TRAY, '<mask id="slots">', '<mask id="slots"><rect x="1" y="1" width="1" height="1" rx="0" fill="#000">'
     "</rect>", "start with the hexagon"),
    (TRAY, SLOT_1, SLOT_1 + ' transform="scale(2)"', "unsupported attribute transform"),
    (TRAY, '<rect width="22" height="22"', '<rect width="11" height="22"', "cover the whole 22x22 canvas"),
    (TRAY, 'stroke="#fff"', 'stroke="#000"', "stroke='#000', expected '#fff'"),
    (TRAY, "L11 18.7", "L11 12", "convex"),
    (TRAY, SLOT_1, '<rect x="4.4" y="8.8" width="8.2" height="1.6" rx="0.8"', "reaches the hexagon's stroke"),
    (TRAY, SLOT_1, '<rect x="5.9" y="8.8" width="8.2" height="1.6" rx="1"', "corner radius"),
    (TRAY, '<rect x="5.9" y="11.6"', '<rect x="5.9" y="9.6"', "slots overlap"),
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
        (ws.src / "xiaolaidict-icon-tinted.svg").unlink()
        self.assert_refused(run(ws.src, ws.resources), "missing source file")

    def test_usage_names_this_script(self) -> None:
        self.assert_refused(run(), f"usage: {SCRIPT.name} <Tools/icon dir> <Resources dir>")

    def test_missing_resources_dir(self) -> None:
        ws = Workspace(self)
        self.assert_refused(run(ws.src, ws.resources / "nope"), "no such directory")


if __name__ == "__main__":
    unittest.main()
