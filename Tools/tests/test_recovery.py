"""A publish that dies anywhere, even by SIGKILL between the two outputs, is finished or undone by
the next run: the pair on disk is never left mixed, and nothing is guessed when it cannot be sure."""
from __future__ import annotations

import contextlib
import errno
import hashlib
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

from fixtures import CONTOUR_DARK, CONTOUR_DARK_STROKE, OUTPUTS, SYNTHETIC, Workspace, build, outputs, publish, run

# Publishes SYNTHETIC in a separate interpreter that SIGKILLs itself on the n-th call of one file
# operation: no handler, no finally, no rollback runs. argv: tests dir, Resources dir, operation, n.
KILL_HARNESS = """
import os, shutil, signal, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import fixtures
op, n, calls = sys.argv[3], int(sys.argv[4]), []
owner = {"write_bytes": Path, "replace": os, "rename": os, "remove": os, "rmtree": shutil}[op]
real = getattr(owner, op)

def dies_on_nth(*args, **kwargs):
    calls.append(args)
    if len(calls) == n:
        os.kill(os.getpid(), signal.SIGKILL)
    return real(*args, **kwargs)

setattr(owner, op, dies_on_nth)
fixtures.publish.publish_outputs(Path(sys.argv[2]), fixtures.SYNTHETIC)
"""

# Where a kill can land, and the pair the next run must restore: before the journal is committed
# nothing published has moved, so the previous pair; after it, the journal's complete new pair.
KILL_POINTS = [
    ("write_bytes", 2, "previous"),  # while staging
    ("replace", 1, "previous"),  # committing the journal
    ("rename", 1, "new"),
    ("rename", 2, "new"),
    ("rename", 3, "new"),  # between the two outputs: XiaolaiDict.icon new, MenuBarIcon.svg old
    ("rename", 4, "new"),
    ("remove", 1, "new"),  # retiring the journal
    ("rmtree", 1, "new"),  # journal gone; only the replaced outputs left to discard
]


def kill_publish(test: unittest.TestCase, ws: Workspace, op: str, n: int) -> None:
    proc = subprocess.run([sys.executable, "-c", KILL_HARNESS, str(Path(__file__).parent), str(ws.resources),
                           op, str(n)], capture_output=True, text=True, timeout=120)
    test.assertEqual(proc.returncode, -signal.SIGKILL, f"the kill at {op} #{n} never happened: {proc.stderr}")
    test.assertIn(publish.WORK, ws.listing(), "the killed publish left nothing to recover from")


def recover(ws: Workspace) -> str:
    """The next run's recovery, with what it reports."""
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        publish.recover(ws.resources)
    return err.getvalue()


def everything(root: Path) -> dict[str, bytes | None]:
    """Every file and directory under root, leftovers included: to show that nothing moved."""
    return {p.relative_to(root).as_posix(): p.read_bytes() if p.is_file() else None for p in root.rglob("*")}


class RecoversFromAKill(unittest.TestCase):
    def test_a_kill_anywhere_is_repaired_by_the_next_run(self) -> None:
        for op, n, want in KILL_POINTS:
            with self.subTest(kill=f"{op} #{n}"):
                ws = Workspace(self)
                before = ws.seed()
                kill_publish(self, ws, op, n)
                report = recover(ws)
                self.assertEqual(outputs(ws.resources), before if want == "previous" else SYNTHETIC)
                self.assertEqual(ws.listing(), OUTPUTS)
                self.assertRegex(report, r"\Amake-icon\.py: (discarded|recovered an interrupted publish)")

    def test_the_journal_records_both_pairs_before_anything_moves(self) -> None:
        ws = Workspace(self)
        before = ws.seed()
        kill_publish(self, ws, "rename", 1)  # the journal is committed; nothing has moved
        self.assertEqual(outputs(ws.resources), before)
        journal = json.loads((ws.resources / publish.WORK / "journal").read_text())
        sha = {rel: hashlib.sha256(data).hexdigest() for rel, data in before.items()}
        self.assertEqual(journal["previous"], sha)
        self.assertEqual(journal["new"], {rel: hashlib.sha256(d).hexdigest() for rel, d in SYNTHETIC.items()})

    def test_a_mixed_pair_is_repaired_even_when_the_next_run_refuses_its_art(self) -> None:
        ws = Workspace(self)
        before = ws.seed()
        kill_publish(self, ws, "rename", 3)
        mixed = outputs(ws.resources)
        self.assertEqual(mixed["MenuBarIcon.svg"], before["MenuBarIcon.svg"])
        self.assertEqual(mixed["XiaolaiDict.icon/icon.json"], SYNTHETIC["XiaolaiDict.icon/icon.json"])
        ws.mutate(CONTOUR_DARK, CONTOUR_DARK_STROKE, 'stroke="#GGGGGG"')
        proc = run(ws.src, ws.resources)
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("rolled forward", proc.stderr)
        self.assertIn("is not a #RRGGBB colour", proc.stderr)
        self.assertEqual(outputs(ws.resources), SYNTHETIC)
        self.assertEqual(ws.listing(), OUTPUTS)

    def test_the_next_publish_repairs_then_replaces(self) -> None:
        ws = Workspace(self)
        ws.seed()
        kill_publish(self, ws, "rename", 3)
        with contextlib.redirect_stderr(io.StringIO()):
            publish.publish_outputs(ws.resources, build())
        self.assertEqual(outputs(ws.resources), build())
        self.assertEqual(ws.listing(), OUTPUTS)

    def test_incomplete_new_outputs_are_rolled_back(self) -> None:
        ws = Workspace(self)
        before = ws.seed()
        kill_publish(self, ws, "rename", 3)
        (ws.resources / publish.WORK / "new" / "MenuBarIcon.svg").write_bytes(b"torn")
        self.assertIn("rolled back", recover(ws))
        self.assertEqual(outputs(ws.resources), before)
        self.assertEqual(ws.listing(), OUTPUTS)

    def assert_left_alone(self, ws: Workspace, work: Path) -> None:
        """Recovery refuses, moves nothing, and names every copy's path."""
        state = everything(ws.resources)
        with self.assertRaises(SystemExit) as cm:
            recover(ws)
        for name in OUTPUTS:
            for path in (work / "new" / name, work / "old" / name, ws.resources / name):
                self.assertIn(str(path), str(cm.exception))
        self.assertIn(str(work / "journal"), str(cm.exception))
        self.assertEqual(everything(ws.resources), state)

    def test_a_missing_previous_copy_fails_loudly_and_nothing_moves(self) -> None:
        # Each time the new pair is torn too, so undoing is the only way left, and it cannot be done.
        for kill, torn, missing in ((3, "new/MenuBarIcon.svg", "old/XiaolaiDict.icon"),
                                    (4, "../XiaolaiDict.icon/icon.json", "old/MenuBarIcon.svg")):
            with self.subTest(kill=f"rename #{kill}", missing=missing):
                ws = Workspace(self)
                ws.seed()
                kill_publish(self, ws, "rename", kill)
                work = ws.resources / publish.WORK
                (work / torn).write_bytes(b"torn")
                (shutil.rmtree if (work / missing).is_dir() else os.remove)(work / missing)
                self.assert_left_alone(ws, work)

    def test_a_damaged_previous_copy_is_never_restored(self) -> None:
        for label, damage in (("changed", lambda old: (old / "XiaolaiDict.icon/icon.json").write_bytes(b"damaged")),
                              ("partial", lambda old: (old / "XiaolaiDict.icon/Assets/contour.svg").unlink())):
            with self.subTest(previous=label):
                ws = Workspace(self)
                ws.seed()
                kill_publish(self, ws, "rename", 3)
                work = ws.resources / publish.WORK
                (work / "new" / "MenuBarIcon.svg").write_bytes(b"torn")  # so forward is ruled out
                damage(work / "old")
                self.assert_left_alone(ws, work)

    def test_a_failed_swap_never_restores_a_damaged_previous_copy(self) -> None:
        ws = Workspace(self)
        ws.seed()
        work = ws.resources / publish.WORK
        real, calls = os.rename, []

        def damages_then_fails(*args, **kwargs):  # the set-aside XiaolaiDict.icon is damaged, then the swap fails
            calls.append(args)
            if len(calls) == 3:
                (work / "old" / "XiaolaiDict.icon" / "icon.json").write_bytes(b"damaged")
                raise OSError(errno.EIO, "I/O error")
            return real(*args, **kwargs)

        with mock.patch.object(os, "rename", damages_then_fails), self.assertRaises(SystemExit) as cm:
            publish.publish_outputs(ws.resources, SYNTHETIC)
        self.assertIn("rolled forward", str(cm.exception))
        self.assertEqual(outputs(ws.resources), SYNTHETIC)  # the new pair, not the damaged old one
        self.assertEqual(ws.listing(), OUTPUTS)

    def test_a_failed_rollback_is_repaired_by_the_next_run(self) -> None:
        ws = Workspace(self)
        ws.seed()
        real, calls = os.rename, []

        def fails_third_and_fourth(*args, **kwargs):  # the swap fails, then so does its rollback
            calls.append(args)
            if len(calls) in (3, 4):
                raise OSError(errno.EIO, "I/O error")
            return real(*args, **kwargs)

        with mock.patch.object(os, "rename", fails_third_and_fourth), self.assertRaises(SystemExit) as cm:
            publish.publish_outputs(ws.resources, SYNTHETIC)
        self.assertGreaterEqual(len(calls), 4, "the injected failures never happened")
        self.assertIn(str(ws.resources / publish.WORK), str(cm.exception))
        self.assertIn("rolled forward", recover(ws))
        self.assertEqual(outputs(ws.resources), SYNTHETIC)
        self.assertEqual(ws.listing(), OUTPUTS)

    def test_unrecognised_leftovers_stop_the_run_untouched(self) -> None:
        ws = Workspace(self)
        ws.seed()
        stray = ws.resources / ".make-icon-x1y2z3" / "old"
        stray.mkdir(parents=True)
        (stray / "MenuBarIcon.svg").write_bytes(b"maybe the only copy")
        state = everything(ws.resources)
        with self.assertRaises(SystemExit) as cm:
            recover(ws)
        self.assertIn(".make-icon-x1y2z3", str(cm.exception))
        self.assertEqual(everything(ws.resources), state)


if __name__ == "__main__":
    unittest.main()
