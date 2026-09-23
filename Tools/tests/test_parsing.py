"""The whitelist's value parsers, and that it leaves no colour unrewritten."""
from __future__ import annotations

import unittest

from fixtures import render, whitelist


class Parsing(unittest.TestCase):
    def test_whitelist_leaves_no_colour_unrewritten(self) -> None:
        # The generator's whole contract is that geometry is emitted verbatim and only paint is
        # rewritten (whitelist.PAINT_ATTRS). An attribute admitted as a colour but not repainted
        # would ride through into the layer asset and paint it, over the colour icon.json assigns
        # per appearance — so the two sets are the same set, mechanically.
        #
        # **Every table the module has, asked for by the module.** Listed by hand, this named seven
        # of the eight and left out TRAY_PATH_OPTIONAL, so a colour admitted there was the one thing
        # a check written to make that impossible could not see. A table added later is covered by
        # being a table. The derivation is self-guarding: find no tables and `carries_colour` is
        # empty, which is not PAINT_ATTRS, so the test fails rather than passing vacuously.
        tables = [value for name, value in vars(whitelist).items()
                  if not name.startswith("_") and isinstance(value, dict)]
        carries_colour = {a for table in tables
                          for a, rule in table.items() if rule is whitelist.COLOUR}
        self.assertEqual(carries_colour, set(whitelist.PAINT_ATTRS))

    def test_viewbox(self) -> None:
        for good in ("0 0 100 100", "0 0 1024 1024", "0,0,100,100", "0 0 22 22"):
            self.assertTrue(whitelist.VIEWBOX.ok(good), good)
        for bad in ("0 0 100 50", "10 0 100 100", "0 0 100", "0 0 100 100 0", "0 0 1e3 1e3"):
            self.assertFalse(whitelist.VIEWBOX.ok(bad), bad)

    def test_path_data(self) -> None:
        # Admitted as written, because it is emitted as written. What the pattern refuses is data
        # that is not path data at all: a paint reference, an entity, an attribute closed early.
        for good in ("M18 50 H82 M57 18 V82", "M18 72 V28 A10 10 0 0 1 28 18 Z", "m1 2 l3,4 z"):
            self.assertTrue(whitelist.PATH_DATA.ok(good), good)
        for bad in ("url(#g)", "M1 2 &size; Z", 'M1 2" onload="x', "M1 2 <circle/>"):
            self.assertFalse(whitelist.PATH_DATA.ok(bad), bad)

    def test_transform(self) -> None:
        for good in ("translate(50 50) scale(1.031) translate(-50 -50)", "scale(1.14)",
                     "matrix(1 0 0 1 0 0)", " rotate(45) "):
            self.assertTrue(whitelist.TRANSFORM.ok(good), good)
        for bad in ("url(#g)", "translate(50, 50) skew(2)", "scale()", "translate(a b)"):
            self.assertFalse(whitelist.TRANSFORM.ok(bad), bad)

    def test_colour(self) -> None:
        self.assertEqual(render.hex_to_srgb("#FF8000"), "srgb:1.00000,0.50196,0.00000,1.00000")
        for bad in ("###AABBCC", "AABBCC", "#ABC", "#AABBCCDD", "#GGGGGG"):
            with self.subTest(colour=bad):
                with self.assertRaises(SystemExit) as cm:
                    render.hex_to_srgb(bad)
                self.assertIn("is not a #RRGGBB colour", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
