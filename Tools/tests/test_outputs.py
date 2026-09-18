"""The real sources reproduce Resources/, byte for byte, and each output is what it claims to be."""
from __future__ import annotations

import math
import shutil
import struct
import subprocess
import unittest
import zlib

from fixtures import (
    DESIGN,
    GOLDEN,
    OUTPUTS,
    Workspace,
    artwork,
    build,
    outputs,
    publish,
    render,
    run,
    sources,
)


def decode_png(data: bytes) -> tuple[int, int, list[bytes]]:
    """Width, height and unfiltered rows of an 8-bit RGBA PNG. Written independently of the
    encoder under test, and only as general as it needs to be: filters None and Up."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError("no PNG signature")
    pos, chunks = 8, []
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        kind, body = data[pos + 4 : pos + 8], data[pos + 8 : pos + 8 + length]
        (crc,) = struct.unpack(">I", data[pos + 8 + length : pos + 12 + length])
        if crc != zlib.crc32(kind + body):
            raise AssertionError(f"bad CRC on {kind!r}")
        chunks.append((kind, body))
        pos += 12 + length
    if [k for k, _ in chunks] != [b"IHDR", b"IDAT", b"IEND"]:
        raise AssertionError(f"unexpected chunks {[k for k, _ in chunks]}")
    width, height, depth, colour_type, *_ = struct.unpack(">IIBBBBB", chunks[0][1])
    if (depth, colour_type) != (8, 6):
        raise AssertionError("not 8-bit RGBA")
    raw, stride = zlib.decompress(chunks[1][1]), 4 * width
    rows, prev = [], bytes(stride)
    for y in range(height):
        line = raw[y * (stride + 1) : (y + 1) * (stride + 1)]
        if line[0] == 0:
            row = line[1:]
        elif line[0] == 2:
            row = bytes((a + b) & 0xFF for a, b in zip(line[1:], prev))
        else:
            raise AssertionError(f"row {y}: unexpected filter {line[0]}")
        rows.append(row)
        prev = row
    return width, height, rows


def fade(glow, x: float, y: float) -> float:
    """The SVG radial fade's alpha, 0..255, at canvas point (x, y): pad spread, linear in t."""
    t = min(1.0, math.hypot(x - glow.cx, y - glow.cy) / glow.r)
    return (glow.a0 + (glow.a1 - glow.a0) * t) * 255


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

    def test_glow_png_is_the_svg_fade(self) -> None:
        glow = artwork.validate_artwork(sources.parse_sources(DESIGN)).glow
        width, height, rows = decode_png(self.files["XiaolaiDict.icon/Assets/dark-glow.png"])
        self.assertEqual((width, height), (1024, 1024))
        for y in range(0, 1024, 31):
            for x in range(0, 1024, 29):
                self.assertEqual(rows[y][4 * x : 4 * x + 3], b"\xff\xff\xff", f"pixel ({x}, {y})")
                self.assertEqual(rows[y][4 * x + 3], round(fade(glow, x + 0.5, y + 0.5)), f"pixel ({x}, {y})")

    def test_glow_png_scales_to_any_size(self) -> None:
        glow = sources.Radial(cx=512, cy=20, r=920, colour="#FFFFFF", a0=0.9, a1=0.0)
        size = 64
        width, height, rows = decode_png(render.radial_png(glow, size))
        self.assertEqual((width, height), (size, size))
        scale = 1024 / size
        for y in range(size):
            for x in range(size):
                want = fade(glow, (x + 0.5) * scale, (y + 0.5) * scale)
                self.assertLessEqual(abs(rows[y][4 * x + 3] - want), 1, f"pixel ({x}, {y})")

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
