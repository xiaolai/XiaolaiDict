"""`Tools/metal-cache-guard.sh` — clears the build cache when the Metal cryptex has remounted.

The defect it exists for: `metal` lives on a cryptex whose directory name carries a random suffix,
that suffix changes when the volume remounts, and Xcode's cache records the absolute path. The next
build then dies with "unable to spawn process '…/metal'" — zero `Test run with` lines and exit 1, a
build failure wearing a test failure's clothes (ADR-0026).

Both directions are held here, because the guard is only useful if it fires on a stale tree *and*
leaves a current one alone. Deleting a current cache is not a harmless false positive: it forces a
full MLX recompile, measured at ~6 minutes debug and ~22 release.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "metal-cache-guard.sh"
CURRENT = "/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v27.1.266.1.3Or21M/Metal.xctoolchain/usr/bin/metal"
OLD_ID = "MetalToolchain-v27.1.266.1.Apk4m6"
NEW_ID = "MetalToolchain-v27.1.266.1.3Or21M"


class MetalCacheGuard(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="metal-guard-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def run_guard(self, build_root=None):
        return subprocess.run(
            [str(SCRIPT), str(build_root or self.root / ".build"), CURRENT],
            capture_output=True, text=True)

    def cache(self, name, *, ident, binary=False):
        """One cache directory holding a toolchain path, as text or as msgpack-ish binary."""
        d = self.root / ".build" / "out" / "Intermediates.noindex" / name
        d.mkdir(parents=True, exist_ok=True)
        payload = f"/var/run/.../{ident}/Metal.xctoolchain/usr/bin/metal".encode()
        if binary:
            payload = b"\x82\xa4path" + payload + b"\x00\xc3\xa5stale"
        (d / ("task-store.msgpack" if binary else "manifest.dat")).write_bytes(payload)
        return d

    def test_a_stale_directory_is_removed(self):
        d = self.cache("XCBuildData", ident=OLD_ID)
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(d.exists(), "a cache holding the old cryptex id must be cleared")
        self.assertIn(NEW_ID, result.stdout, "it must say which toolchain it moved to")

    def test_a_current_directory_is_left_alone(self):
        d = self.cache("XCBuildData", ident=NEW_ID)
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(d.exists(), "a cache already on the current toolchain must not be cleared")
        self.assertEqual(result.stdout, "", "and it must say nothing at all")

    def test_a_current_binary_cache_is_left_alone(self):
        """The bug this locks: `grep -o` on a binary file prints "Binary file … matches" instead of
        the match, and that line equals no id — so without `-a` every directory read as stale and a
        current cache was deleted on every build. Found before shipping, by running the guard twice
        on a tree it had nothing to do to."""
        d = self.cache("XCBuildData", ident=NEW_ID, binary=True)
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(d.exists(), "a binary cache on the current toolchain must not be cleared")
        self.assertEqual(result.stdout, "")

    def test_a_stale_binary_cache_is_still_removed(self):
        d = self.cache("XCBuildData", ident=OLD_ID, binary=True)
        self.assertEqual(self.run_guard().returncode, 0)
        self.assertFalse(d.exists())

    def test_every_holder_is_found_not_just_the_first(self):
        """The hand-typed cure missed holders twice — once the second `XCBuildData`, once the Release
        Metal directory — and each time the next build failed identically. The holders are found
        rather than listed for that reason, so a tree with several loses all of them in one pass."""
        dirs = [
            self.cache("XCBuildData", ident=OLD_ID),
            self.cache("mlx-swift.build/Debug/mlx-swift_Cmlx-b.build/Metal", ident=OLD_ID),
            self.cache("mlx-swift.build/Release/mlx-swift_Cmlx-b.build/Metal", ident=OLD_ID, binary=True),
        ]
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        for d in dirs:
            self.assertFalse(d.exists(), f"{d} survived, and the build would fail on it")

    def test_it_is_idempotent(self):
        self.cache("XCBuildData", ident=OLD_ID)
        self.assertEqual(self.run_guard().returncode, 0)
        second = self.run_guard()
        self.assertEqual(second.returncode, 0)
        self.assertEqual(second.stdout, "", "a second run has nothing to do and must say nothing")

    def test_no_build_directory_is_not_an_error(self):
        result = self.run_guard(build_root=self.root / "never-built")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_no_metal_toolchain_is_not_an_error(self):
        self.cache("XCBuildData", ident=OLD_ID)
        result = subprocess.run([str(SCRIPT), str(self.root / ".build"), ""],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, "a machine with no Metal toolchain is not this script's business")

    def test_a_metal_path_with_no_cryptex_component_is_left_alone(self):
        """A toolchain installed somewhere else has no id to compare against, so there is nothing to
        clear — and guessing would delete a cache that is fine."""
        d = self.cache("XCBuildData", ident=OLD_ID)
        result = subprocess.run([str(SCRIPT), str(self.root / ".build"), "/usr/bin/metal"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(d.exists())


if __name__ == "__main__":
    unittest.main()
