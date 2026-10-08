"""`Tools/compiler-warnings.py` — the gate for the warnings `-warnings-as-errors` does not make errors.

**A warning is an error in this package** (`Package.swift`'s last lines), and the compiler does not keep
that promise for every warning. Measured 2026-10-08 on Swift 6.4: a file whose stored property's type is
inferred from a module the file does not import draws "cannot use enum … in a property declaration member
of a type not marked '@_implementationOnly'; '…' was not imported by this file" as a **warning, exit 0,
with `-warnings-as-errors` on the compile**; an unused variable in the same build fails it. The warning
carries no diagnostic group, so nothing can name it to promote it, and `MemberImportVisibility` does not
turn it into an error — with the feature on, it is not reported at all (ADR-0052).

So the gate reads what the compiler wrote down rather than what it exited with: every compile of a
source writes that source's diagnostics to a `.dia` file beside its object, and a later build that does
not recompile the source leaves the file as it was. That is why it reads files and not a build log — the
log of a build that compiled nothing holds no warning, measured, while the warning stands.

Each case builds its own scratch tree in the layout SwiftPM uses, with diagnostics the toolchain itself
wrote for a few lines of Swift. A check that cannot fail is not a check (ADR-0023).
"""
from __future__ import annotations

import os
import pathlib
import platform
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "Tools" / "compiler-warnings.py"
TRIPLE = f"{platform.machine()}-apple-macos27.0"

CLEAN = "public func answer() -> Int { 42 }\n"
UNUSED = "func probe() { var unused = 1 }\n"
# The shape that reached the tree: a type another file's import makes visible, inferred into a property.
LIBRARY = "public enum Status: Sendable { case on, off }\n"
HOLDER = "import Lib\npublic struct Holder: Sendable {\n    public static let status: Status? = .on\n}\n"
INFERRED = ("public struct Card {\n    private var status = Holder.status\n    public init() {}\n"
            "    public var isOn: Bool { status != nil }\n}\n")


class CompilerWarningsGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True,
                                 check=True).stdout.strip()

    def setUp(self) -> None:
        self.scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-compiler-warnings-test-"))
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        self.sources = self.scratch / "Sources"
        self.sources.mkdir()
        self.build = self.scratch / "Debug"
        self.build.mkdir()

    # MARK: - What the toolchain writes

    def source(self, name: str, text: str) -> pathlib.Path:
        path = self.sources / name
        path.write_text(text)
        return path

    def compile(self, primary: pathlib.Path, *others: pathlib.Path, into: pathlib.Path,
                module: str = "Probe", search: pathlib.Path | None = None,
                warnings_as_errors: bool = False) -> subprocess.CompletedProcess:
        """One frontend job, as SwiftPM runs one per source: `-serialize-diagnostics-path` is the file
        the gate reads."""
        command = ["xcrun", "swiftc", "-frontend", "-typecheck", "-primary-file", str(primary),
                   *map(str, others), "-module-name", module, "-parse-as-library", "-swift-version", "6",
                   "-sdk", self.sdk, "-target", TRIPLE, "-serialize-diagnostics-path", str(into)]
        if search is not None:
            command += ["-I", str(search)]
        if warnings_as_errors:
            command.append("-warnings-as-errors")
        result = subprocess.run(command, capture_output=True, text=True, timeout=120,
                                env=dict(os.environ, TMPDIR=str(self.scratch)))
        self.assertTrue(into.exists(), f"the compiler wrote no diagnostics: {result.stderr}")
        return result

    def module(self, name: str, *sources: pathlib.Path, kind: str = "t",
               stem: str | None = None) -> pathlib.Path:
        """A module's directory as SwiftPM lays it out: `<name>-t.build` for a library, `-p.build` for a
        product, and the list of sources it compiles beside their diagnostics."""
        stem = stem or name
        directory = self.build / f"{stem}-{kind}.build" / "Objects-normal" / platform.machine()
        directory.mkdir(parents=True)
        (directory / f"{stem}.SwiftFileList").write_text("".join(f"{path}\n" for path in sources))
        return directory

    def clean_module(self, name: str = "Clean") -> pathlib.Path:
        source = self.source(f"{name}File.swift", CLEAN)
        directory = self.module(name, source)
        self.compile(source, into=directory / f"{name}File.dia", module=name)
        return directory

    def gate(self, *targets: str, libclang: str | None = None) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env.pop("XIAOLAIDICT_LIBCLANG", None)
        if libclang is not None:
            env["XIAOLAIDICT_LIBCLANG"] = libclang
        arguments = [str(SCRIPT), str(self.build)]
        if targets:
            arguments += ["--targets", ",".join(targets)]
        return subprocess.run(arguments, capture_output=True, text=True, env=env, timeout=120)

    # MARK: - It passes what is clean

    def test_a_build_with_no_warning_passes_and_says_what_it_read(self) -> None:
        self.clean_module()
        result = self.gate("Clean")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no warning in 1 file of 1 module", result.stdout)

    # MARK: - It refuses a warning, wherever the compiler wrote it

    def test_the_warning_warnings_as_errors_lets_through_is_refused(self) -> None:
        library = self.source("Lib.swift", LIBRARY)
        interface = self.scratch / "Modules"
        interface.mkdir()
        made = subprocess.run(["xcrun", "swiftc", "-emit-module", "-parse-as-library", "-module-name", "Lib",
                               "-swift-version", "6", "-target", TRIPLE, "-o", str(interface / "Lib.swiftmodule"),
                               str(library)], capture_output=True, text=True, timeout=120,
                              env=dict(os.environ, TMPDIR=str(self.scratch)))
        self.assertEqual(made.returncode, 0, made.stderr)
        holder, card = self.source("Holder.swift", HOLDER), self.source("Card.swift", INFERRED)
        directory = self.module("Shown", holder, card)
        self.compile(holder, card, into=directory / "Holder.dia", module="Shown", search=interface,
                     warnings_as_errors=True)
        compiled = self.compile(card, holder, into=directory / "Card.dia", module="Shown", search=interface,
                                warnings_as_errors=True)
        # The premise, reproduced: the compile that wrote the warning exited 0 under -warnings-as-errors. If a
        # toolchain ever fails it instead, the build stops first and this gate is merely redundant — say so.
        self.assertEqual(compiled.returncode, 0,
                         "the compiler now fails this build itself; the gate still holds, but ADR-0052's "
                         f"premise has changed: {compiled.stderr}")
        self.assertIn("was not imported by this file", compiled.stderr)
        result = self.gate("Shown")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertRegex(result.stderr, r"Card\.swift:2:\d+: warning: cannot use enum 'Status'")
        self.assertIn("'Lib' was not imported by this file", result.stderr)
        self.assertNotIn("Holder.swift", result.stderr, "a clean file is named as a warning")

    def test_an_ordinary_warning_is_refused_with_its_place(self) -> None:
        self.clean_module()
        source = self.source("Unused.swift", UNUSED)
        directory = self.module("Warned", source)
        self.compile(source, into=directory / "Unused.dia", module="Warned")
        result = self.gate("Clean", "Warned")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertRegex(result.stderr, r"Unused\.swift:1:\d+: warning: initialization of variable 'unused'")
        self.assertIn("1 warning", result.stderr)

    def test_the_module_jobs_diagnostics_are_read_too(self) -> None:
        directory = self.clean_module()
        warned = self.source("Unused.swift", UNUSED)
        self.compile(warned, into=directory / "Clean-primary-emit-module.dia", module="Clean")
        result = self.gate("Clean")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("initialization of variable 'unused'", result.stderr)

    def test_a_warning_written_twice_is_named_once(self) -> None:
        source = self.source("Unused.swift", UNUSED)
        directory = self.module("Warned", source)
        self.compile(source, into=directory / "Unused.dia", module="Warned")
        shutil.copy(directory / "Unused.dia", directory / "Warned-primary-emit-module.dia")
        result = self.gate("Warned")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.stderr.count("initialization of variable 'unused'"), 1, result.stderr)

    def test_the_testable_copy_of_an_executable_is_read(self) -> None:
        source = self.source("Main.swift", CLEAN)
        product = self.module("App", source, kind="p")
        self.compile(source, into=product / "Main.dia", module="App")
        warned = self.source("Unused.swift", UNUSED)
        testable = self.module("App", warned, stem="App-5D5E93E10A397156-testable")
        self.compile(warned, into=testable / "Unused.dia", module="App")
        result = self.gate("App")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Unused.swift", result.stderr)

    # MARK: - It reads only what the build compiles now

    def test_a_file_the_module_no_longer_compiles_is_not_read(self) -> None:
        directory = self.clean_module()
        moved = self.source("Moved.swift", UNUSED)
        self.compile(moved, into=directory / "Moved.dia", module="Clean")
        result = self.gate("Clean")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 left by a source the module no longer compiles", result.stdout)

    def test_a_target_no_longer_declared_is_not_read(self) -> None:
        self.clean_module()
        source = self.source("Unused.swift", UNUSED)
        directory = self.module("Removed", source)
        self.compile(source, into=directory / "Unused.dia", module="Removed")
        result = self.gate("Clean")
        self.assertEqual(result.returncode, 0, result.stderr)

    # MARK: - It refuses to pass on nothing

    def test_a_source_the_compiler_wrote_nothing_for_is_refused(self) -> None:
        directory = self.clean_module()
        unread = self.source("Unread.swift", CLEAN)
        (directory / "Clean.SwiftFileList").write_text(
            (directory / "Clean.SwiftFileList").read_text() + f"{unread}\n")
        result = self.gate("Clean")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Unread.swift", result.stderr)
        self.assertIn("no diagnostics", result.stderr)

    def test_a_target_that_was_not_built_is_refused(self) -> None:
        self.clean_module()
        result = self.gate("Clean", "NeverBuilt")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("NeverBuilt", result.stderr)

    def test_an_empty_build_is_refused(self) -> None:
        result = self.gate("Clean")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Clean", result.stderr)

    def test_a_build_directory_that_is_not_there_is_refused(self) -> None:
        shutil.rmtree(self.build)
        result = self.gate("Clean")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(str(self.build), result.stderr)

    def test_a_diagnostics_file_that_cannot_be_read_is_refused(self) -> None:
        directory = self.clean_module()
        (directory / "CleanFile.dia").write_bytes(b"not a diagnostics file")
        result = self.gate("Clean")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CleanFile.dia", result.stderr)

    def test_without_the_toolchains_reader_it_refuses(self) -> None:
        self.clean_module()
        result = self.gate("Clean", libclang=str(self.scratch / "missing" / "libclang.dylib"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("libclang", result.stderr)

    def test_with_no_targets_named_it_asks_swiftpm_for_this_packages(self) -> None:
        self.clean_module()
        result = self.gate()
        self.assertEqual(result.returncode, 1, result.stdout)
        # Every target of this package is missing from a scratch tree that built only `Clean`.
        for target in ("XiaolaiDictCore", "MacCapture", "XiaolaiDictTests"):
            self.assertIn(target, result.stderr)

    # MARK: - Every build that tests runs it

    def test_every_build_that_tests_runs_it_and_fails_with_it(self) -> None:
        makefile = (REPO / "Makefile").read_text()
        recipe = re.search(r"^test-swift:[^\n]*\n((?:\t[^\n]*\n)+)", makefile, re.MULTILINE)
        self.assertIsNotNone(recipe, "no test-swift rule")
        body = recipe.group(1)
        self.assertIn("Tools/compiler-warnings.py $(DIAGNOSTICS) || status=1", body)
        # The configuration `swift test` builds, in the layout SwiftPM writes it in; the gate refuses a
        # directory that is not there, so a layout that moves fails here rather than passing on nothing.
        directory = re.search(r"^DIAGNOSTICS := (\S+)$", makefile, re.MULTILINE)
        self.assertIsNotNone(directory, "no DIAGNOSTICS")
        self.assertEqual(directory.group(1), ".build/out/Intermediates.noindex/XiaolaiDict.build/Debug")
        # After the tests, so it reads what this build compiled, and before the exit that reports it.
        self.assertLess(body.index("swift test"), body.index("compiler-warnings.py"))
        self.assertLess(body.index("compiler-warnings.py"), body.index("exit $$status"))
        for rule in ("all", "run", "test", "release"):
            prerequisites = re.search(rf"^{rule}:([^\n]*)", makefile, re.MULTILINE)
            self.assertIsNotNone(prerequisites, rule)
            self.assertIn("test-swift", prerequisites.group(1).split(), rule)


if __name__ == "__main__":
    unittest.main()
