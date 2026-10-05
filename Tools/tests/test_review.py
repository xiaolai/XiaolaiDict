"""The review stage's fixture and its readings, against the ledger's real schema.

The stage runs only on the E2E Mac, against a ledger set aside for it, so a seed the queue would not
ask is found out there as "no card on screen" after a full build and ship. These tests seed a ledger
built from the schema `XiaolaiDictCore` executes and ask it the queue's own question — the askable
predicate read out of the Swift source — so a fixture the app would refuse fails here first.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import sqlite3
import tempfile
import time
import unittest

from ledger_schema import REPO, askable_predicate, scheduler_version, study_ledger

SCRIPT = REPO / "Tools" / "e2e" / "review.py"
_spec = importlib.util.spec_from_file_location("review", SCRIPT)
review = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(review)

NOW = 1_800_000_000.0


class SeedTests(unittest.TestCase):
    def ledger(self) -> pathlib.Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = pathlib.Path(directory.name) / "ledger.sqlite"
        study_ledger(path)
        return path

    def seeded(self, dictionary: str = "com.apple.dictionary.NOAD") -> tuple[pathlib.Path, dict]:
        path = self.ledger()
        output = path.with_name("fixture.json")
        review.seed(str(path), dictionary, str(output), now=NOW)
        return path, json.loads(output.read_text())

    def query(self, path: pathlib.Path, sql: str, *bind) -> list[tuple]:
        db = sqlite3.connect(path)
        try:
            return db.execute(sql, bind).fetchall()
        finally:
            db.close()

    def test_every_seeded_card_is_one_the_queue_asks_now(self):
        path, fixture = self.seeded()
        # `dueCards`' own filters over the askable predicate the Swift source declares. **Which cards,
        # not in what order**: the window shuffles cards due on one study day (SittingPlanner, WI-2),
        # and the drive reads whichever card it is shown.
        asked = [row[0] for row in self.query(path, f"""
            SELECT c.id FROM study_cards c JOIN study_notes n ON n.id = c.note_id
            WHERE c.paused = 0
              AND (c.hidden_until IS NULL OR c.hidden_until <= ?1)
              AND (c.due IS NULL OR c.due <= ?1)
              AND {askable_predicate()}
              AND n.dictionary = ?2
            """, NOW, "com.apple.dictionary.NOAD")]
        self.assertEqual(sorted(asked), sorted(card["card"] for card in fixture["cards"]))
        self.assertGreaterEqual(len(asked), 6, "the stage spends five cards and needs one to spare")

    def test_no_seeded_card_is_new_so_the_daily_allowance_cannot_hold_one_back(self):
        path, _ = self.seeded()
        phases = {row[0] for row in self.query(path, "SELECT phase FROM study_cards")}
        self.assertEqual(phases, {"review"})

    def test_each_answer_is_the_readers_own_usable_and_carries_a_secret_no_other_text_contains(self):
        path, fixture = self.seeded()
        rows = self.query(path, "SELECT origin, is_usable, text FROM study_answers")
        self.assertEqual({(origin, usable) for origin, usable, _ in rows}, {("reader", 1)})
        answers = [card["answer"] for card in fixture["cards"]]
        words = [card["word"] for card in fixture["cards"]]
        self.assertEqual(sorted(text for _, _, text in rows), sorted(answers))
        self.assertEqual(len(set(answers)), len(answers))
        for answer in answers:
            # A secret inside another would read as that card's answer being on screen.
            self.assertEqual([other for other in answers if answer in other], [answer])
            # And a word inside an answer would put the card's word on the back as well as the front.
            self.assertFalse([word for word in words if word in answer], answer)

    def test_a_card_carries_the_version_of_the_scheduler_the_app_runs(self):
        path, _ = self.seeded()
        versions = {row[0] for row in self.query(path, "SELECT scheduler_version FROM study_cards")}
        self.assertEqual(versions, {scheduler_version()})

    def test_the_notes_are_namespaced_by_the_dictionary_review_is_scoped_to(self):
        path, fixture = self.seeded("com.example.primary")
        self.assertEqual(fixture["dictionary"], "com.example.primary")
        self.assertEqual({row[0] for row in self.query(path, "SELECT dictionary FROM study_notes")},
                         {"com.example.primary"})

    def test_a_ledger_that_already_holds_notes_is_refused(self):
        # The seed is the positive control that the reader's ledger was set aside: it runs only on an
        # empty one, so a stage that failed to isolate writes nothing into the reader's study.
        path, _ = self.seeded()
        with self.assertRaises(AssertionError):
            review.seed(str(path), "com.apple.dictionary.NOAD", str(path.with_name("again.json")), now=NOW)


class ReadingTests(unittest.TestCase):
    def window(self, title: str, texts: list[str], names: list[list[str]] | None = None) -> dict:
        return {"title": title, "texts": texts,
                "nodes": [{"role": "AXStaticText", "names": n} for n in (names or [])]}

    def test_a_word_is_on_a_card_only_as_a_whole_text(self):
        window = self.window("Review", ["pellucid", "1 of 8", "lucid prose"])
        self.assertEqual(review.words_on(window, ["lucid", "pellucid"]), {"pellucid"})

    def test_a_secret_is_found_in_a_text_or_a_control_name_of_any_window(self):
        report = {"windows": [
            self.window("Review", ["ephemeral"]),
            self.window("Other", [], [["Show QZXsecret"]]),
        ]}
        self.assertEqual(review.secrets_in(report, ["QZXsecret", "QZXother"]), {"QZXsecret"})
        self.assertEqual(review.secrets_in({"windows": [self.window("Review", ["ephemeral"])]},
                                           ["QZXsecret"]), set())

    def test_the_review_window_is_the_one_titled_by_its_pane(self):
        report = {"windows": [self.window("Lookup", []), self.window("Review — 8", ["x"])]}
        self.assertEqual(review.review_window(report)["title"], "Review — 8")
        self.assertIsNone(review.review_window({"windows": [self.window("History", [])]}))


class LedgerStateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = pathlib.Path(directory.name) / "Application Support" / "ledger.sqlite"
        self.path.parent.mkdir()
        study_ledger(self.path)
        output = self.path.with_name("fixture.json")
        review.seed(str(self.path), "noad", str(output), now=NOW)
        self.fixture = json.loads(output.read_text())

    def write(self, sql: str, *bind) -> None:
        db = sqlite3.connect(self.path)
        try:
            db.execute(sql, bind)
            db.commit()
        finally:
            db.close()

    def test_nothing_written_is_no_change(self):
        # A path with a space in it, as the reader's own ledger has: read through a `file:` URI.
        before = review.ledger_state(str(self.path))
        self.assertEqual(review.changes(before, review.ledger_state(str(self.path))), [])
        self.assertEqual(before["counts"]["study_cards"], len(self.fixture["cards"]))

    def test_a_review_event_and_a_moved_schedule_are_both_named(self):
        card = self.fixture["cards"][0]["card"]
        before = review.ledger_state(str(self.path))
        self.write("""INSERT INTO review_events (id, card_id, grade, reviewed_at, before_phase, after_phase,
                      after_stability, after_difficulty, after_due, scheduler_version, retention,
                      card_revision) VALUES ('E1', ?, 3, ?, 'review', 'review', 20, 5, ?, 'v', 0.9, 0)""",
                   card, NOW, NOW + 86_400)
        self.write("UPDATE study_cards SET revision = revision + 1 WHERE id = ?", card)
        after = review.ledger_state(str(self.path))
        found = review.changes(before, after)
        self.assertTrue(any("review_events" in line for line in found), found)
        self.assertTrue(any(card in line for line in found), found)
        self.assertEqual(review.new_events(before, after), {"E1": [card, 3, "graded"]})

    def test_a_lookup_row_is_a_change(self):
        before = review.ledger_state(str(self.path))
        self.write("INSERT INTO lookups (surface, lemma, context, looked_up_at) VALUES ('w', 'w', 'w', 1.0)")
        self.assertTrue(any("lookups" in line for line in review.changes(before, review.ledger_state(str(self.path)))))

    def test_a_voided_event_is_not_a_live_one(self):
        card = self.fixture["cards"][1]["card"]
        before = review.ledger_state(str(self.path))
        self.write("""INSERT INTO review_events (id, card_id, grade, reviewed_at, before_phase, after_phase,
                      after_stability, after_difficulty, after_due, scheduler_version, retention,
                      card_revision, voided_at) VALUES ('E2', ?, 1, ?, 'review', 'relearning', 2, 6, ?, 'v',
                      0.9, 0, ?)""", card, NOW, NOW + 600, NOW + 1)
        self.assertEqual(review.new_events(before, review.ledger_state(str(self.path))), {})

    # **An event changed in place is a write** (audit-fix round 2, #22). `changes` compared the row counts
    # and the cards' schedules and never the events, so a key that voided a grade, or rewrote one, with
    # the card left as it was, passed every "wrote nothing" assertion.

    def live_event(self) -> str:
        card = self.fixture["cards"][2]["card"]
        self.write("""INSERT INTO review_events (id, card_id, grade, reviewed_at, before_phase, after_phase,
                      after_stability, after_difficulty, after_due, scheduler_version, retention,
                      card_revision) VALUES ('E3', ?, 3, ?, 'review', 'review', 20, 5, ?, 'v', 0.9, 0)""",
                   card, NOW, NOW + 86_400)
        return card

    def test_voiding_an_event_is_a_change(self):
        self.live_event()
        before = review.ledger_state(str(self.path))
        self.write("UPDATE review_events SET voided_at = ? WHERE id = 'E3'", NOW + 5)
        found = review.changes(before, review.ledger_state(str(self.path)))
        self.assertTrue(any("E3" in line for line in found), f"a voided grade passed as no write: {found}")

    def test_rewriting_an_event_is_a_change(self):
        self.live_event()
        before = review.ledger_state(str(self.path))
        self.write("UPDATE review_events SET grade = 1 WHERE id = 'E3'")
        found = review.changes(before, review.ledger_state(str(self.path)))
        self.assertTrue(any("E3" in line for line in found), f"a rewritten grade passed as no write: {found}")

    def test_a_voided_event_still_moves_nothing_new(self):
        """The control: voiding is a change, and still not a new live event."""
        self.live_event()
        before = review.ledger_state(str(self.path))
        self.write("UPDATE review_events SET voided_at = ? WHERE id = 'E3'", NOW + 5)
        self.assertEqual(review.new_events(before, review.ledger_state(str(self.path))), {})

    # **Every column, not a list of them** (audit-fix round 3, C3). The snapshot named ten event columns
    # and eight card columns, so a key that rewrote an event's `before_*` half, its scheduler or its
    # retention — or a card's prompt or scheduler — passed every "wrote nothing" assertion.

    def test_rewriting_any_event_column_is_a_change(self):
        self.live_event()
        rewrites = {"before_phase": "relearning", "before_stability": 21.5, "before_difficulty": 5.5,
                    "before_last_review": NOW - 7, "before_due": NOW + 7, "scheduler_version": "w",
                    "retention": 0.85, "card_revision": 9, "after_due": NOW + 99, "reviewed_at": NOW + 3}
        columns = self.columns("review_events")
        self.assertEqual(set(rewrites) | {"id", "card_id", "grade", "kind", "voided_at", "after_phase",
                                          "after_stability", "after_difficulty"}, set(columns),
                         "a column this test does not rewrite: add it, so the snapshot is shown to read it")
        for column, value in rewrites.items():
            with self.subTest(column=column):
                before = review.ledger_state(str(self.path))
                self.write(f"UPDATE review_events SET {column} = ? WHERE id = 'E3'", value)
                found = review.changes(before, review.ledger_state(str(self.path)))
                self.assertTrue(any("E3" in line for line in found), f"{column} rewritten passed as no write: {found}")

    def test_rewriting_any_card_column_is_a_change(self):
        card = self.fixture["cards"][3]["card"]
        rewrites = {"prompt": "rewritten", "scheduler_version": "w", "created_at": NOW + 11, "stability": 33.0,
                    "due": NOW + 13, "revision": 7, "hidden_until": NOW + 17, "paused": 1}
        for column, value in rewrites.items():
            with self.subTest(column=column):
                before = review.ledger_state(str(self.path))
                self.write(f"UPDATE study_cards SET {column} = ? WHERE id = ?", value, card)
                found = review.changes(before, review.ledger_state(str(self.path)))
                self.assertTrue(any(card in line for line in found), f"{column} rewritten passed as no write: {found}")

    def columns(self, table: str) -> list[str]:
        db = sqlite3.connect(self.path)
        try:
            return [row[1] for row in db.execute(f"PRAGMA table_info({table})")]
        finally:
            db.close()


class OneReadTests(unittest.TestCase):
    """**One reading is one read transaction** (audit-fix round 3, #14). The counts, the cards and the
    events were separate statements, each its own snapshot, so a grade committed between them gave a
    reading whose count of events disagreed with the events it listed — and `changes` reported a write
    that no single moment of the ledger held. The ledger is in WAL mode, as the app keeps it, so a
    reader does not block the grade; it reads from before it, or after it, whole."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = pathlib.Path(directory.name) / "ledger.sqlite"
        study_ledger(self.path)
        db = sqlite3.connect(self.path)
        try:
            self.assertEqual(db.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
        finally:
            db.close()
        output = self.path.with_name("fixture.json")
        review.seed(str(self.path), "noad", str(output), now=NOW)
        self.card = json.loads(output.read_text())["cards"][0]["card"]
        self.real_connect = review._connect
        self.addCleanup(setattr, review, "_connect", self.real_connect)

    def grade(self) -> None:
        """A grade, as the app writes one: the event and the card's revision, in one transaction."""
        db = sqlite3.connect(self.path)
        try:
            db.execute("""INSERT INTO review_events (id, card_id, grade, reviewed_at, before_phase, after_phase,
                          after_stability, after_difficulty, after_due, scheduler_version, retention,
                          card_revision) VALUES ('G1', ?, 3, ?, 'review', 'review', 20, 5, ?, 'v', 0.9, 0)""",
                       (self.card, NOW, NOW + 86_400))
            db.execute("UPDATE study_cards SET revision = revision + 1 WHERE id = ?", (self.card,))
            db.commit()
        finally:
            db.close()

    def test_a_grade_committed_mid_reading_is_seen_whole_or_not_at_all(self):
        test = self

        class GradedMidReading:
            """The reading's connection, with a grade committed by another just before its first row read."""

            def __init__(self, real):
                self.real, self.graded = real, False

            def execute(self, sql, *args):
                if not self.graded and sql.lstrip().upper().startswith("SELECT") and "count(" not in sql:
                    self.graded = True
                    test.grade()
                return self.real.execute(sql, *args)

            def __getattr__(self, name):
                return getattr(self.real, name)

        review._connect = lambda ledger: GradedMidReading(self.real_connect(ledger))
        state = review.ledger_state(str(self.path))
        self.assertEqual(state["counts"]["review_events"], len(state["events"]),
                         f"the count of events and the events read disagree: {state['counts']} {list(state['events'])}")
        self.assertEqual(state["counts"]["study_cards"], len(state["cards"]))
        # Both halves of the one grade, or neither.
        self.assertEqual("G1" in state["events"], state["cards"][self.card]["revision"] == 1,
                         (list(state["events"]), state["cards"][self.card]))

    def test_the_reading_after_the_grade_has_it(self):
        """The control: a grade committed before the reading is in it."""
        self.grade()
        state = review.ledger_state(str(self.path))
        self.assertIn("G1", state["events"])
        self.assertEqual(state["counts"]["review_events"], len(state["events"]))


class HeldKeyTimingTests(unittest.TestCase):
    """`held` says when the grade was made, counted from the key going down. The `keys` helper blocks for
    the whole hold and its tail, so a wait begun when it returned starts well after the key went down and
    reads 0.0 for any grade written during the hold — a number that is not the one the line names.

    The stand-in `keys` writes the grade 0.6 s into a 1.8 s run, as the app does while the key is
    still down, stamped with the instant it wrote it; the line must report that, not the time after the
    helper finished.

    **And not the time after the parent got round to watching** (audit-fix round 1, #31). A wait begun
    once the helper had been launched read a grade already written as 0.0 whenever the parent was
    delayed between the launch and the first poll. The figure is now the event's own instant less the
    key-down instant the helper reports, so no delay on this side moves it."""

    WRITTEN_AFTER = 0.6

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = pathlib.Path(directory.name)
        self.path = root / "Application Support" / "ledger.sqlite"
        self.path.parent.mkdir()
        study_ledger(self.path)
        fixture = root / "fixture.json"
        review.seed(str(self.path), "noad", str(fixture), now=NOW)
        self.word = "laconic"
        card = next(c["card"] for c in json.loads(fixture.read_text())["cards"] if c["word"] == self.word)
        helpers = root / "helpers"
        helpers.mkdir()
        keys = helpers / "keys"
        # The key goes down as the stand-in starts, as the real helper's does after its tap is made.
        keys.write_text(f"""#!/usr/bin/env python3
import json, sqlite3, time
down = time.time()
time.sleep({self.WRITTEN_AFTER})
db = sqlite3.connect({str(self.path)!r})
db.execute('''INSERT INTO review_events (id, card_id, grade, reviewed_at, before_phase, after_phase,
              after_stability, after_difficulty, after_due, scheduler_version, retention, card_revision)
              VALUES ('HELD', ?, 3, ?, 'review', 'review', 20, 5, ?, 'v', 0.9, 0)''',
           ({card!r}, time.time(), {NOW + 86_400}))
db.commit()
db.close()
time.sleep(1.2)
print(json.dumps({{"down": 1, "downAt": down, "heldSeconds": 1.5, "repeats": 40, "seenRepeats": 40, "up": 1}}))
""")
        keys.chmod(0o755)
        evidence = root / "evidence"
        evidence.mkdir()
        self.drive = review.Drive(str(helpers), str(self.path), str(fixture), str(evidence))
        # Nothing on this Mac is driven: no window is asked about and nothing is captured.
        self.drive.in_front = lambda step: None
        self.drive.card_shown = lambda label, previous=None, seconds=10: (None, "gregarious", 0.0)
        self.drive.capture = lambda name: None

    def held_line(self) -> tuple[str, float]:
        import contextlib
        import io
        import re
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            following = self.drive.held(self.word)
        self.assertEqual(following, "gregarious")
        self.assertEqual(self.drive.failures, 0, printed.getvalue())
        line = next(line for line in printed.getvalue().splitlines() if "a held 2 grades once" in line)
        return line, float(re.search(r"written ([0-9.]+)s after the key went down", line).group(1))

    def test_the_wait_is_measured_from_the_key_going_down(self):
        line, written = self.held_line()
        self.assertGreaterEqual(written, self.WRITTEN_AFTER - 0.1, line)
        self.assertLess(written, 1.5, line)

    def test_a_parent_delayed_after_the_launch_still_measures_from_the_key_going_down(self):
        """The parent descheduled for a second straight after starting the helper: by its first poll the
        grade is in the ledger, and a clock started then reads it as written at once."""
        launch = review.subprocess.Popen

        class Delayed(launch):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                time.sleep(1.0)

        review.subprocess.Popen = Delayed
        try:
            line, written = self.held_line()
        finally:
            review.subprocess.Popen = launch
        self.assertGreaterEqual(written, self.WRITTEN_AFTER - 0.1, line)
        self.assertLess(written, 1.0, line)


if __name__ == "__main__":
    unittest.main()
