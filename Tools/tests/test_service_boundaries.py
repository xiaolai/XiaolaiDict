"""`verify_service_boundaries`, the check that each XPC service links and carries only what it serves,
run exactly as `Tools/build-bundle.sh` writes it, against stand-ins for `otool`, `nm` and `swift-demangle`.

**A scan that finds nothing because it read nothing passes** — so each tool the check reads through has
to be shown to have answered, not merely to have found no forbidden name. Two of its three readers were
unwatched: `otool -L` and `swift-demangle` each ended in `|| true`, so either failing left an empty
list and a pass. `otool -L` does not even fail on a file that is not an object — measured, it prints
"is not an object file" and exits 0 — so its status is not enough: the list must name `libSystem`,
which every Mach-O executable links. A demangler that answered with the mangled names unchanged would
be blind to every module spelled the mangled way, so the demangled list must hold a Swift name.

The stand-ins are positive controls as well: a clean bundle passes, and a forbidden framework and a
forbidden symbol (visible only once demangled) are each refused, so the harness can fail for the
reasons the real check exists.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import os
import pathlib
import re
import stat
import subprocess
import tempfile
import unittest

from ledger_schema import REPO

SCRIPT = REPO / "Tools" / "build-bundle.sh"
PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

SERVICE = "XiaolaiDictService"
MODEL_SERVICE = "XiaolaiDictModelService"

# `otool -L`: the binary's name, then one dependency a line. STUB_OTOOL picks the answer.
OTOOL = """#!/bin/bash
case "${STUB_OTOOL:-ok}" in
    fail) echo "error: otool-classic: can't open file: $2" >&2; exit 1 ;;
    notobject) echo "$2: is not an object file"; exit 0 ;;
    sqlite) printf '%s:\\n\\t/usr/lib/libSystem.B.dylib (x)\\n\\t/usr/lib/libsqlite3.dylib (x)\\n' "$2" ;;
    *) printf '%s:\\n\\t/usr/lib/libSystem.B.dylib (x)\\n\\t/System/Library/Frameworks/Foundation.framework/Foundation (x)\\n' "$2" ;;
esac
"""

# `nm`: 200 mangled symbols, and one that demangles to a forbidden module when STUB_NM=ledger.
NM = """#!/bin/bash
for i in $(seq 1 200); do echo "0000000100000000 T \\$sSS${i}MANGLED"; done
[ "${STUB_NM:-}" = ledger ] && echo "0000000100000000 T \\$sMANGLED_LEDGER"
exit 0
"""

# `xcrun swift-demangle`: one line out for each line in, unless STUB_DEMANGLE says otherwise.
XCRUN = """#!/bin/bash
[ "$1" = swift-demangle ] || { echo "stub xcrun: unexpected $*" >&2; exit 64; }
case "${STUB_DEMANGLE:-ok}" in
    fail) echo "xcrun: error: unable to find utility \\"swift-demangle\\"" >&2; exit 72 ;;
    passthrough) cat ;;
    *) sed -e 's/\\$sMANGLED_LEDGER/XiaolaiDictCore.Ledger.init() -> XiaolaiDictCore.Ledger/' -e 's/\\$sSS/Swift.String./' ;;
esac
"""


def function(name: str) -> str:
    """One shell function, as `build-bundle.sh` defines it: from `name() {` to the first line that is `}`."""
    found = re.search(rf"^{name}\(\) {{.*?^}}$", SCRIPT.read_text(), re.MULTILINE | re.DOTALL)
    assert found, f"build-bundle.sh defines no {name}()"
    return found.group(0)


class ServiceBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.scratch.name)
        self.stubs = root / "stubs"
        self.stubs.mkdir()
        for name, body in (("otool", OTOOL), ("nm", NM), ("xcrun", XCRUN)):
            tool = self.stubs / name
            tool.write_text(body)
            tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
        self.bundle = root / "XiaolaiDict.app"
        for service in (SERVICE, MODEL_SERVICE):
            binary = self.bundle / f"Contents/XPCServices/{service}.xpc/Contents/MacOS/{service}"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"")

    def tearDown(self):
        self.scratch.cleanup()

    def verify(self, **stub: str) -> subprocess.CompletedProcess:
        script = "\n".join([
            "set -euo pipefail",
            f"readonly SERVICE={SERVICE} MODEL_SERVICE={MODEL_SERVICE}",
            "readonly XPC_PATH=Contents/XPCServices/$SERVICE.xpc",
            "readonly MODEL_XPC_PATH=Contents/XPCServices/$MODEL_SERVICE.xpc",
            function("verify_service_boundaries"),
            'verify_service_boundaries "$1"',
        ])
        env = {"PATH": f"{self.stubs}:{PATH}", **{f"STUB_{key.upper()}": value for key, value in stub.items()}}
        return subprocess.run(["bash", "-c", script, "verify", str(self.bundle)], text=True,
                              capture_output=True, env=env, check=False, timeout=60)

    def test_a_clean_bundle_passes(self):
        done = self.verify()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_a_forbidden_framework_is_refused(self):
        done = self.verify(otool="sqlite")
        self.assertNotEqual(done.returncode, 0, done.stdout)
        self.assertIn("links what it must not", done.stdout)
        self.assertIn("libsqlite3", done.stdout)

    def test_a_forbidden_symbol_is_seen_once_demangled(self):
        done = self.verify(nm="ledger")
        self.assertNotEqual(done.returncode, 0, done.stdout)
        self.assertIn("carries symbols it must not", done.stdout)
        self.assertIn("Ledger", done.stdout)

    def test_otool_failing_fails_the_check(self):
        done = self.verify(otool="fail")
        self.assertNotEqual(done.returncode, 0, done.stdout)
        self.assertIn("otool -L could not read", done.stdout)

    def test_otool_reading_no_object_fails_the_check(self):
        """The real `otool -L` on a file that is not an object: a message on stdout, and exit 0."""
        done = self.verify(otool="notobject")
        self.assertNotEqual(done.returncode, 0, done.stdout)
        self.assertIn("the link check read nothing", done.stdout)

    def test_the_demangler_failing_fails_the_check(self):
        done = self.verify(nm="ledger", demangle="fail")
        self.assertNotEqual(done.returncode, 0, done.stdout)
        self.assertIn("swift-demangle could not read", done.stdout)

    def test_a_demangler_that_demangles_nothing_fails_the_check(self):
        """Mangled names spell a module differently, so a scan of them is blind to it — the forbidden
        `Ledger` here is invisible until demangled, and the check must refuse rather than pass it."""
        done = self.verify(nm="ledger", demangle="passthrough")
        self.assertNotEqual(done.returncode, 0, done.stdout)
        self.assertIn("demangled no Swift name", done.stdout)


if __name__ == "__main__":
    unittest.main()
