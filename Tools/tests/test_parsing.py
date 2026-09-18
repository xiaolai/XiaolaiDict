"""The whitelist's value parsers, and that it leaves no geometry unchecked."""
from __future__ import annotations

import unittest

from fixtures import render, whitelist


class Parsing(unittest.TestCase):
    def test_whitelist_leaves_no_geometry_unchecked(self) -> None:
        # Everything a shape may carry is either compared as geometry, or is paint and checked as
        # paint. An attribute in neither set would be accepted, differ between files, and be lost.
        admitted = {*whitelist.PATH_ATTRS, *whitelist.STROKE_ATTRS, *whitelist.LINE_ATTRS}
        self.assertEqual(admitted - {"fill", "stroke"}, set(whitelist.GEOMETRY_ATTRS))

    def test_polygon(self) -> None:
        self.assertEqual(whitelist.polygon("M1 2 L3 4 L5 6 Z"), [(1, 2), (3, 4), (5, 6)])
        self.assertEqual(whitelist.polygon("M.5 -1 L3,4 L5 6 Z"), [(0.5, -1), (3, 4), (5, 6)])
        for bad in ("M1 2 l3 4 L5 6 Z", "M1 2 3 4 5 6 Z", "M1 2 L3 4 Z", "M1 2 L3 4 L5 6",
                    "M1..2 L3 4 L5 6 Z"):
            with self.subTest(d=bad):
                with self.assertRaises(SystemExit) as cm:
                    whitelist.polygon(bad)
                self.assertIn("is not an absolute M/L/Z polygon", str(cm.exception))

    def test_colour(self) -> None:
        self.assertEqual(render.hex_to_srgb("#FF8000"), "srgb:1.00000,0.50196,0.00000,1.00000")
        for bad in ("###AABBCC", "AABBCC", "#ABC", "#AABBCCDD", "#GGGGGG"):
            with self.subTest(colour=bad):
                with self.assertRaises(SystemExit) as cm:
                    render.hex_to_srgb(bad)
                self.assertIn("is not a #RRGGBB colour", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
