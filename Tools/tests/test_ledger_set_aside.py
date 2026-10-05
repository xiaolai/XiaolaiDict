"""The reader's ledger, set aside by the E2E stages exactly as `Tools/e2e.sh` writes the two steps.

`ledger_backup` and `ledger_digest` are read out of the script and run in bash with `/usr/bin` first on
`PATH` — the `sqlite3` the E2E Mac runs them with — against a ledger in the two shapes a stage meets:

- **closed**: WAL in its header and no `-wal` or `-shm` beside it, which is the reader's ledger after a
  stage has put it back and before the app has opened it again. The backup opened it plainly, and a
  read-only connection cannot create the `-shm`, so it was CANTOPEN: on 2026-10-05 the `reminder` stage,
  run straight after `review`, got a 0-byte backup and stopped. The first test is the positive control
  that the fixture is that shape — the old command fails on it here too.
- **live**: commits still in a non-empty `-wal`, the writer's `-shm` beside it, which is the ledger of an
  app stopped mid-session. A backup that skipped the `-wal` would lose them.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import pathlib
import re
import sqlite3
import subprocess
import tempfile
import unittest

from ledger_schema import REPO

SCRIPT = REPO / "Tools" / "e2e.sh"
SQLITE = "/usr/bin/sqlite3"
# The E2E Mac's own: `sqlite3` on a developer's PATH may be another build entirely.
PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def function(name: str) -> str:
    """One shell function, as `e2e.sh` defines it: from `name() {` to the first line that is `}`."""
    text = SCRIPT.read_text()
    found = re.search(rf"^{name}\(\) {{.*?^}}$", text, re.MULTILINE | re.DOTALL)
    assert found, f"e2e.sh defines no {name}()"
    return found.group(0)


def shell(body: str, *args: str) -> subprocess.CompletedProcess:
    script = "\n".join([function("ledger_source"), function("ledger_digest"), function("ledger_backup"), body])
    return subprocess.run(["bash", "-c", script, "e2e", *args], text=True, capture_output=True,
                          env={"PATH": PATH}, check=False, timeout=60)


class LedgerSetAsideTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        # A space, as in "Application Support", where the reader's ledger lives.
        folder = pathlib.Path(self.scratch.name) / "Application Support"
        folder.mkdir()
        self.ledger = str(folder / "ledger.sqlite")
        self.copy = str(pathlib.Path(self.scratch.name) / "original-backup.sqlite")
        db = sqlite3.connect(self.ledger)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("CREATE TABLE readings (word TEXT)")
        db.executemany("INSERT INTO readings VALUES (?)", [("lucid",), ("frugal",)])
        db.commit()
        db.close()

    def tearDown(self):
        self.scratch.cleanup()

    def digest(self, path: str) -> str:
        done = shell('ledger_digest "$1"', path)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue(done.stdout.startswith("ok\n"), done.stdout)
        return done.stdout

    def test_the_closed_ledger_is_the_shape_the_old_backup_could_not_open(self):
        self.assertFalse(pathlib.Path(self.ledger + "-wal").exists())
        self.assertFalse(pathlib.Path(self.ledger + "-shm").exists())
        with open(self.ledger, "rb") as ledger:
            self.assertEqual(ledger.read(20)[18:20], b"\x02\x02", "the fixture is not in WAL mode")
        old = subprocess.run([SQLITE, "-readonly", self.ledger, f".backup '{self.copy}'"],
                             text=True, capture_output=True, check=False, timeout=60)
        self.assertNotEqual(old.returncode, 0, "the old backup opened a closed WAL ledger, so this proves nothing")
        self.assertIn("unable to open", old.stderr)

    def test_a_ledger_put_back_and_not_yet_opened_is_backed_up_whole(self):
        before = self.digest(self.ledger)
        done = shell('ledger_backup "$1" "$2"', self.ledger, self.copy)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.digest(self.copy), before)
        self.assertFalse(pathlib.Path(self.ledger + "-shm").exists(), "the backup wrote beside the reader's ledger")

    def test_a_ledger_with_commits_still_in_its_wal_is_backed_up_with_them(self):
        writer = sqlite3.connect(self.ledger)
        try:
            writer.execute("PRAGMA wal_autocheckpoint=0")
            writer.execute("INSERT INTO readings VALUES ('tenacious')")
            writer.commit()
            self.assertGreater(pathlib.Path(self.ledger + "-wal").stat().st_size, 0, "the commit is not in the -wal")
            done = shell('ledger_backup "$1" "$2"', self.ledger, self.copy)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(self.digest(self.copy), self.digest(self.ledger))
        finally:
            writer.close()
        copy = sqlite3.connect(self.copy)
        try:
            self.assertEqual(copy.execute("SELECT count(*) FROM readings").fetchone()[0], 3,
                             "the commit in the -wal did not reach the backup")
        finally:
            copy.close()

    def test_every_stage_that_sets_the_ledger_aside_backs_it_up_through_the_one_function(self):
        text = SCRIPT.read_text()
        self.assertEqual(text.count(".backup '"), 1, "a backup is taken somewhere other than ledger_backup")
        self.assertEqual(len(re.findall(r'ledger_backup "\$ledger" "\$(learning|review|reminder)_backup"', text)), 3)


if __name__ == "__main__":
    unittest.main()
