"""An E2E stage whose inputs have not changed since a fresh pass is carried forward, marked, instead of run again.

`Tools/e2e-inputs.py` hashes each stage's inputs — the SwiftPM modules it exercises and everything they depend on, read
off the package graph; the `Tools` files it uses; its own region of `Tools/e2e.sh`; and the harness code every stage
shares — into one key. A stage is carried only from an earlier **fresh pass** with an equal key, on the same E2E Mac and
the same macOS build. A false skip is far worse than an extra run, so most of what follows is about the ways a key could
fail to move: an input declared by a pattern that matches nothing, a module claimed by no stage, a file a stage uses
that it never declared, a function one stage defines and another calls.

Run from the repository root:

    Tools/python.sh -m unittest discover -s Tools/tests -p test_e2e_incremental.py
"""
from __future__ import annotations

import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

from ledger_schema import REPO

TOOL = REPO / "Tools" / "e2e-inputs.py"
_spec = importlib.util.spec_from_file_location("e2e_inputs", TOOL)
inputs = importlib.util.module_from_spec(_spec)
# Registered before it runs: a dataclass looks its own module up in `sys.modules` while it is being defined.
sys.modules["e2e_inputs"] = inputs
_spec.loader.exec_module(inputs)

STATUS_SCRIPT = REPO / "Tools" / "e2e-status.sh"
BASH = "/bin/bash"

# A package of four targets: App depends on Lib, Lib on Base; Other stands alone; AppTests is a test target.
DUMP = {
    "targets": [
        {"name": "Base", "type": "regular", "path": None, "dependencies": []},
        {"name": "Lib", "type": "regular", "path": None, "dependencies": [{"byName": ["Base", None]}]},
        {"name": "App", "type": "executable", "path": None, "dependencies": [{"byName": ["Lib", None]},
                                                                              {"product": ["MLX", "mlx", None, None]}]},
        {"name": "Other", "type": "regular", "path": None, "dependencies": []},
        {"name": "Support", "type": "regular", "path": "Tests/Support", "dependencies": []},
        {"name": "AppTests", "type": "test", "path": None, "dependencies": [{"target": ["App", None]}]},
    ]
}

SCRIPT = textwrap.dedent("""\
    #!/bin/bash
    shared_helper() { echo shared; }
    KNOWN_STAGES=(alpha beta gamma)
    if want alpha; then
    alpha_only() { "$helpers/poke" a; }
    alpha_only
    fi

    if want beta; then
    echo beta
    fi

    if want gamma; then
    echo gamma
    fi
    finished=true
    echo tail
    """)

ROWS = textwrap.dedent("""\
    # stage\tkind\tvalue\treason
    *\tpath\tTools/shared/*\tthe harness every stage shares
    alpha\tmodule\tApp\tlaunches the app
    alpha\tpath\tTools/e2e/poke.swift\tits helper
    beta\tmodule\tOther\tlooks at Other
    gamma\tpath\tTools/e2e/gamma.html\tits page
    gamma\town\tApp\truns the app, asserting on none of what it links
    -\tunexercised\tSupport\ttest support, never in the bundle
    """)


class Scratch:
    """A repository on disk with the four targets, a script, helpers and an inputs file."""

    def __init__(self, test: unittest.TestCase):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-e2e-inputs-"))
        test.addCleanup(shutil.rmtree, self.root, True)
        for relative, text in {
            "Sources/Base/base.swift": "let base = 1\n",
            "Sources/Lib/lib.swift": "let lib = 1\n",
            "Sources/Lib/nested/deep.swift": "let deep = 1\n",
            "Sources/App/main.swift": "print(1)\n",
            "Sources/Other/other.swift": "let other = 1\n",
            "Tests/Support/support.swift": "let support = 1\n",
            "Tests/AppTests/test.swift": "let test = 1\n",
            "Tools/shared/common.sh": "echo common\n",
            "Tools/e2e/poke.swift": "print(0)\n",
            "Tools/e2e/gamma.html": "<p>gamma</p>\n",
            "Tools/e2e/unrelated.swift": "print(2)\n",
            "README.md": "readme\n",
        }.items():
            self.write(relative, text)
        self.script = SCRIPT
        self.rows = ROWS
        self.targets = inputs.targets_from_dump(DUMP)

    def write(self, relative: str, text: str):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def append(self, relative: str, text: str = "// touched\n"):
        path = self.root / relative
        path.write_text(path.read_text() + text)

    def keys(self) -> dict[str, str | None]:
        found = inputs.stage_keys(self.root, self.script, inputs.parse_inputs(self.rows), self.targets)
        return {stage: key.value for stage, key in found.items()}


class TheKeyFollowsItsInputs(unittest.TestCase):

    def setUp(self):
        self.repo = Scratch(self)
        self.before = self.repo.keys()

    def changed(self) -> set[str]:
        after = self.repo.keys()
        return {stage for stage in after if after[stage] != self.before[stage]}

    def test_every_declared_stage_has_a_key(self):
        self.assertEqual(sorted(self.before), ["alpha", "beta", "gamma"])
        for stage, key in self.before.items():
            self.assertRegex(key or "", r"^[0-9a-f]{64}$", stage)

    def test_a_file_of_a_declared_module_moves_only_the_stages_that_declare_it(self):
        self.repo.append("Sources/App/main.swift")
        self.assertEqual(self.changed(), {"alpha", "gamma"})

    def test_a_module_claimed_as_own_does_not_bring_its_dependencies(self):
        self.repo.append("Sources/Lib/lib.swift")   # App -> Lib, but gamma claims App's own files only
        self.assertEqual(self.changed(), {"alpha"})

    def test_a_module_the_declared_one_depends_on_moves_it_too(self):
        self.repo.append("Sources/Base/base.swift")   # App -> Lib -> Base
        self.assertEqual(self.changed(), {"alpha"})

    def test_a_nested_file_and_a_new_file_and_a_removed_file_all_move_it(self):
        self.repo.append("Sources/Lib/nested/deep.swift")
        self.assertEqual(self.changed(), {"alpha"})
        self.before = self.repo.keys()
        self.repo.write("Sources/Lib/added.swift", "let added = 1\n")
        self.assertEqual(self.changed(), {"alpha"})
        self.before = self.repo.keys()
        (self.repo.root / "Sources/Lib/added.swift").unlink()
        self.assertEqual(self.changed(), {"alpha"})

    def test_an_unrelated_file_moves_nothing(self):
        for relative in ("README.md", "Tools/e2e/unrelated.swift", "Tests/AppTests/test.swift", "Tests/Support/support.swift"):
            self.repo.append(relative)
        self.assertEqual(self.changed(), set())

    def test_a_declared_path_moves_only_its_stage(self):
        self.repo.append("Tools/e2e/gamma.html")
        self.assertEqual(self.changed(), {"gamma"})

    def test_a_shared_input_moves_every_stage(self):
        self.repo.append("Tools/shared/common.sh")
        self.assertEqual(self.changed(), {"alpha", "beta", "gamma"})

    def test_a_stages_own_region_moves_only_that_stage(self):
        self.repo.script = self.repo.script.replace("echo beta", "echo beta  # a comment")
        self.assertEqual(self.changed(), {"beta"})

    def test_the_harness_outside_every_region_moves_every_stage(self):
        for edit in (("echo shared;", "echo shared; # a comment"), ("echo tail", "echo tail # a comment")):
            with self.subTest(edit=edit[1]):
                self.repo.script = SCRIPT.replace(*edit)
                self.assertEqual(self.changed(), {"alpha", "beta", "gamma"})

    def test_a_stages_own_declaration_moves_only_that_stage(self):
        self.repo.rows = self.repo.rows.replace("beta\tmodule\tOther\tlooks at Other",
                                                "beta\tmodule\tOther\tlooks at Other\nbeta\tmodule\tBase\tand Base")
        self.assertEqual(self.changed(), {"beta"})

    def test_a_shared_declaration_moves_every_stage(self):
        self.repo.rows += "*\tpath\tREADME.md\tread by every stage\n"
        self.assertEqual(self.changed(), {"alpha", "beta", "gamma"})

    def test_a_pattern_that_matches_nothing_leaves_its_stage_without_a_key(self):
        self.repo.rows += "gamma\tpath\tTools/e2e/gone.html\ta page that is not there\n"
        found = inputs.stage_keys(self.repo.root, self.repo.script, inputs.parse_inputs(self.repo.rows), self.repo.targets)
        self.assertIsNone(found["gamma"].value)
        self.assertIn("Tools/e2e/gone.html", found["gamma"].why)
        self.assertIsNotNone(found["alpha"].value)

    def test_a_stage_without_an_entry_has_no_key(self):
        self.repo.script = SCRIPT.replace("KNOWN_STAGES=(alpha beta gamma)", "KNOWN_STAGES=(alpha beta gamma delta)") \
            .replace("finished=true", "if want delta; then\necho delta\nfi\nfinished=true")
        found = inputs.stage_keys(self.repo.root, self.repo.script, inputs.parse_inputs(self.repo.rows), self.repo.targets)
        self.assertIsNone(found["delta"].value)
        self.assertIn("no entry", found["delta"].why)

    def test_a_module_the_package_does_not_have_is_refused(self):
        self.repo.rows += "beta\tmodule\tNoSuchModule\ta typo\n"
        found = inputs.stage_keys(self.repo.root, self.repo.script, inputs.parse_inputs(self.repo.rows), self.repo.targets)
        self.assertIsNone(found["beta"].value)
        self.assertIn("NoSuchModule", found["beta"].why)

    def test_a_malformed_row_is_refused(self):
        for row in ("alpha\tmodule\n", "alpha\tsomething\tApp\twhy\n", "alpha\tunexercised\tApp\twhy\n",
                    "-\tunexercised\tOther\t\n", "alpha\tpath\t/etc/passwd\twhy\n", "alpha\tpath\t../outside\twhy\n"):
            with self.subTest(row=row):
                with self.assertRaises(ValueError):
                    inputs.parse_inputs(ROWS + row)


class TheRegionsPartitionTheScript(unittest.TestCase):

    def test_each_region_runs_from_its_want_to_the_next(self):
        regions, shared = inputs.split_script(SCRIPT, ("alpha", "beta", "gamma"))
        self.assertIn("alpha_only", regions["alpha"])
        self.assertNotIn("echo beta", regions["alpha"])
        self.assertIn("echo gamma", regions["gamma"])
        self.assertNotIn("finished=true", regions["gamma"])
        self.assertIn("finished=true", shared)
        self.assertIn("shared_helper", shared)
        self.assertNotIn("alpha_only", shared)

    def test_a_stage_with_no_region_is_refused(self):
        with self.assertRaises(ValueError):
            inputs.split_script(SCRIPT, ("alpha", "beta", "gamma", "delta"))


def record(rows: list[str]) -> dict:
    return inputs.read_status("\n".join(rows) + "\n")


HOST, OS, KEY = "UUID-1", "27.0.1 26A434", "a" * 64
FRESH = f"lookup\tpass\t2026.1011.1\t2026-10-11T01:00:00Z\t{KEY}\t{HOST}\t{OS}"


class OnlyAFreshPassWithAnEqualKeyIsCarried(unittest.TestCase):

    def decide(self, rows, *, key=KEY, host=HOST, os_version=OS, asked=(), full=False):
        decisions = inputs.decide(("lookup",), {"lookup": inputs.Key(key, "")}, record(rows), host, os_version,
                                  asked=asked, full=full)
        return decisions[0]

    def test_a_fresh_pass_with_an_equal_key_on_the_same_mac_is_carried_and_says_why(self):
        decision = self.decide([FRESH])
        self.assertFalse(decision.run)
        self.assertIn(KEY[:12], decision.why)
        self.assertIn("2026.1011.1", decision.why)
        self.assertIn("2026-10-11", decision.why)

    def test_nothing_else_is_carried(self):
        cases = {
            "a failure": FRESH.replace("\tpass\t", "\tfail\t"),
            "an unknown result": FRESH.replace("\tpass\t", "\tskipped\t"),
            "a carried row": FRESH.replace("\tpass\t", "\tcarried\t"),
            "another hash": FRESH.replace(KEY, "b" * 64),
            "another host": FRESH.replace(HOST, "UUID-2"),
            "another macOS": FRESH.replace(OS, "27.0 26A428"),
            "a row with no key": FRESH.replace(KEY, "-"),
            "a row from before keys": "\t".join(FRESH.split("\t")[:4]),
        }
        for name, row in cases.items():
            with self.subTest(name):
                self.assertTrue(self.decide([row]).run)
        self.assertTrue(self.decide([]).run, "a stage never recorded")
        self.assertTrue(self.decide([FRESH], key=None).run, "a stage whose key could not be computed")

    def test_asked_and_full_run_fresh_whatever_is_recorded(self):
        self.assertTrue(self.decide([FRESH], asked=("lookup",)).run)
        self.assertTrue(self.decide([FRESH], full=True).run)

    def test_a_stage_not_asked_for_is_neither_run_nor_carried(self):
        decisions = inputs.decide(("lookup", "panel"), {"lookup": inputs.Key(KEY, ""), "panel": inputs.Key(KEY, "")},
                                  record([FRESH]), HOST, OS, asked=("panel",), full=False)
        by_stage = {d.stage: d for d in decisions}
        self.assertTrue(by_stage["panel"].run)
        self.assertFalse(by_stage["lookup"].run)
        self.assertFalse(by_stage["lookup"].carried)


class TheRecordHoldsTheKeyItRanUnder(unittest.TestCase):
    """`e2e-status.sh record` files the key, the host and the macOS build beside each stage; Python reads them back."""

    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-e2e-record-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        (self.root / "Tools").mkdir()
        shutil.copy(STATUS_SCRIPT, self.root / "Tools" / "e2e-status.sh")
        self.keys = self.root / "keys.tsv"
        self.keys.write_text(f"lookup\t{KEY}\npanel\t-\n")

    def run_record(self, results: str) -> dict:
        done = subprocess.run([BASH, str(self.root / "Tools" / "e2e-status.sh"), "record", "2026.1011.9",
                               str(self.keys), HOST, OS], input=results, capture_output=True, text=True,
                              timeout=60, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        return inputs.read_status((self.root / ".build" / "e2e-status.tsv").read_text())

    def test_a_pass_is_filed_with_its_key_host_and_macos(self):
        records = self.run_record("RESULT\tlookup\tpass\nRESULT\tpanel\tpass\nRESULT\tpanel\tfail\n")
        self.assertEqual((records["lookup"].result, records["lookup"].key, records["lookup"].host, records["lookup"].os),
                         ("pass", KEY, HOST, OS))
        self.assertEqual(records["lookup"].build, "2026.1011.9")
        self.assertEqual(records["panel"].result, "fail")
        self.assertEqual(records["panel"].key, "-")

    def test_what_was_filed_is_carried_next_time_and_only_that(self):
        records = self.run_record("RESULT\tlookup\tpass\n")
        decision = inputs.decide(("lookup",), {"lookup": inputs.Key(KEY, "")}, records, HOST, OS)[0]
        self.assertTrue(decision.carried)

    def test_a_key_that_moved_during_the_run_is_filed_as_none(self):
        after = {"lookup": "c" * 64, "panel": "-"}
        settled = inputs.settle({"lookup": KEY, "panel": "-"}, after)
        self.assertEqual(settled, {"lookup": "-", "panel": "-"})
        self.assertEqual(inputs.settle({"lookup": KEY}, {"lookup": KEY}), {"lookup": KEY})


class AReleaseNeedsAFreshPassOfEveryStageOnItsBuild(unittest.TestCase):

    STAGES = ("lookup", "panel")

    def rows(self, panel_result="pass", panel_build="2026.1011.1"):
        return record([FRESH, FRESH.replace("lookup", "panel").replace("\tpass\t", f"\t{panel_result}\t")
                       .replace("2026.1011.1", panel_build)])

    def test_every_fresh_pass_on_the_build_is_accepted(self):
        self.assertEqual(inputs.release_refusals(self.STAGES, self.rows(), "2026.1011.1"), [])

    def test_a_carried_failed_missing_or_older_row_is_refused(self):
        for name, rows in {
            "carried": self.rows(panel_result="carried"),
            "failed": self.rows(panel_result="fail"),
            "another build": self.rows(panel_build="2026.1010.7"),
            "missing": record([FRESH]),
        }.items():
            with self.subTest(name):
                refused = inputs.release_refusals(self.STAGES, rows, "2026.1011.1")
                self.assertEqual(len(refused), 1, refused)
                self.assertIn("panel", refused[0])

    def test_the_status_script_gate_refuses_a_file_holding_a_carried_row(self):
        root = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-e2e-gate-"))
        self.addCleanup(shutil.rmtree, root, True)
        (root / "Tools").mkdir()
        (root / ".build").mkdir()
        shutil.copy(STATUS_SCRIPT, root / "Tools" / "e2e-status.sh")
        shutil.copy(TOOL, root / "Tools" / "e2e-inputs.py")
        shutil.copy(REPO / "Tools" / "python.sh", root / "Tools" / "python.sh")
        shutil.copy(REPO / "Tools" / "e2e.sh", root / "Tools" / "e2e.sh")
        stages = inputs.known_stages((REPO / "Tools" / "e2e.sh").read_text())
        good = [FRESH.replace("lookup", stage, 1) for stage in stages]
        for rows, expected in ((good, 0), (good[:-1] + [good[-1].replace("\tpass\t", "\tcarried\t")], 1)):
            (root / ".build" / "e2e-status.tsv").write_text("\n".join(rows) + "\n")
            done = subprocess.run([BASH, str(root / "Tools" / "e2e-status.sh"), "require-fresh", "2026.1011.1"],
                                  capture_output=True, text=True, timeout=120, check=False)
            self.assertEqual(done.returncode, expected, done.stdout + done.stderr)
        self.assertIn(stages[-1], done.stdout + done.stderr)


class TheRealInputsFileCoversTheTree(unittest.TestCase):
    """The checks the scratch repository cannot make: the real file, against the real package and the real script."""

    @classmethod
    def setUpClass(cls):
        cls.targets = inputs.targets_from_dump(inputs.dump_package(REPO))
        cls.script = (REPO / "Tools" / "e2e.sh").read_text()
        cls.rows = inputs.parse_inputs(inputs.INPUTS.read_text())
        cls.stages = inputs.known_stages(cls.script)

    def test_the_declarations_have_no_problems(self):
        self.assertEqual(inputs.problems(REPO, self.script, self.rows, self.targets), [])

    def test_every_stage_has_a_key(self):
        keys = inputs.stage_keys(REPO, self.script, self.rows, self.targets)
        self.assertGreaterEqual(len(self.stages), 18)
        for stage in self.stages:
            with self.subTest(stage=stage):
                self.assertIsNotNone(keys[stage].value, keys[stage].why)

    def test_the_problem_scan_can_fail(self):
        """Each problem it looks for, planted in a copy of the real declarations."""
        first = self.stages[0]
        plants = {
            "a stage with no entry": [row for row in self.rows if row.stage != first],
            "a pattern that matches nothing": self.rows + inputs.parse_inputs(f"{first}\tpath\tTools/e2e/nothing-here.*\tplant\n"),
            "a module claimed nowhere": [row for row in self.rows if not (row.kind == "unexercised" and row.value == "XiaolaiDictAlign")],
            "a module both claimed and unexercised": self.rows + inputs.parse_inputs(f"{first}\tmodule\tXiaolaiDictAlign\tplant\n"),
        }
        for name, rows in plants.items():
            with self.subTest(name):
                self.assertNotEqual(inputs.problems(REPO, self.script, rows, self.targets), [])

    def test_a_helper_a_stage_uses_and_does_not_declare_is_named(self):
        script = self.script.replace("if want panel; then", 'if want panel; then\n"$helpers/drag-card" x', 1)
        rows = [row for row in self.rows if not (row.stage == "panel" and "drag-card" in row.value)]
        found = inputs.problems(REPO, script, rows, self.targets)
        self.assertTrue(any("drag-card" in p and "panel" in p for p in found), found)

    def test_a_function_one_stage_defines_and_another_calls_is_named(self):
        script = self.script.replace("if want panel; then", "if want panel; then\nplanted_only_here() { :; }", 1) \
            .replace("if want model; then", "if want model; then\nplanted_only_here", 1)
        found = inputs.problems(REPO, script, self.rows, self.targets)
        self.assertTrue(any("planted_only_here" in p for p in found), found)

    def test_touching_any_declared_input_moves_its_stages_key(self):
        """For every stage and every input it declares — and every shared one — a touch of one matched file, in a copy
        of the tree, moves the key."""
        copy = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-e2e-mutation-"))
        self.addCleanup(shutil.rmtree, copy, True)
        for name in ("Sources", "Tools", "Resources", "Strings", "Tests"):
            if (REPO / name).exists():
                shutil.copytree(REPO / name, copy / name, ignore=shutil.ignore_patterns(".build", "__pycache__"))
        for name in ("Package.swift", "Package.resolved", "Makefile"):
            if (REPO / name).exists():
                shutil.copy(REPO / name, copy / name)
        before = inputs.stage_keys(copy, self.script, self.rows, self.targets)
        mutations = 0
        for stage in self.stages:
            for row in [r for r in self.rows if r.stage in (stage, "*") and r.kind in ("module", "own", "path")]:
                files = (inputs.module_closure_files(copy, self.targets, [row.value]) if row.kind == "module"
                         else inputs.target_own_files(copy, self.targets, row.value) if row.kind == "own"
                         else inputs.pattern_files(copy, row.value))
                self.assertTrue(files, f"{stage}: {row.value} matches nothing")
                target = copy / files[-1]
                original = target.read_bytes()
                target.write_bytes(original + b"\n")
                try:
                    after = inputs.stage_keys(copy, self.script, self.rows, self.targets, only=(stage,))
                finally:
                    target.write_bytes(original)
                mutations += 1
                with self.subTest(stage=stage, input=row.value):
                    self.assertNotEqual(after[stage].value, before[stage].value)
        self.assertGreater(mutations, 50)


class TheCommandsAndTheRunUseIt(unittest.TestCase):

    def test_the_makefile_offers_incremental_full_and_named_runs(self):
        make = (REPO / "Makefile").read_text()
        self.assertRegex(make, r"(?m)^e2e-full:")
        self.assertIn("XIAOLAIDICT_E2E_FULL", make)

    def test_the_scripts_parse_under_the_macs_own_bash(self):
        for script in (REPO / "Tools" / "e2e.sh", STATUS_SCRIPT):
            with self.subTest(script=script.name):
                done = subprocess.run([BASH, "-n", str(script)], capture_output=True, text=True, timeout=60, check=False)
                self.assertEqual(done.returncode, 0, done.stderr)

    def test_the_run_plans_records_with_keys_and_prints_the_table(self):
        text = (REPO / "Tools" / "e2e.sh").read_text()
        for needle in ("Tools/e2e-inputs.py keys", "Tools/e2e-inputs.py plan", "Tools/e2e-inputs.py settle", "Tools/e2e-inputs.py table",
                       "e2e-status.sh record \"$remote_version\" \"$"):
            self.assertIn(needle, text)


if __name__ == "__main__":
    unittest.main()
