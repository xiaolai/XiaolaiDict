"""The real sources reproduce Resources/, byte for byte, and each output is what it claims to be."""
from __future__ import annotations

import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

from fixtures import (
    DESIGN,
    GOLDEN,
    OUTPUTS,
    TRAY,
    Workspace,
    artwork,
    build,
    outputs,
    publish,
    render,
    run,
    sources,
    whitelist,
)


def ictool() -> pathlib.Path | None:
    """Icon Composer's renderer. `xcrun ictool` finds a different, actool-family binary that only
    speaks plist and cannot export an image, so the path is taken from the active developer dir."""
    found = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True)
    if found.returncode != 0:
        return None
    path = (pathlib.Path(found.stdout.strip()).parent
            / "Applications/Icon Composer.app/Contents/Executables/ictool")
    return path if path.is_file() else None


def png_pixel(data: bytes, fx: float, fy: float) -> tuple[int, int, int]:
    """One pixel of a PNG, at a fraction of its width and height, as (r, g, b). Read through
    ImageIO rather than decoded here: the renders are palette-free RGBA but nothing guarantees it,
    and a hand-rolled decoder that guesses wrong reports colours that were never in the file."""
    import plistlib
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        f.write(data)
        path = f.name
    size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                          capture_output=True, text=True).stdout
    w = int(re.search(r"pixelWidth: (\d+)", size).group(1))
    h = int(re.search(r"pixelHeight: (\d+)", size).group(1))
    x, y = int(w * fx), int(h * fy)
    # Crop one pixel and re-read it as raw RGB: sips can do both, and both are system tools.
    one = path + ".one.png"
    subprocess.run(["sips", "-c", "1", "1", "--cropOffset", str(y), str(x), path, "--out", one],
                   capture_output=True, check=True)
    raw = subprocess.run(["sips", "-s", "format", "bmp", one, "--out", one + ".bmp"],
                         capture_output=True)
    body = pathlib.Path(one + ".bmp").read_bytes()
    offset = int.from_bytes(body[10:14], "little")
    b, g, r = body[offset], body[offset + 1], body[offset + 2]
    for f in (path, one, one + ".bmp"):
        pathlib.Path(f).unlink(missing_ok=True)
    return (r, g, b)


def walk(root: ET.Element) -> list[tuple[str, dict[str, str]]]:
    """Every element of a tree in document order, as (tag, attributes)."""
    return [(el.tag, dict(el.attrib)) for el in root.iter()]


class Outputs(unittest.TestCase):
    files: dict[str, bytes]

    @classmethod
    def setUpClass(cls) -> None:
        cls.files = build()

    def test_real_sources_reproduce_resources(self) -> None:
        # Resources/ is what `make icon` last wrote. A difference is either a regression here or
        # art that changed without the icon being regenerated; both need a person to look.
        golden = outputs(GOLDEN)
        self.assertEqual(sorted(self.files), sorted(golden))
        for name in golden:
            self.assertEqual(self.files[name], golden[name], f"{name} differs from Resources/")

    def test_command_line_end_to_end(self) -> None:
        ws = Workspace(self)
        proc = run(ws.src, ws.resources)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stderr, "")
        self.assertIn(f"wrote into {ws.resources}", proc.stdout)
        self.assertEqual(outputs(ws.resources), self.files)
        self.assertEqual(ws.listing(), OUTPUTS)

    def test_layer_asset_is_the_source_but_for_its_paint(self) -> None:
        # The claim the whole generator rests on. Not "the geometry is right" — nobody can read
        # that off a path — but "the geometry is the designer's own bytes", which a machine can
        # check. Every element, every attribute, in order; only a paint value may differ, and only
        # by having become white.
        for layer, stem in (("contour", "layer2-contour"), ("sparkle", "layer3-sparkle")):
            with self.subTest(layer=layer):
                source, _ = sources.load(DESIGN / f"{stem}-light.svg", sources.CANVAS)
                asset = ET.fromstring(self.files[f"XiaolaiDict.icon/Assets/{layer}.svg"])
                want, got = walk(source), walk(asset)
                self.assertEqual([t for t, _ in want], [t for t, _ in got])
                for (_, a), (tag, b) in zip(want, got):
                    self.assertEqual(sorted(a), sorted(b), tag)
                    for name, value in a.items():
                        if name in whitelist.PAINT_ATTRS and value != "none":
                            self.assertEqual(b[name], "#FFFFFF", f"{tag} {name}")
                        else:
                            self.assertEqual(b[name], value, f"{tag} {name}")

    def test_menu_bar_template_is_the_source(self) -> None:
        # Paint included, here: a template image's ink is never read, so there is nothing to
        # rewrite and nothing that may differ.
        source, _ = sources.load(DESIGN / TRAY, sources.TRAY)
        self.assertEqual(walk(ET.fromstring(self.files["MenuBarIcon.svg"])), walk(source))

    def test_document_colours_come_from_the_sources(self) -> None:
        design = artwork.validate_artwork(sources.parse_sources(DESIGN))
        doc = json.loads(self.files["XiaolaiDict.icon/icon.json"])

        def solids(specializations: list) -> dict[str, str]:
            return {s.get("appearance", "light"): s["value"]["solid"] for s in specializations}

        # The ground carries light and dark and NOTHING else. A tinted entry here is not merely
        # unnecessary, it is ignored: set to a garish red the ground still rendered (110, 91, 202),
        # byte-identical to the document without it, because the system replaces the ground outright
        # in the tinted and clear appearances. Measured 2026-09-22.
        want = {a: render.hex_to_srgb(design.ground[a].colour) for a in ("light", "dark")}
        self.assertEqual(solids(doc["fill-specializations"]), want)
        for group in doc["groups"]:
            for layer in group["layers"]:
                mark = getattr(design, layer["name"])
                want = {a: render.hex_to_srgb(mark[a].colour) for a in ("light", "dark")}
                # And every mark layer carries the tinted fill the ground must not. Without it the
                # system derives one, and derives it so dark that the mark measures 1.13:1 against
                # its own ground in TintedDark — which is not a faint mark, it is no mark.
                want["tinted"] = render.hex_to_srgb(render.TINTED)
                self.assertEqual(solids(layer["fill-specializations"]), want, layer["name"])

    def test_every_group_is_flat(self) -> None:
        # The reader looked at the bevelled default and rejected it, so flatness is a decision the
        # document has to keep making. A group added later without the treatment — or a layer added
        # without `glass: false` — brings the chrome piping back on that layer alone, which is
        # harder to notice than the whole icon changing.
        doc = json.loads(self.files["XiaolaiDict.icon/icon.json"])
        self.assertTrue(doc["groups"])
        for group in doc["groups"]:
            self.assertFalse(group["translucency"]["enabled"], group["name"])
            self.assertFalse(group["specular"], group["name"])
            self.assertEqual(group["shadow"]["kind"], "none", group["name"])
            self.assertTrue(group["layers"])
            for layer in group["layers"]:
                self.assertFalse(layer["glass"], layer["name"])

    def test_rendering_leaves_the_sources_as_the_designer_wrote_them(self) -> None:
        # Nothing in the render stage may write back into the Design it was given. The tray is the
        # case that nearly did: it is emitted unchanged, so it was the one tree handed to the
        # serialiser without a copy, and `ET.indent` rewrites its argument in place.
        #
        # Comparing two renders cannot see this — `ET.indent` is idempotent, so the second render
        # of an already-indented tree comes back byte-identical and the check passes over the bug.
        # What the mutation actually damages is the *source*, so the source is what to look at.
        design = artwork.validate_artwork(sources.parse_sources(DESIGN))
        before = {name: ET.tostring(art.root)
                  for layer in (design.ground, design.contour, design.sparkle)
                  for name, art in layer.items()}
        before["tray"] = ET.tostring(design.tray.root)
        render.build_outputs(design)
        after = {name: ET.tostring(art.root)
                 for layer in (design.ground, design.contour, design.sparkle)
                 for name, art in layer.items()}
        after["tray"] = ET.tostring(design.tray.root)
        self.assertEqual(before, after)

    @unittest.skipUnless(ictool() is not None, "needs Icon Composer's ictool")
    def test_the_mark_renders_as_an_outline_not_a_blob(self) -> None:
        """The contour is a stroke, and a renderer that drops the stroke fills the path instead —
        which turns this icon into a solid navy tile with the sparkle gone, silently, with no warning
        from actool or at launch.

        That is not hypothetical: it is exactly what `--design-generation 26` does with these
        layers, measured 2026-09-22 (ink 126,860 pixels of 262,144 against 61,366 correct; the cell
        the mark encloses comes back ink-coloured instead of ground-coloured). Shipping the SVG
        anyway is a decision on record — see AGENTS.md — and this check is what remains available:
        it holds the generation we support and can test to drawing an outline. If generation 27
        ever acquires the same defect, this fails instead of the icon quietly becoming a blob.
        """
        ws = Workspace(self)
        publish.publish_outputs(ws.resources, self.files)
        out = ws.resources.parent / "render.png"
        proc = subprocess.run(
            [str(ictool()), str(ws.resources / "XiaolaiDict.icon"), "--export-image",
             "--output-file", str(out), "--platform", "macOS", "--rendition", "Default",
             "--width", "256", "--height", "256", "--scale", "1", "--design-generation", "27"],
            capture_output=True, text=True, timeout=300)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        # A point well inside the contour and clear of the sparkle's arms: a stroked contour leaves
        # it showing the ground, a filled one floods it. The sparkle is right of centre and its
        # west arm runs along the middle, so the upper left of the counter is the clear quarter.
        cell = png_pixel(out.read_bytes(), 0.36, 0.33)
        self.assertLess(cell[2] - cell[0], 30,
                        f"the cell the mark encloses came back {cell}, which is ink, not ground — "
                        "the contour filled instead of stroking")

    @unittest.skipUnless(shutil.which("xcrun") and subprocess.run(
        ["xcrun", "--find", "actool"], capture_output=True).returncode == 0, "needs Xcode's actool")
    def test_actool_compiles_the_document(self) -> None:
        # What the Makefile does with the document, minus the app around it.
        ws = Workspace(self)
        publish.publish_outputs(ws.resources, self.files)
        compiled = ws.resources.parent / "compiled"
        compiled.mkdir()
        proc = subprocess.run(
            ["xcrun", "actool", "--compile", str(compiled), "--app-icon", "XiaolaiDict",
             "--output-partial-info-plist", str(compiled / "partial.plist"), "--platform", "macosx",
             "--minimum-deployment-target", "26.0", "--target-device", "mac", "--errors", "--warnings",
             "--output-format", "human-readable-text", str(ws.resources / "XiaolaiDict.icon")],
            capture_output=True, text=True, timeout=300)
        report = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, report)
        self.assertNotRegex(report.lower(), r": (warning|error):")
        info = subprocess.run(["xcrun", "assetutil", "--info", str(compiled / "Assets.car")],
                              capture_output=True, text=True, timeout=300)
        self.assertIn("IconImageStack", info.stdout)


if __name__ == "__main__":
    unittest.main()
