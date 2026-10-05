"""`Tools/portability.sh`, the gate that holds ReviewKit to its boundary with the toolchain as the
authority — typechecked alone for every platform, its imports as the compiler lists them, and no
directive as the parser reads it — and its controls.

A check that cannot fail is not a check (ADR-0023). Each case copies `Sources/ReviewKit` into a scratch
directory, plants the one thing the gate exists to refuse, and expects a non-zero exit that names it.
**Never planted into `Sources`**: a parallel test would read the plant, and a crash would leave it for
`swift build` to compile. The scratch directory is also the subprocess's `TMPDIR`, so the module cache
and anything `xcodebuild` writes while looking for a missing SDK go where this test removes them.

That the clean sources pass on all four platforms is `make portability` itself, which every target that
runs `swift test` runs first (ADR-0047).
"""
from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "Tools" / "portability.sh"
REVIEW_KIT = REPO / "Sources" / "ReviewKit"


class PortabilityGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-portability-test-"))
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        self.copy = self.scratch / "ReviewKit"
        shutil.copytree(REVIEW_KIT, self.copy)
        self.assertTrue(list(self.copy.glob("*.swift")), "nothing to copy: the gate's subject has moved")

    def gate(self, directory: pathlib.Path, *flags: str, platforms: str | None = None,
             imports: str = "Foundation", formatter: str | None = None):
        env = dict(os.environ, TMPDIR=str(self.scratch))
        env.pop("PORTABILITY_PLATFORMS", None)
        env.pop("PORTABILITY_SWIFT_FORMAT", None)
        if platforms is not None:
            env["PORTABILITY_PLATFORMS"] = platforms
        if formatter is not None:
            env["PORTABILITY_SWIFT_FORMAT"] = formatter
        return subprocess.run([str(SCRIPT), "--imports", imports, str(directory), *flags],
                              capture_output=True, text=True, env=env, timeout=600)

    def plant(self, source: str) -> None:
        (self.copy / "Planted.swift").write_text(source)

    def test_an_appkit_import_fails_where_appkit_does_not_exist(self) -> None:
        self.plant("import AppKit\n")
        result = self.gate(self.copy, "-DSWIFT_PACKAGE")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("no such module 'AppKit'", result.stderr)
        self.assertIn("does not typecheck for ios", result.stderr)

    def test_a_ledger_reference_fails_because_no_sibling_module_is_reachable(self) -> None:
        self.plant("func probe(_ ledger: Ledger) {}\n")
        result = self.gate(self.copy, "-DSWIFT_PACKAGE")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("cannot find type 'Ledger' in scope", result.stderr)

    def test_an_import_of_the_core_fails_too(self) -> None:
        self.plant("import XiaolaiDictCore\n")
        result = self.gate(self.copy, "-DSWIFT_PACKAGE")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("no such module 'XiaolaiDictCore'", result.stderr)

    def test_the_callers_flags_reach_the_compiler(self) -> None:
        """`make portability` passes `-DSWIFT_PACKAGE`; a script that dropped the caller's flags would
        check a build nobody ships. A define has nothing left to change in ReviewKit — every directive
        is refused before anything compiles — so a flag the compiler rejects is what shows they arrive."""
        refused = self.gate(self.copy, "-DSWIFT_PACKAGE", "-no-such-flag", platforms="macosx:macos")
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("no-such-flag", refused.stderr)
        clean = self.gate(self.copy, "-DSWIFT_PACKAGE", platforms="macosx:macos")
        self.assertEqual(clean.returncode, 0, clean.stderr)

    def test_a_directive_the_define_would_select_is_refused_before_it_compiles(self) -> None:
        """The case the define once had to reach: code only a real build compiles. Refused by the parser
        whether or not the define is given, so the gate's conditions never have to match the build's."""
        self.plant("#if SWIFT_PACKAGE\nfunc probe(_ ledger: Ledger) {}\n#endif\n")
        for flags in (("-DSWIFT_PACKAGE",), ()):
            result = self.gate(self.copy, *flags, platforms="macosx:macos")
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("conditional compilation (#if #endif)", result.stderr)

    def test_the_import_list_must_be_exactly_the_one_named(self) -> None:
        """A module the compiler does not report is refused too: a list that lost one cannot be trusted
        to have found the rest — and an empty list would otherwise pass every allowance."""
        result = self.gate(self.copy, "-DSWIFT_PACKAGE", imports="Foundation,Dispatch", platforms="macosx:macos")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("reports no import of Dispatch", result.stderr)

    def test_a_directive_reader_that_sees_nothing_refuses(self) -> None:
        """The parser is asked about a control file first. A reader that finds nothing — a toolchain whose
        debug output changed shape — would pass every file; it refuses on its own control instead."""
        result = self.gate(self.copy, "-DSWIFT_PACKAGE", formatter="/usr/bin/true", platforms="macosx:macos")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("found no directive in its own control", result.stderr)

    def test_a_directive_in_a_string_or_a_comment_is_not_one(self) -> None:
        """Text is not code: the parser reads a directive's spelling inside a string or a comment as
        what it is, so a clean file that only mentions one passes."""
        self.plant('import Foundation\n// #if DEBUG\nlet mention = "#if X; #endif"\n')
        result = self.gate(self.copy, "-DSWIFT_PACKAGE", platforms="macosx:macos")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_imports_must_be_named(self) -> None:
        result = subprocess.run([str(SCRIPT), str(self.copy), "-DSWIFT_PACKAGE"],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)

    # **Three spellings that parse, typecheck everywhere, and got past the textual scans** (WI-8). The
    # compiler is the authority on what a file imports and on whether it holds a directive, so the
    # gate asks it — and each of these must be refused by name.

    def test_a_backticked_import_is_read_as_the_module_it_names(self) -> None:
        self.plant("import `SQLite3`\n")
        result = self.gate(self.copy, "-DSWIFT_PACKAGE")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("imports SQLite3", result.stderr)

    def test_an_import_between_two_regex_literals_is_seen(self) -> None:
        self.plant('func before() -> Bool { "x".contains(/"/) }\n'
                   "import Dispatch\n"
                   'func after() -> Bool { "x".contains(/"/) }\n')
        result = self.gate(self.copy, "-DSWIFT_PACKAGE")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("imports Dispatch", result.stderr)

    def test_a_directive_after_a_semicolon_is_conditional_compilation(self) -> None:
        self.plant("import Foundation; #if canImport(AppKit)\nlet planted = 1\n#endif\n")
        result = self.gate(self.copy, "-DSWIFT_PACKAGE")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Planted.swift", result.stderr)
        self.assertIn("conditional compilation", result.stderr)

    def test_a_directory_with_no_swift_refuses(self) -> None:
        empty = self.scratch / "Empty"
        empty.mkdir()
        result = self.gate(empty, "-DSWIFT_PACKAGE")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no Swift files", result.stderr)

    def test_a_directory_the_search_cannot_read_refuses(self) -> None:
        """`find` reports a directory it cannot enter and goes on, so the files it did list are a
        partial, non-empty list — and a check over part of the sources passes the rest unread. The
        planted file would be refused if it were read; the gate must refuse because it could not be."""
        hidden = self.copy / "Hidden"
        hidden.mkdir()
        (hidden / "Planted.swift").write_text("import AppKit\n")
        hidden.chmod(0)
        self.addCleanup(hidden.chmod, 0o755)
        result = self.gate(self.copy, "-DSWIFT_PACKAGE", platforms="macosx:macos")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("could not list the Swift files", result.stderr)

    def test_a_missing_sdk_is_named(self) -> None:
        result = self.gate(self.copy, "-DSWIFT_PACKAGE", platforms="nosuchsdk:ios")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the nosuchsdk SDK is not installed", result.stderr)

    def test_the_cache_is_removed_on_every_exit(self) -> None:
        self.plant("import AppKit\n")
        self.gate(self.copy, "-DSWIFT_PACKAGE")
        self.assertEqual(list(self.scratch.glob("xiaolaidict-portability.*")), [],
                         "a failing run left its module cache behind")

    def test_a_stream_holding_the_formatted_source_too_is_refused(self) -> None:
        """Formatted to standard output, the source shares the token stream and lands wherever the dump is
        flushed — measured mid-token at byte 24,576 — so a directive's line could be split and read as
        nothing. The reader formats a copy in place; a formatter that writes the source to the stream
        anyway is refused by the sentinel it then holds twice."""
        result = self.gate(self.copy, "-DSWIFT_PACKAGE", formatter=str(leaky_formatter(self.scratch)),
                           platforms="macosx:macos")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("holds its sentinel 2 times, not once", result.stderr)


class ImportListTests(unittest.TestCase):
    """`--list-imports`, the compiler's own list of what one target imports, which
    `ModuleBoundaryTests.theCompilerHoldsEveryTargetToItsBoundary` judges for every target (ADR-0047,
    addendum 2026-10-05). The names planted below need not exist: the compiler lists an import without
    loading the module, which is also why no sibling has to be built first."""

    def setUp(self) -> None:
        self.scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-import-list-test-"))
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        self.copy = self.scratch / "ReviewKit"
        shutil.copytree(REVIEW_KIT, self.copy)

    def listed(self, directory: pathlib.Path, *extra: str):
        env = dict(os.environ, TMPDIR=str(self.scratch))
        return subprocess.run([str(SCRIPT), "--list-imports", str(directory), *extra],
                              capture_output=True, text=True, env=env, timeout=300)

    def modules(self, *extra: str) -> list[str]:
        result = self.listed(self.copy, *extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def plant(self, source: str) -> None:
        (self.copy / "Planted.swift").write_text(source)

    def test_the_list_is_the_compilers_sorted_and_once_each(self) -> None:
        self.plant("import Foundation\nimport Dispatch\n")
        self.assertEqual(self.modules(), ["Dispatch", "Foundation"])

    def test_an_import_between_two_regex_literals_is_listed(self) -> None:
        self.plant('func before() -> Bool { "x".contains(/"/) }\n'
                   "import Dispatch\n"
                   'func after() -> Bool { "x".contains(/"/) }\n')
        self.assertIn("Dispatch", self.modules())

    def test_a_backticked_import_and_one_after_a_semicolon_are_listed(self) -> None:
        self.plant("import `SQLite3`\nimport Foundation; #if canImport(Dispatch)\nimport Dispatch\n#endif\n")
        self.assertEqual(self.modules(), ["Dispatch", "Foundation", "SQLite3"])

    def test_every_define_a_build_passes_is_asked_both_ways(self) -> None:
        """An import in a clause only some builds compile is listed if any build compiles it. The
        defines are read off where builds start — the Makefile, the scripts in Tools and the manifest —
        so a new `-Xswiftc -D…` there is a define this list must reach, and fails here until it does.
        `DEBUG` is SwiftPM's own, set for `swift test` and not for the bundle's `-c release`. Every
        SwiftPM build sets `SWIFT_PACKAGE`, so its negation is the one clause no build compiles."""
        defines = real_build_defines()
        self.assertIn("XIAOLAIDICT_CAPTURE_INSTRUMENTS", defines, "the reader of the build scripts found nothing")
        defines.add("DEBUG")
        source, expected = "", []
        for name in sorted(defines):
            source += f"#if {name}\nimport On_{name}\n#endif\n"
            expected.append(f"On_{name}")
            source += f"#if !{name}\nimport Off_{name}\n#endif\n"
            if name != "SWIFT_PACKAGE":
                expected.append(f"Off_{name}")
        self.plant(source)
        self.assertEqual(self.modules(), sorted(expected + ["Foundation"]))

    def test_a_build_hands_the_compiler_nothing_but_defines(self) -> None:
        """The list asks the configurations a real build compiles under, which is the whole of what a
        build compiles under only while a build passes the compiler nothing else that binds: an
        `-import-module` through `unsafeFlags` binds a module with no import line at all (ADR-0047, B7).
        So every `-X…` argument a build passes is a define — but for `Tools/strings.sh`'s extraction
        build, which ships nothing — and the manifest has no `unsafeFlags`."""
        manifest = "\n".join(line.split("//", 1)[0] for line in (REPO / "Package.swift").read_text().splitlines())
        self.assertNotIn("unsafeFlags", manifest)
        passed: dict[str, str] = {}
        for path in [REPO / "Makefile", *sorted((REPO / "Tools").glob("*.sh"))]:
            for line in path.read_text().splitlines():
                if line.lstrip().startswith("#"):
                    continue
                for argument in re.findall(r'-X(?:swiftc|frontend|cc|linker)\s+("[^"]*"|\S+)', line):
                    passed.setdefault(argument, path.name)
        # The reader finds what is there: the bundle's define and the extraction's flags.
        self.assertEqual(passed.get("-DXIAOLAIDICT_CAPTURE_INSTRUMENTS"), "build-bundle.sh")
        self.assertEqual(passed.get("-emit-localized-strings"), "strings.sh")
        extraction = {"-emit-localized-strings", "-emit-localized-strings-path", '"$EXTRACTED"'}
        unexpected = {argument: name for argument, name in passed.items()
                      if not argument.startswith("-D") and not (name == "strings.sh" and argument in extraction)}
        self.assertEqual(unexpected, {}, "a build passes the compiler a flag the import list does not ask under")

    def test_a_siblings_can_import_is_asked_both_ways(self) -> None:
        """True in an incremental build, where the sibling's module is already in `.build`, and false in
        a clean one — so each module named by `--siblings` is made importable for a second pass."""
        self.plant("#if canImport(XiaolaiDictCore)\nimport WhenImportable\n#endif\n"
                   "#if !canImport(XiaolaiDictCore)\nimport WhenNot\n#endif\n")
        self.assertEqual(self.modules("--siblings", "XiaolaiDictBase,XiaolaiDictCore"),
                         ["Foundation", "WhenImportable", "WhenNot"])
        self.assertEqual(self.modules(), ["Foundation", "WhenNot"])

    def test_an_executable_with_a_main_swift_is_read_as_one(self) -> None:
        """SwiftPM parses a target with a `main.swift` as top-level code; parsed as a library, its first
        statement is an error and the list is refused."""
        result = self.listed(REPO / "Sources" / "XiaolaiDictIndex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["AppleDictionaryFormat", "DictionaryIndex", "Foundation"])

    def test_a_file_the_compiler_cannot_read_refuses(self) -> None:
        self.plant("import\n")
        result = self.listed(self.copy)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "", "a refused list printed modules anyway")
        self.assertIn("the compiler could not list what", result.stderr)

    def test_a_directory_with_no_swift_refuses(self) -> None:
        empty = self.scratch / "Empty"
        empty.mkdir()
        result = self.listed(empty)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no Swift files", result.stderr)

    def test_anything_but_a_directory_and_its_siblings_is_usage(self) -> None:
        """The configurations are the script's, so a caller's flag has nowhere to go and is refused."""
        directory = str(self.copy)
        for arguments in ([], [directory, "--siblings"], [directory, "--other", "X"],
                          [directory, "--siblings", "X", "-DDEBUG"], [directory, "-DDEBUG"]):
            result = subprocess.run([str(SCRIPT), "--list-imports", *arguments],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 2, f"{arguments}: {result.stderr}")
            self.assertIn("usage:", result.stderr)

    def test_a_sibling_is_a_module_name_and_nothing_more(self) -> None:
        """Each one is written into a module map, where a brace would be syntax."""
        result = self.listed(self.copy, "--siblings", "XiaolaiDictCore,Evil } module Other {")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("which is not a module name", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_the_cache_is_removed_on_every_exit(self) -> None:
        self.plant("import\n")
        self.listed(self.copy, "--siblings", "XiaolaiDictCore")
        self.listed(self.copy)
        self.assertEqual(list(self.scratch.glob("xiaolaidict-portability.*")), [],
                         "a run left its module cache behind")


class ConditionListTests(unittest.TestCase):
    """`--list-conditions`, every `#if` and `#elseif` condition as the Swift parser reads it, which
    `ModuleBoundaryTests.everyConditionIsOneTheBuildConfigurationsDecide` judges for every target (the final
    closing pass, finding 3): a condition is judged as text, never evaluated, so the verdict cannot depend on
    what a build has happened to make importable."""

    def setUp(self) -> None:
        self.scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-condition-list-test-"))
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        self.copy = self.scratch / "DictionaryIndex"
        shutil.copytree(REPO / "Sources" / "DictionaryIndex", self.copy)

    def listed(self, directory: pathlib.Path, *extra: str, formatter: str | None = None):
        env = dict(os.environ, TMPDIR=str(self.scratch))
        env.pop("PORTABILITY_SWIFT_FORMAT", None)
        if formatter is not None:
            env["PORTABILITY_SWIFT_FORMAT"] = formatter
        return subprocess.run([str(SCRIPT), "--list-conditions", str(directory), *extra],
                              capture_output=True, text=True, env=env, timeout=300)

    def conditions(self) -> list[str]:
        result = self.listed(self.copy)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def plant(self, source: str, name: str = "Planted.swift") -> None:
        (self.copy / name).write_text(source)

    def test_the_reviewers_two_conditions_are_listed_through_regex_literals(self) -> None:
        """Each guarded an `import AppKit` the import list never asked and the text scan read as a string."""
        hidden = 'func before() -> Bool { "x".contains(/"/) }\nimport AppKit\nfunc after() -> Bool { "x".contains(/"/) }\n'
        self.plant(f"#if canImport(MLX)\n{hidden}#endif\n"
                   f"let opening = /\"/; #if canImport(AppleDictionaryFormat) && !canImport(XiaolaiDictCore)\n{hidden}"
                   "#elseif DEBUG || os(macOS)\nlet x = 1\n#endif\n")
        self.assertEqual(self.conditions(), [
            "Planted.swift\t#elseif\tDEBUG || os(macOS)",
            "Planted.swift\t#if\tcanImport(AppleDictionaryFormat) && !canImport(XiaolaiDictCore)",
            "Planted.swift\t#if\tcanImport(MLX)",
        ])

    def test_a_mention_in_a_string_or_a_comment_is_no_condition(self) -> None:
        self.plant('// #if canImport(MLX)\nlet s = "#if canImport(MLX)"\n/* #elseif DEBUG */\n')
        self.assertEqual(self.conditions(), [])

    def test_a_condition_across_lines_is_read_whole(self) -> None:
        """Swift lets a condition run on only inside parentheses — a line break after a bare `||` is a
        parse error — and a comment inside one is no token of it."""
        self.plant("#if (canImport(MLX) ||\n    /* why */ canImport(AppKit)) // why\nlet x = 1\n#endif\n")
        self.assertEqual(self.conditions(), ["Planted.swift\t#if\t(canImport(MLX) || canImport(AppKit))"])

    def test_a_condition_the_parser_does_not_bound_is_listed_empty(self) -> None:
        """A postfix `#if` carries none of the markers that bound a condition, so its condition cannot be
        told from the body; it is listed empty, which the verdict refuses."""
        self.plant("let x = [1]\n    #if DEBUG\n    .map { $0 }\n    #endif\n")
        self.assertEqual(self.conditions(), ["Planted.swift\t#if\t"])

    def test_a_stream_holding_the_formatted_source_too_is_refused(self) -> None:
        self.plant("#if DEBUG\nlet x = 1\n#endif\n")
        result = self.listed(self.copy, formatter=str(leaky_formatter(self.scratch)))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "", "a refused list printed conditions anyway")
        self.assertIn("holds its sentinel 2 times, not once", result.stderr)

    def test_a_reader_that_sees_nothing_refuses(self) -> None:
        result = self.listed(self.copy, formatter="/usr/bin/true")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("found no directive in its own control", result.stderr)

    def test_a_file_the_parser_cannot_read_refuses(self) -> None:
        self.plant("#if DEBUG\nlet = \n#endif\n")
        result = self.listed(self.copy)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "")
        self.assertIn("the Swift parser could not read", result.stderr)

    def test_a_directory_with_no_swift_refuses(self) -> None:
        empty = self.scratch / "Empty"
        empty.mkdir()
        result = self.listed(empty)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no Swift files", result.stderr)

    def test_anything_but_a_directory_is_usage(self) -> None:
        for extra in (["--siblings", "X"], ["-DDEBUG"]):
            result = self.listed(self.copy, *extra)
            self.assertEqual(result.returncode, 2, f"{extra}: {result.stderr}")
            self.assertIn("usage:", result.stderr)

    def test_the_cache_is_removed_on_every_exit(self) -> None:
        self.plant("#if DEBUG\nlet = \n#endif\n")
        self.listed(self.copy)
        self.assertEqual(list(self.scratch.glob("xiaolaidict-portability.*")), [],
                         "a run left its scratch behind")


def leaky_formatter(scratch: pathlib.Path) -> pathlib.Path:
    """The real swift-format with `--in-place` dropped: the formatted source goes to the token stream's
    own standard output, the shape the reader must refuse."""
    real = subprocess.run(["xcrun", "--find", "swift-format"], capture_output=True, text=True,
                          check=True).stdout.strip()
    script = scratch / "leaky-swift-format"
    script.write_text("#!/bin/bash\nargs=()\nfor a in \"$@\"; do [ \"$a\" = --in-place ] || args+=(\"$a\"); done\n"
                      f"exec '{real}' \"${{args[@]}}\"\n")
    script.chmod(0o755)
    return script


def real_build_defines() -> set[str]:
    """Every `-D<NAME>` the Makefile and the scripts in Tools pass, and every `.define("…")` in the
    manifest. Comments are read too: a define named in one and passed nowhere is a false refusal, which
    is loud, and never a define missed."""
    found: set[str] = set()
    for path in [REPO / "Makefile", REPO / "Package.swift", *sorted((REPO / "Tools").glob("*.sh"))]:
        text = path.read_text()
        found.update(re.findall(r"(?<![\w-])-D([A-Za-z_]\w*)", text))
        found.update(re.findall(r'\.define\(\s*"([A-Za-z_]\w*)"', text))
    return found


if __name__ == "__main__":
    unittest.main()
