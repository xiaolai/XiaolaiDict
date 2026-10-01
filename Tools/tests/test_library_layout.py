"""The Library layout stage's fixture, seeded against the ledger's real schema.

The stage runs only on the E2E Mac, against a ledger copied aside, so a seed that violates the schema
is found out there — as "the expanded fixture failed its positive controls", after a ten-minute run.
The schema here is read out of the Swift sources rather than restated, so a test that passes cannot
be passing against a shape the app no longer writes.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import re
import sqlite3
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
CORE = REPO / "Sources" / "XiaolaiDictCore"
SCRIPT = REPO / "Tools" / "e2e" / "library-layout.py"
_spec = importlib.util.spec_from_file_location("library_layout", SCRIPT)
layout = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(layout)


def swift_literal(source: str, name: str) -> str:
    match = re.search(rf'static let {name} = """\n(.*?)\n\s*"""', source, re.S)
    assert match, f"{name} is no longer a multi-line literal; this test reads the schema from it"
    return match.group(1)


def lookups_schema() -> list[str]:
    """`lookups` as the migrations leave it: the table they create and every column they add."""
    sources = "\n".join(path.read_text() for path in sorted(CORE.glob("*.swift")))
    create = re.search(r"CREATE TABLE lookups \(.*?\);", sources, re.S)
    assert create, "the lookups table is no longer created where this test looks"
    added = re.findall(r"ALTER TABLE lookups ADD COLUMN [^;]*;", sources, re.S)
    assert len(added) >= 20, f"found only {len(added)} lookups columns added; the scan has gone blind"
    return [create.group(0), *added]


def ledger(path: pathlib.Path, kind: str) -> int:
    """A ledger holding one live lookup whose study note is of `kind`, with a dictionary answer."""
    study = (CORE / "StudyLedger.swift").read_text()
    db = sqlite3.connect(path)
    for statement in lookups_schema():
        db.executescript(statement)
    db.executescript(swift_literal(study, "studySchema"))
    db.executescript(swift_literal(study, "studyAnswerSchema"))
    db.execute("INSERT INTO lookups (id, surface, lemma, context, looked_up_at, context_range_location,"
               " context_range_length) VALUES (7, 'run', 'run', 'They run home.', 1.0, 5, 3)")
    identity = {
        "sense": ("NOAD.run", "run.1", "publisher", ""),
        "entry": ("NOAD.run", "", "none", ""),
        "phrase": ("", "", "", "run into"),
    }[kind]
    db.execute("INSERT INTO study_notes VALUES ('LIVE', ?, 'live', 'en', 'NOAD', ?, ?, ?, ?, 'active', 1.0, 1.0)",
               (kind, *identity))
    db.execute("INSERT INTO study_note_lookups VALUES ('LIVE', 7, 1.0)")
    db.execute("INSERT INTO study_answers VALUES ('LIVE', 'dictionary', 'move fast', 'v1', 'h', 1.0, 1)")
    db.commit()
    db.close()
    return 7


class SeedTests(unittest.TestCase):
    def seeded(self, kind: str) -> tuple[sqlite3.Connection, dict]:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        scratch = pathlib.Path(directory.name)
        path = scratch / "ledger.sqlite"
        lookup = ledger(path, kind)
        layout.seed(str(path), lookup, str(scratch / "fixture.json"))
        db = sqlite3.connect(path)
        self.addCleanup(db.close)
        return db, json.loads((scratch / "fixture.json").read_text())

    def test_every_target_kind_a_live_lookup_can_carry_is_cloned_inside_the_schema(self):
        # The live fixture's note is whatever the reader's primary dictionary made of the word: a
        # dictionary without sense keys gives an entry, and an entry carrying a sense key is refused.
        for kind in ("sense", "entry", "phrase"):
            with self.subTest(kind=kind):
                db, fixture = self.seeded(kind)
                kinds = {row[0] for row in db.execute(
                    "SELECT target_kind FROM study_notes WHERE id <> 'LIVE' AND target_kind <> 'custom'")}
                self.assertEqual(kinds, {kind})
                self.assertEqual(len(fixture["saved"]), 222)

    def test_a_copied_lookup_points_at_no_range_of_its_new_sentence(self):
        db, _ = self.seeded("sense")
        ranges = db.execute("SELECT count(*) FROM lookups WHERE id <> 7 AND "
                            "(context_range_location IS NOT NULL OR context_range_length IS NOT NULL)").fetchone()[0]
        self.assertEqual(ranges, 0)
        # Positive control: the original's range was there to be copied.
        self.assertEqual(db.execute("SELECT context_range_location FROM lookups WHERE id = 7").fetchone()[0], 5)

    def test_each_layout_reveals_a_target_no_earlier_reveal_has_shown(self):
        db, fixture = self.seeded("sense")
        targets = fixture["reveal"]
        self.assertEqual(set(targets), {"list", "grid"})
        ids = [targets[name]["note"] for name in ("list", "grid")]
        secrets = [targets[name]["secret"] for name in ("list", "grid")]
        self.assertEqual(len(set(ids)), 2)
        self.assertEqual(len(set(secrets)), 2)
        for note, secret in zip(ids, secrets, strict=True):
            self.assertIn(note, fixture["saved"][:8], "a reveal target must be among the rows the stage drives")
            holders = [row[0] for row in db.execute(
                "SELECT note_id FROM study_answers WHERE instr(text, ?) > 0", (secret,))]
            self.assertEqual(holders, [note], "exactly one answer may carry each secret")


if __name__ == "__main__":
    unittest.main()
