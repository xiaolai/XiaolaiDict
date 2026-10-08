"""The review stage, on the E2E Mac: its fixture, and the reader's keys against the real window.

    review.py seed <isolated-ledger> <dictionary> <fixture.json>
    review.py run <helpers> <ledger> <fixture.json> <evidence>

`seed` refuses a ledger that already holds a study note, which is the positive control that the
reader's own was set aside: it can only ever write into the stage's isolated one.

`run` prints one PASS or FAIL line per claim and DONE last; `e2e.sh` reads them with
`consume_verdicts`, which fails the stage on a missing DONE — a drive that died part-way must not read
as one that found nothing wrong.

**No reader prose is asserted here.** A card is found by its fixture word and an answer by a secret
the fixture invented, so rewording the surface cannot turn a check into one that passes over nothing:
the scan that guards `e2e.sh`'s phrases does not read this file, and it does not need to.
"""
from __future__ import annotations

import datetime
import json
import pathlib
import sqlite3
import subprocess
import sys
import time
import uuid

BUNDLE = "com.xiaolaidict"
DICTIONARY = "com.apple.Dictionary"
DICTIONARY_EXECUTABLE = "/System/Applications/Dictionary.app/Contents/MacOS/Dictionary"
FINDER = "com.apple.finder"
# `MemoryScheduler.version`, which every card the app writes carries. `test_review` compares this
# with the Swift source, so the two cannot drift apart unnoticed.
SCHEDULER_VERSION = "fsrs6-py9446cb0-one10m-no-fuzz-v1"
# Real words, so `E` opens an entry rather than an empty Dictionary window. **Eight**: the drive
# spends five and a batch is ten, so every one is in the first batch with three to spare.
WORDS = ("ephemeral", "meticulous", "laconic", "gregarious", "tenacious", "candid", "lucid", "frugal")
# Virtual key codes, as `keys` posts them.
KEY = {"space": "49", "e": "14", "1": "18", "2": "19", "s": "1", "t": "17"}
# `Grade`'s raw values: Forgot is `.again`, Remembered is `.good`.
FORGOT, REMEMBERED = 1, 3
# How long `2` is held. Long enough for the repeats a keyboard sends to arrive after the grade has
# been written and the next card drawn, which is when a repeat could grade a card nobody answered.
HOLD_SECONDS = "1.5"
DAY = 86_400
# The study day starts at 04:00 local (`StudyDay.standard`), which is where "Not Today" hides a card
# until.
STUDY_DAY_STARTS = 4
# A card's schedule: what "Not Today" must leave as it was. **Not what `ledger_state` reads**, which is
# every column of every card and event (audit-fix round 3, C3).
CARD_COLUMNS = ("phase", "stability", "difficulty", "last_review", "due", "revision", "hidden_until", "paused")
TABLES = ("lookups", "sense_encounters", "study_notes", "study_note_lookups", "study_cards", "review_events")


def secret(index: int) -> str:
    """An answer no surface could produce by itself, and no other card's answer contains."""
    return f"QZX{index}W{index}VKJ"


# ---------------------------------------------------------------------------------------------
# The fixture


def seed(ledger: str, dictionary: str, output: str, now: float | None = None) -> dict:
    """Eight cards the reader wrote, each already reviewed once and now overdue, oldest first.

    **Custom cards** (C07): the reader's own words need no lookup row, so the fixture writes no
    reading history it would have to invent, and `E` opens the card's own text. **In the review
    phase, not new**: new cards are rationed five a day, and a stage that spends five would have none
    to spare.
    """
    now = time.time() if now is None else now
    cards = []
    db = sqlite3.connect(ledger)
    try:
        db.execute("PRAGMA foreign_keys=ON")
        held = db.execute("SELECT count(*) FROM study_notes").fetchone()[0]
        assert held == 0, (f"positive control: this ledger already holds {held} study note(s), so it "
                           "is not the isolated one, and nothing is written into it")
        for index, word in enumerate(WORDS):
            note, card = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
            # A minute apart and oldest first. That is not the order the window asks: it shuffles cards
            # due on one study day (SittingPlanner, WI-2), so the drive reads whichever card is shown.
            due = now - 2 * DAY - (len(WORDS) - index) * 60
            enrolled = now - 30 * DAY
            db.execute(
                "INSERT INTO study_notes (id, target_kind, issuer, language, dictionary, entry_id, sense_key,"
                " sense_key_kind, phrase_text, enrollment, confirmed_at, created_at)"
                " VALUES (?, 'custom', 'live', 'en', ?, '', '', '', ?, 'active', ?, ?)",
                (note, dictionary, word, enrolled, enrolled))
            db.execute(
                "INSERT INTO study_answers (note_id, origin, text, dictionary_version, sense_hash,"
                " recorded_at, is_usable) VALUES (?, 'reader', ?, NULL, NULL, ?, 1)",
                (note, secret(index), enrolled))
            db.execute(
                "INSERT INTO study_cards (id, note_id, prompt, phase, stability, difficulty, last_review,"
                " due, paused, hidden_until, revision, scheduler_version, created_at)"
                " VALUES (?, ?, 'meaning', 'review', 12.0, 5.0, ?, ?, 0, NULL, 0, ?, ?)",
                (card, note, due - 12 * DAY, due, SCHEDULER_VERSION, enrolled))
            cards.append({"word": word, "note": note, "card": card, "answer": secret(index), "due": due})
        db.commit()
        broken = db.execute("PRAGMA foreign_key_check").fetchall()
        assert not broken, f"positive control: the fixture breaks a foreign key: {broken}"
    finally:
        db.close()
    fixture = {"dictionary": dictionary, "seededAt": now, "cards": cards}
    pathlib.Path(output).write_text(json.dumps(fixture, indent=2))
    return fixture


# ---------------------------------------------------------------------------------------------
# Readings


def review_window(report: dict) -> dict | None:
    """The Library window while it shows Review: it is titled by its pane."""
    found = [w for w in report.get("windows", []) if w.get("title", "").startswith("Review")]
    assert len(found) <= 1, f"{len(found)} windows are titled for Review: {[w['title'] for w in found]}"
    return found[0] if found else None


def words_on(window: dict, words) -> set:
    """Which of `words` the window shows **as a whole text**. A substring would find *lucid* in
    *pellucid*, or a word inside a tooltip that names it."""
    texts = set(window.get("texts", []))
    return {word for word in words if word in texts}


def secrets_in(report: dict, secrets) -> set:
    """Which of `secrets` appear anywhere the accessibility tree says anything: every window's title,
    texts, and the names of every node — a label, a description, a value, a help tag."""
    said = []
    for window in report.get("windows", []):
        said.append(window.get("title", ""))
        said += window.get("texts", [])
        said += [name for node in window.get("nodes", []) for name in node.get("names", [])]
    return {s for s in secrets if any(s in text for text in said)}


def _connect(ledger: str) -> sqlite3.Connection:
    # Read-only, through a URI: the reader's ledger lives under "Application Support", and a space in
    # a plain path given to `mode=ro` has to be escaped, which `as_uri` does.
    return sqlite3.connect(pathlib.Path(ledger).resolve().as_uri() + "?mode=ro", uri=True)


def _rows(db: sqlite3.Connection, table: str) -> dict:
    """Every row of `table` by id, **every column by name** — `SELECT *`, so a column the schema gains is
    read without anyone remembering to add it. A list of columns missed an event's `before_*` half, its
    scheduler and its retention, and a card's prompt and scheduler (audit-fix round 3, C3)."""
    cursor = db.execute(f"SELECT * FROM {table}")
    names = [column[0] for column in cursor.description]
    return {row["id"]: row for row in (dict(zip(names, values)) for values in cursor)}


def ledger_state(ledger: str) -> dict:
    """Everything a review key could write: the row counts that a lookup or an event would move, and
    every card and every event, voided or not, whole.

    **One read transaction** (audit-fix round 3, #14). Separate statements are separate snapshots, so a
    grade the app committed between them gave a reading whose count of events disagreed with the events
    it listed. The ledger is in WAL mode, so this reader blocks no write: it sees the ledger as it was at
    its first read, whole."""
    db = _connect(ledger)
    try:
        db.execute("BEGIN")
        counts = {table: db.execute(f"SELECT count(*) FROM {table}").fetchone()[0] for table in TABLES}
        cards = _rows(db, "study_cards")
        events = _rows(db, "review_events")
    finally:
        # Ends the read transaction too: nothing was written, so there is nothing to keep.
        db.close()
    return {"counts": counts, "cards": cards, "events": events}


def _moved(before: dict, after: dict) -> str:
    """The columns of one row that differ, as `column: was → now`."""
    return ", ".join(f"{column}: {before.get(column)!r} → {after.get(column)!r}"
                     for column in sorted(before.keys() | after.keys()) if before.get(column) != after.get(column))


def changes(before: dict, after: dict) -> list[str]:
    """What moved between two readings, in words; empty when nothing did.

    **The events too, row by row** (audit-fix round 2, #22). Counts and schedules alone passed a key
    that voided a grade, or rewrote one, with its card left as it was: the row count does not move when
    an event is voided, and nothing here looked at the event itself."""
    found = [f"{table}: {before['counts'].get(table)} rows, now {count}"
             for table, count in after["counts"].items() if count != before["counts"].get(table)]
    for card, row in after["cards"].items():
        if card in before["cards"] and before["cards"][card] != row:
            found.append(f"card {card}: {_moved(before['cards'][card], row)}")
    found += [f"card {card} is new" for card in after["cards"].keys() - before["cards"].keys()]
    found += [f"card {card} is gone" for card in before["cards"].keys() - after["cards"].keys()]
    for event, row in after["events"].items():
        if event in before["events"] and before["events"][event] != row:
            found.append(f"event {event}: {_moved(before['events'][event], row)}")
    found += [f"event {event} is gone" for event in before["events"].keys() - after["events"].keys()]
    found += [f"event {event} is new" for event in after["events"].keys() - before["events"].keys()]
    return found


def new_events(before: dict, after: dict) -> dict:
    """The live events that were not there before, by id: `[card, grade, kind]`."""
    return {event: [row["card_id"], row["grade"], row["kind"]] for event, row in after["events"].items()
            if event not in before["events"] and row["voided_at"] is None}


def next_study_day(at: float) -> float:
    """The next 04:00 local after `at` — where "Not Today" hides a card until."""
    moment = datetime.datetime.fromtimestamp(at)
    start = moment.replace(hour=STUDY_DAY_STARTS, minute=0, second=0, microsecond=0)
    if moment >= start:
        start += datetime.timedelta(days=1)
    return start.timestamp()


# ---------------------------------------------------------------------------------------------
# The drive


class Unreached(Exception):
    """A step the rest of the drive depends on did not happen; what follows cannot be measured."""


class Drive:
    def __init__(self, helpers: str, ledger: str, fixture: str, evidence: str):
        self.helpers, self.ledger = pathlib.Path(helpers), ledger
        self.evidence = pathlib.Path(evidence)
        self.fixture = json.loads(pathlib.Path(fixture).read_text())
        self.cards = {card["word"]: card for card in self.fixture["cards"]}
        self.secrets = [card["answer"] for card in self.fixture["cards"]]
        self.failures = 0

    # --- verdicts

    def say(self, ok: bool, good: str, bad: str) -> bool:
        if ok:
            print(f"PASS\t{good}", flush=True)
        else:
            self.failures += 1
            print(f"FAIL\t{bad}", flush=True)
            self.capture(f"fail-{self.failures}")
        return ok

    def capture(self, name: str) -> None:
        # Evidence for a person, never an assertion: a capture that is refused says nothing about the app.
        subprocess.run(["screencapture", "-x", str(self.evidence / f"{name}.png")],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)

    # --- the helpers

    def helper(self, name: str, *args: str) -> str:
        # A helper that fails says why on its own output; that is what the failure carries.
        done = subprocess.run([str(self.helpers / name), *args], text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=30)
        if done.returncode != 0:
            raise subprocess.SubprocessError(
                f"{name} {' '.join(args)} exited {done.returncode}: {done.stdout.strip()[-300:] or 'nothing'}")
        return done.stdout.strip()

    def frontmost(self) -> str:
        return json.loads(self.helper("on-screen", BUNDLE)).get("frontmost", "")

    def review_drawn(self) -> bool:
        """Drawn by the compositor, not merely listed by Accessibility."""
        return any(m.get("drawn") for m in json.loads(self.helper("on-screen", BUNDLE, "Review")).get("matches", []))

    def panel(self, app: str = BUNDLE) -> dict:
        return json.loads(self.helper("panel", app))

    def snapshot(self, label: str) -> dict:
        """The app's whole accessibility tree, read until one walk finishes.

        **An absence is evidence only from a complete walk.** Straight after a card changes SwiftUI is
        rebuilding the window, and the elements the walk had queued answer AXError -25202 — the tree
        changing under the walk, which is waited out. Anything else incomplete fails, naming why.
        """
        report = {}
        for _ in range(10):
            report = self.panel()
            settling = report["incomplete"] and all("AXError -25202" in why for why in report["incomplete"])
            if report["complete"] or not settling:
                break
            time.sleep(0.5)
        (self.evidence / f"{label}.json").write_text(json.dumps(report, indent=2))
        assert report["complete"], f"the accessibility walk is incomplete ({report.get('incomplete')}); an absence cannot be asserted"
        return report

    def wait(self, seconds: float, condition):
        """Polls `condition` until it is truthy or `seconds` pass; answers its last value and the wait."""
        started = time.monotonic()
        while True:
            value = condition()
            waited = time.monotonic() - started
            if value or waited >= seconds:
                return value, waited
            time.sleep(0.2)

    def card_shown(self, label: str, previous: str | None = None, seconds: float = 10):
        """Waits for the Review window to ask exactly one fixture card other than `previous`; answers
        the report it was read from, the word, and the wait."""
        def asked():
            report = self.snapshot(label)
            window = review_window(report)
            words = words_on(window, WORDS) if window else set()
            if len(words) == 1 and previous not in words:
                return report, words.pop()
            return None
        found, waited = self.wait(seconds, asked)
        return (found[0], found[1], waited) if found else (None, None, waited)

    def showing(self) -> str:
        """Which windows the app has, by title — what a missing card most often turns out to be: the
        window showing another pane, or none."""
        try:
            return ", ".join(repr(w.get("title", "")) for w in self.panel().get("windows", [])) or "no window"
        except (subprocess.SubprocessError, ValueError) as error:
            return f"unreadable ({error})"

    def in_front(self, step: str) -> None:
        """**Never a key for an app that is not in front**: it would go to whatever is."""
        front = self.frontmost()
        if front != BUNDLE:
            raise Unreached(f"{step}: {front or 'nothing'} is in front, so a key would not reach the Review window")

    def key(self, name: str, *extra: str) -> str:
        return self.helper("keys", KEY[name], *extra)

    def bring_library_forward(self) -> tuple[bool, str]:
        """The reader's way to the Library: its item in the menu-bar menu, clicked until it takes."""
        why = ""
        for _ in range(40):
            try:
                self.helper("menu-click", BUNDLE, "Library")
                return True, ""
            except subprocess.SubprocessError as error:
                why = str(error)
                time.sleep(0.25)
        return False, why

    def dictionary_running(self) -> bool:
        # By the executable it was started from, never by name — another process can be called the same.
        table = subprocess.run(["ps", "-axww", "-o", "comm="], text=True, stdout=subprocess.PIPE, check=True).stdout
        return any(line.strip() == DICTIONARY_EXECUTABLE for line in table.splitlines())

    def dictionary_shows(self, word: str) -> bool:
        if self.frontmost() != DICTIONARY:
            return False
        report = self.panel(DICTIONARY)
        return any(word == w.get("title") or word in w.get("texts", []) for w in report.get("windows", []))

    # --- the claims, in the order a reader meets them

    def drive(self) -> None:
        first = self.comes_forward_on_a_card()
        self.explore_before_the_reveal(first)
        baseline = self.reveal(first)
        self.explore_after_the_reveal(first, baseline)
        second = self.grade(first, "1", FORGOT)
        self.reveal(second)
        third = self.grade(second, "2", REMEMBERED)
        fourth = self.held(third)
        fifth = self.skip(fourth)
        self.postpone(fifth)

    def comes_forward_on_a_card(self) -> str:
        # Brought forward by LaunchServices, never by an Apple event: one from this SSH session needs an Automation
        # grant of its own, and asked the first time it raises a prompt nobody is there to answer (2026-10-08).
        subprocess.run(["open", "-a", "Finder"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
        before, _ = self.wait(5, lambda: self.frontmost() == FINDER)
        before = self.frontmost()
        opened, why = self.bring_library_forward()
        forward, waited = self.wait(10, lambda: self.frontmost() == BUNDLE and self.review_drawn())
        self.say(before == FINDER and opened and bool(forward),
                 f"review: choosing the Library brings its window forward on Review over {before}, in {waited:.1f}s",
                 f"review: the Library did not come forward on Review (before: {before}, menu: {why or 'clicked'}, "
                 f"now in front: {self.frontmost()}, Review drawn: {self.review_drawn()})")
        if not forward:
            raise Unreached("the Review window never came forward")
        report, first, waited = self.card_shown("front")
        if first is None:
            raise Unreached(f"no fixture card was asked within {waited:.0f}s")
        leaked = secrets_in(report, self.secrets)
        texts = sum(len(w.get("texts", [])) for w in report["windows"])
        self.say(not leaked,
                 f"review: before the reveal no element holds an answer — {first} asked, {texts} texts in a complete walk",
                 f"review: an answer is in the accessibility tree before the reveal: {sorted(leaked)}, with {first} asked")
        return first

    def explore_before_the_reveal(self, word: str) -> None:
        self.in_front("E before the reveal")
        before, started = ledger_state(self.ledger), self.dictionary_running()
        self.key("e")
        # **A negative, so it is given time to fail.** Dictionary takes a second or two to come up.
        time.sleep(2.5)
        report = self.snapshot("explore-before")
        problems = changes(before, ledger_state(self.ledger))
        front = self.frontmost()
        if front != BUNDLE:
            problems.append(f"{front} came forward")
        if not started and self.dictionary_running():
            problems.append("Dictionary was started")
        if secrets_in(report, self.secrets):
            problems.append("an answer appeared")
        self.say(not problems, f"review: E before the reveal opens nothing and writes nothing ({word} still asked)",
                 f"review: E before the reveal did something: {problems}")
        if front != BUNDLE:
            raise Unreached("E before the reveal took XiaolaiDict out of the front")

    def reveal(self, word: str) -> dict:
        answer = self.cards[word]["answer"]
        self.in_front(f"Space on {word}")
        before = ledger_state(self.ledger)
        self.key("space")
        def shown():
            report = self.snapshot(f"reveal-{word}")
            return report if answer in secrets_in(report, [answer]) else None
        report, waited = self.wait(5, shown)
        others = secrets_in(report, self.secrets) - {answer} if report else set()
        self.say(bool(report) and not others,
                 f"review: Space reveals {word}'s answer into the accessibility tree in {waited:.1f}s, and no other card's",
                 f"review: Space did not reveal {word}'s answer alone within {waited:.0f}s (others shown: {sorted(others)})")
        moved = changes(before, ledger_state(self.ledger))
        self.say(not moved, f"review: revealing {word} wrote nothing — a reveal is not a grade",
                 f"review: revealing {word} wrote to the ledger: {moved}")
        if not report:
            raise Unreached(f"{word}'s answer was never shown")
        return before

    def explore_after_the_reveal(self, word: str, baseline: dict) -> None:
        self.in_front(f"E on {word}")
        self.key("e")
        opened, waited = self.wait(10, lambda: self.dictionary_shows(word))
        self.say(bool(opened), f"review: E opens {word} in Dictionary, in front after {waited:.1f}s",
                 f"review: E did not open {word} in Dictionary within {waited:.0f}s (in front: {self.frontmost()})")
        time.sleep(1.0)
        moved = changes(baseline, ledger_state(self.ledger))
        if opened:
            self.say(not moved,
                     "review: opening Dictionary wrote nothing — no lookup, no review event, every schedule as it was",
                     f"review: opening Dictionary from a review card wrote to the ledger: {moved}")
        else:
            self.say(False, "", "review: that E writes nothing is unmeasured, because Dictionary never opened")
        # Back the way a reader comes back: the Library from the menu bar.
        back, why = self.bring_library_forward()
        front, _ = self.wait(10, lambda: self.frontmost() == BUNDLE)
        if not (back and front):
            raise Unreached(f"XiaolaiDict did not come back in front after Dictionary ({why or self.frontmost()})")
        report, still, _ = self.card_shown("back-from-dictionary")
        if still != word or self.cards[word]["answer"] not in secrets_in(report, self.secrets):
            raise Unreached(f"after Dictionary the Review window asks {still}, not {word} with its answer")

    def grade(self, word: str, key: str, expected: int) -> str:
        card = self.cards[word]["card"]
        self.in_front(f"{key} on {word}")
        before = ledger_state(self.ledger)
        self.key(key)
        # **This grade's own row**, by the card it was for — never "the count went up", which any
        # write would satisfy — and the wait is said, so it stays a number rather than a bound.
        events, waited = self.wait(10, lambda: new_events(before, ledger_state(self.ledger)))
        mine = [row for row in (events or {}).values() if row[0] == card]
        self.say(len(events or {}) == 1 and len(mine) == 1 and mine[0][1] == expected and mine[0][2] == "graded",
                 f"review: {key} grades {word} — its own event, grade {expected}, written {waited:.1f}s after the key",
                 f"review: {key} on {word} wrote {events or 'nothing'} in {waited:.1f}s, wanted one grade-{expected} event for card {card}")
        # Then the sitting moves on — watched for separately, because it lands on a later await.
        _, following, waited = self.card_shown(f"after-{word}", previous=word)
        if following is None:
            raise Unreached(f"after {word} was graded no other card was asked within {waited:.0f}s (showing: {self.showing()})")
        return following

    def held(self, word: str) -> str:
        card = self.cards[word]["card"]
        self.in_front(f"holding 2 on {word}")
        before = ledger_state(self.ledger)
        # **Watched while the key is held, not after.** `keys --hold` returns only once the key is up
        # and its tail has passed, so a wait begun then reads 0.0 for any grade written during the
        # hold. The helper runs beside the wait instead.
        #
        # **And timed by the two instants themselves, not by this process's clock** (audit-fix round 1,
        # #31). A wait started once the helper was launched read a grade already written as 0.0
        # whenever this process was delayed between the launch and its first poll. So the figure is the
        # event's own `reviewed_at` — the app's instant for the grade — less the instant the helper
        # posted the key down (`downAt`, the same Mac's clock): no delay on this side can move it, and
        # a grade stamped before the key went down is not one this key made.
        holding = subprocess.Popen([str(self.helpers / "keys"), KEY["2"], "--hold", HOLD_SECONDS],
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            self.wait(10, lambda: new_events(before, ledger_state(self.ledger)))
            output, _ = holding.communicate(timeout=30)
        finally:
            if holding.poll() is None:
                holding.kill()
                holding.wait()
        if holding.returncode != 0:
            raise subprocess.SubprocessError(
                f"keys {KEY['2']} --hold {HOLD_SECONDS} exited {holding.returncode}: {output.strip()[-300:] or 'nothing'}")
        posted = json.loads(output.strip())
        # Required, never defaulted: without it the line below would have no instant to count from.
        down_at = float(posted["downAt"])
        _, following, _ = self.card_shown(f"after-held-{word}", previous=word)
        # **A negative, given time to fail**: the repeats were posted while the key was down, and any
        # that reached the next card have landed by now.
        time.sleep(2.0)
        after = ledger_state(self.ledger)
        final = new_events(before, after)
        mine = [event for event, row in final.items() if row[0] == card]
        stamped = after["events"][mine[0]]["reviewed_at"] - down_at if len(mine) == 1 else None
        repeats, seen = posted.get("repeats", 0), posted.get("seenRepeats")
        # **The positive control: the repeats existed.** Without it, a hold that posted none — or whose
        # repeats were delivered as nothing — passes this check by never testing it.
        self.say(repeats >= 5 and seen is not None and seen >= 5,
                 f"review: holding 2 for {HOLD_SECONDS}s posted {repeats} key repeats, and {seen} were seen as repeats",
                 f"review: the hold is no test of key repeat — {repeats} repeats posted, "
                 f"{'none could be observed' if seen is None else f'{seen} seen as repeats'}")
        self.say(len(final) == 1 and len(mine) == 1 and final[mine[0]][1] == REMEMBERED
                 and stamped is not None and stamped >= 0,
                 f"review: a held 2 grades once — {word}, written {stamped:.1f}s after the key went down "
                 f"by its own instant, and not {following}" if stamped is not None else "",
                 f"review: a held 2 wrote {len(final)} event(s), wanted one for {word} stamped after the key "
                 f"went down ({'no instant' if stamped is None else f'{stamped:.2f}s'}): {final}")
        if following is None:
            raise Unreached(f"after the held key no card other than {word} was asked (showing: {self.showing()})")
        return following

    def skip(self, word: str) -> str:
        self.in_front(f"S on {word}")
        before = ledger_state(self.ledger)
        self.key("s")
        _, following, waited = self.card_shown(f"after-skip-{word}", previous=word)
        moved = changes(before, ledger_state(self.ledger))
        where = "" if following else f" (showing: {self.showing()})"
        self.say(following is not None and not moved,
                 f"review: S skips {word} — {following} is asked {waited:.1f}s later, and {word} has no event and the same schedule",
                 f"review: S on {word}: next card {following}, ledger changes {moved}{where}")
        if following is None:
            raise Unreached(f"S did not move the sitting past {word}")
        return following

    def postpone(self, word: str) -> None:
        card = self.cards[word]["card"]
        self.in_front(f"T on {word}")
        before = ledger_state(self.ledger)
        pressed = time.time()
        self.key("t")
        # **This card's own row**: the moment its `hidden_until` is written.
        after, waited = self.wait(10, lambda: (lambda s: s if s["cards"][card]["hidden_until"] is not None else None)(
            ledger_state(self.ledger)))
        if not after:
            self.say(False, "", f"review: T on {word} hid nothing within {waited:.0f}s")
            return
        until = after["cards"][card]["hidden_until"]
        tomorrow = next_study_day(pressed)
        moved = [column for column in CARD_COLUMNS if column not in ("hidden_until", "revision")
                 and before["cards"][card][column] != after["cards"][card][column]]
        events = new_events(before, after)
        self.say(abs(until - tomorrow) < 2 and not moved and not events,
                 f"review: T puts {word} off until {datetime.datetime.fromtimestamp(until):%Y-%m-%d %H:%M} — "
                 f"the next study day, written {waited:.1f}s after the key, no event and the schedule untouched",
                 f"review: T on {word}: hidden until {until} against the next study day {tomorrow}, "
                 f"schedule fields moved {moved}, events {events}")


def run(helpers: str, ledger: str, fixture: str, evidence: str) -> int:
    drive = Drive(helpers, ledger, fixture, evidence)
    try:
        drive.drive()
    except Unreached as reason:
        drive.say(False, "", f"review: the drive stopped — {reason}; every claim after it is unmeasured")
    except (AssertionError, subprocess.SubprocessError, ValueError, KeyError) as error:
        drive.say(False, "", f"review: the drive failed — {type(error).__name__}: {error}")
    print("DONE", flush=True)
    return 1 if drive.failures else 0


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "seed":
        seed(sys.argv[2], sys.argv[3], sys.argv[4])
    elif len(sys.argv) == 6 and sys.argv[1] == "run":
        sys.exit(run(*sys.argv[2:]))
    else:
        raise SystemExit("usage: review.py seed <isolated-ledger> <dictionary> <fixture.json> | "
                         "run <helpers> <ledger> <fixture.json> <evidence>")
