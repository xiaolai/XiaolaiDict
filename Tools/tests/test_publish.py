"""Publishing replaces both outputs or neither, whatever fails and whenever."""
from __future__ import annotations

import errno
import os
import threading
import unittest
from pathlib import Path
from unittest import mock

from fixtures import DARK_BACK, OUTPUTS, Workspace, build, failing_on_call, outputs, publish, run


class PublishesAllOrNothing(unittest.TestCase):
    files: dict[str, bytes]

    @classmethod
    def setUpClass(cls) -> None:
        cls.files = build()

    def test_replaces_previous_outputs_entirely(self) -> None:
        ws = Workspace(self)
        ws.seed()
        publish.publish_outputs(ws.resources, self.files)
        self.assertEqual(outputs(ws.resources), self.files)  # stale.svg is gone, not merged
        self.assertEqual(ws.listing(), OUTPUTS)

    def test_refused_art_leaves_previous_outputs(self) -> None:
        # A colour that fails only when the document is built: the old script had deleted
        # XiaolaiDict.icon and written half of it by then.
        ws = Workspace(self)
        before = ws.seed()
        ws.mutate("xiaolaidict-icon-dark.svg", DARK_BACK, 'fill="#GGGGGG" stroke="#GGGGGG"')
        proc = run(ws.src, ws.resources)
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)
        self.assertEqual(outputs(ws.resources), before)
        self.assertEqual(ws.listing(), OUTPUTS)

    def test_write_failure_while_staging_leaves_previous_outputs(self) -> None:
        ws = Workspace(self)
        before = ws.seed()
        calls = []
        disk_full = failing_on_call(3, OSError(errno.ENOSPC, "No space left on device"),
                                    Path.write_bytes, calls)
        with mock.patch.object(Path, "write_bytes", disk_full), self.assertRaises(SystemExit) as cm:
            publish.publish_outputs(ws.resources, self.files)
        self.assertEqual(len(calls), 3, "the injected failure never happened")
        self.assertRegex(str(cm.exception), r"\Amake-icon\.py: error: .*No space left on device")
        self.assertEqual(outputs(ws.resources), before)
        self.assertEqual(ws.listing(), OUTPUTS)

    def test_failure_at_every_step_of_the_swap_rolls_back(self) -> None:
        real = os.rename
        for seeded in (True, False):
            for step in range(1, 5 if seeded else 3):
                for error in (OSError(errno.EIO, "I/O error"), KeyboardInterrupt()):
                    with self.subTest(seeded=seeded, step=step, error=type(error).__name__):
                        ws = Workspace(self)
                        before = ws.seed() if seeded else {}
                        calls = []
                        flaky = failing_on_call(step, error, real, calls)
                        with mock.patch.object(os, "rename", flaky), \
                                self.assertRaises((SystemExit, KeyboardInterrupt)):
                            publish.publish_outputs(ws.resources, self.files)
                        self.assertGreaterEqual(len(calls), step, "the injected failure never happened")
                        self.assertEqual(outputs(ws.resources), before)
                        self.assertEqual(ws.listing(), OUTPUTS if seeded else [])

    def test_concurrent_runs_are_serialised(self) -> None:
        # Hold the lock the script takes; its swap must wait for it rather than interleave.
        import fcntl

        ws = Workspace(self)
        before = ws.seed()
        fd = os.open(ws.resources, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            done = threading.Event()
            errors = []

            def contend() -> None:
                try:
                    publish.publish_outputs(ws.resources, self.files)
                except BaseException as e:  # reported below; a thread cannot fail the test itself
                    errors.append(e)
                done.set()

            worker = threading.Thread(target=contend)
            worker.start()
            self.assertFalse(done.wait(0.5), f"finished while another run held the lock; errors: {errors}")
            self.assertEqual(outputs(ws.resources), before)
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        worker.join(60)
        self.assertEqual(errors, [])
        self.assertEqual(outputs(ws.resources), self.files)


if __name__ == "__main__":
    unittest.main()
