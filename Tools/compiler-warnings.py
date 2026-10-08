#!/usr/bin/env python3
"""Refuse a build whose compiler wrote a warning down, whatever the compiler exited with.

    Tools/compiler-warnings.py <intermediates> [--targets A,B,...]

`<intermediates>` is one configuration of this package's build — `make` passes
`.build/out/Intermediates.noindex/XiaolaiDict.build/Debug`, which `swift test` has just built. With no
`--targets`, the targets are `swift package dump-package`'s, so a target added later is read unasked.

**Why it exists** (ADR-0052). A warning is an error in this package, and `-warnings-as-errors` does not
make every warning one: a stored property whose type is inferred from a module its file does not import
is reported as a warning, carries no diagnostic group, and exits 0 — measured on Swift 6.4, in this tree
and in a two-module probe, while an unused variable in the same build fails it.

**Why files, not a log.** Each compile of a source writes its diagnostics to `<source>.dia` beside its
object, and a build that does not recompile the source leaves that file alone. A build log holds only
what that build compiled: a no-op rebuild printed no warning while the warning stood (measured). So this
reads the files, through the toolchain's own reader (`libclang`'s `clang_loadDiagnostics`) rather than a
parser of its own, and fails loud on anything it cannot read — a missing reader, an unreadable file, a
target with no module directory, a source with no diagnostics file. Nothing found is never a pass.

What it reads, per module: the diagnostics of every source its `.SwiftFileList` names, and of the module
job (`<module>-primary-emit-module.dia`), where a declaration's diagnostics are written as well. A `.dia`
whose source the module no longer compiles — a file moved or removed — is stale, counted and skipped.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
WARNING = 2  # CXDiagnostic_Warning; Error is 3 and Fatal 4. Notes (1) belong to the diagnostic they follow.


class CXString(ctypes.Structure):
    _fields_ = [("data", ctypes.c_void_p), ("private_flags", ctypes.c_uint)]


class Refusal(Exception):
    """Something this gate could not read, which is never a pass."""


def libclang() -> ctypes.CDLL:
    """The active toolchain's libclang, beside its clang, unless `XIAOLAIDICT_LIBCLANG` names another."""
    path = os.environ.get("XIAOLAIDICT_LIBCLANG")
    if path is None:
        found = subprocess.run(["xcrun", "--find", "clang"], capture_output=True, text=True)
        if found.returncode != 0:
            raise Refusal(f"xcrun cannot find clang, so not libclang either: {found.stderr.strip()}")
        path = str(pathlib.Path(found.stdout.strip()).parent.parent / "lib" / "libclang.dylib")
    try:
        library = ctypes.CDLL(path)
    except OSError as error:
        raise Refusal(f"cannot load libclang, the toolchain's reader of diagnostics files: {error}") from None
    library.clang_loadDiagnostics.restype = ctypes.c_void_p
    library.clang_loadDiagnostics.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int),
                                              ctypes.POINTER(CXString)]
    library.clang_getNumDiagnosticsInSet.restype = ctypes.c_uint
    library.clang_getNumDiagnosticsInSet.argtypes = [ctypes.c_void_p]
    library.clang_getDiagnosticInSet.restype = ctypes.c_void_p
    library.clang_getDiagnosticInSet.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    library.clang_getDiagnosticSeverity.restype = ctypes.c_int
    library.clang_getDiagnosticSeverity.argtypes = [ctypes.c_void_p]
    library.clang_formatDiagnostic.restype = CXString
    library.clang_formatDiagnostic.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    library.clang_getCString.restype = ctypes.c_char_p
    library.clang_getCString.argtypes = [CXString]
    library.clang_disposeString.argtypes = [CXString]
    library.clang_disposeDiagnostic.argtypes = [ctypes.c_void_p]
    library.clang_disposeDiagnosticSet.argtypes = [ctypes.c_void_p]
    return library


def text(library: ctypes.CDLL, value: CXString) -> str:
    try:
        return (library.clang_getCString(value) or b"").decode("utf-8", "replace")
    finally:
        library.clang_disposeString(value)


def warnings_in(library: ctypes.CDLL, path: pathlib.Path) -> list[str]:
    """Every diagnostic of warning severity or worse in one file, formatted with its place."""
    error, message = ctypes.c_int(0), CXString()
    diagnostics = library.clang_loadDiagnostics(str(path).encode(), ctypes.byref(error), ctypes.byref(message))
    if not diagnostics:
        raise Refusal(f"{path}: libclang cannot read it (error {error.value}: {text(library, message)})")
    found = []
    try:
        for index in range(library.clang_getNumDiagnosticsInSet(diagnostics)):
            diagnostic = library.clang_getDiagnosticInSet(diagnostics, index)
            try:
                if library.clang_getDiagnosticSeverity(diagnostic) >= WARNING:
                    # Source location and column, as the compiler prints them.
                    found.append(text(library, library.clang_formatDiagnostic(diagnostic, 0x1 | 0x2)))
            finally:
                library.clang_disposeDiagnostic(diagnostic)
    finally:
        library.clang_disposeDiagnosticSet(diagnostics)
    return found


def package_targets() -> list[str]:
    dumped = subprocess.run(["swift", "package", "dump-package", "--package-path", str(REPO)],
                            capture_output=True, text=True)
    if dumped.returncode != 0:
        raise Refusal(f"swift package dump-package failed: {dumped.stderr.strip()}")
    targets = [target["name"] for target in json.loads(dumped.stdout)["targets"]]
    if not targets:
        raise Refusal("swift package dump-package listed no target")
    return targets


def modules(build: pathlib.Path, target: str) -> list[pathlib.Path]:
    """Every module directory compiled for one target: the module itself (`-t` for a library, `-p` for a
    product) and, for an executable, the copy built for testing (`<target>-<hash>-testable`)."""
    own = re.compile(rf"{re.escape(target)}(-[0-9A-F]+-testable)?")
    return sorted(listed.parent for listed in build.glob("*.build/Objects-normal/*/*.SwiftFileList")
                  if own.fullmatch(listed.stem))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("intermediates", type=pathlib.Path)
    parser.add_argument("--targets", help="comma-separated; this package's targets if absent")
    arguments = parser.parse_args()
    build = arguments.intermediates
    try:
        if not build.is_dir():
            raise Refusal(f"{build} is not a directory: nothing was built there, or the layout changed")
        library = libclang()
        targets = arguments.targets.split(",") if arguments.targets else package_targets()
        unbuilt, missing, warnings = [], [], {}
        read = stale = module_count = 0
        for target in targets:
            directories = modules(build, target)
            if not directories:
                unbuilt.append(target)
            for directory in directories:
                module_count += 1
                listed = next(directory.glob("*.SwiftFileList"))
                stems = {pathlib.Path(line.strip()).stem for line in listed.read_text().splitlines() if line.strip()}
                for stem in sorted(stems):
                    if not (directory / f"{stem}.dia").is_file():
                        missing.append(f"{directory.name}/{stem}.swift")
                current = {f"{stem}.dia" for stem in stems} | {f"{listed.stem}-primary-emit-module.dia"}
                for dia in sorted(directory.glob("*.dia")):
                    if dia.name not in current:
                        # A source the module no longer compiles, or the dependency scan's (which fails
                        # the build itself when it finds anything).
                        stale += dia.name != f"{listed.stem}-dependency-scan.dia"
                        continue
                    read += 1
                    for warning in warnings_in(library, dia):
                        warnings.setdefault(warning.replace(f"{REPO}/", ""), None)
        if unbuilt:
            raise Refusal(f"no module directory under {build} for {', '.join(unbuilt)}: not built in this "
                          "configuration, so nothing says what the compiler made of it")
        if missing:
            raise Refusal("the compiler left no diagnostics for " + ", ".join(missing)
                          + " — its file list names them, and a source with nothing written is not a clean one")
    except Refusal as refusal:
        print(f"compiler-warnings: {refusal}", file=sys.stderr)
        return 1
    if warnings:
        count = len(warnings)
        print(f"compiler-warnings: {count} warning{'s' if count != 1 else ''} the compiler wrote down and "
              "did not fail the build on. A warning is an error in this package (ADR-0052):", file=sys.stderr)
        for warning in warnings:
            print(f"  {warning}", file=sys.stderr)
        return 1
    note = f"; {stale} left by a source the module no longer compiles, not read" if stale else ""
    print(f"compiler-warnings: no warning in {read} file{'s' if read != 1 else ''} of {module_count} "
          f"module{'s' if module_count != 1 else ''}{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
