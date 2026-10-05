"""The three stages that swap the reader's ledger for a fixture, run as `Tools/e2e.sh` writes them.

`learning`, `review` and `reminder` set the reader's ledger and preferences aside, launch the app on a
ledger of their own, and put both back — at the end of the stage, and again from `on_exit` when the
stage dies first. Their restorers are read out of the script and run in bash against a stand-in app:
every command that could reach this Mac's real app or its preferences (`open`, `defaults`, the report,
stopping the app) is a recorder, and the ledger is a file in a scratch directory.

- **A backup outlives every step it could be needed for** (audit-fix round 2, #21). Each restorer
  deleted its ledger backup straight after putting the ledger back, before the preferences and the
  reminders; a later step that failed left the retry from `on_exit` failing at `cp` on a file it had
  removed itself, so a restore that one retry would have finished could never finish.
- **The reader's reminders are left alone, and that is checked** (audit-fix round 2, #20). The app
  re-plans its reminders at every launch from the ledger it opens and the settings in its domain, and
  the notification center it changes is the app's, not the ledger's: a fixture launched with the
  reader's settings on removed their pending requests. Every swapping stage now takes the reminder
  settings and log out of the domain before its first launch — off with no log touches nothing — and
  its restore fails unless what the reader had pending is pending again at its own instant.
- **The reminder stage does not clobber what it cannot put back** (audit-fix round 1, #28). Only the
  app's process can add a request, and it adds what it plans now — so a request the reader had, planned
  in another zone, came back at another instant. With the reader's own requests pending, the stage runs
  its `off` phase alone and says why the rest is not run.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import time
import unittest

from ledger_schema import REPO

SCRIPT = REPO / "Tools" / "e2e.sh"
HELPER = REPO / "Tools" / "e2e" / "reminder.py"
PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
STAGES = ("learning", "review", "reminder")


def text() -> str:
    return SCRIPT.read_text()


def function(name: str) -> str:
    """One shell function, as `e2e.sh` defines it: from `name() {` to the first line that is `}`."""
    found = re.search(rf"^{name}\(\) {{.*?^}}$", text(), re.MULTILINE | re.DOTALL)
    assert found, f"e2e.sh defines no {name}()"
    return found.group(0)


def stage(name: str) -> str:
    """One stage's block: from `if want <name>; then` to the next stage's."""
    found = re.search(rf"^if want {name}; then\n(.*?)(?=^if want )", text(), re.MULTILINE | re.DOTALL)
    assert found, f"e2e.sh has no {name} stage"
    return found.group(1)


# The recorder. Nothing reaches this Mac's app or its preferences; `defaults import` fails once where
# the test asks it to, and `run_report` answers the reports the test queued, in turn.
STUBS = r"""
set -uo pipefail
stop_app() { echo "stop_app" >> "$CALLS"; }
open() { echo "open $*" >> "$CALLS"; }
osascript() { echo "osascript $*" >> "$CALLS"; }
plutil() { echo "plutil $*" >> "$CALLS"; }
defaults() {
    echo "defaults $*" >> "$CALLS"
    if [ "$1" = import ] && [ -e "$FAIL_IMPORT" ]; then rm -f "$FAIL_IMPORT"; return 1; fi
    # A deleted domain exports as an empty dictionary, as the real one does; one the delete did not
    # clear still holds a key, and an export can fail outright.
    if [ "$1" = export ]; then
        [ -e "$EXPORT_FAILS" ] && return 1
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">'
        if [ -e "$STILL_THERE" ]; then printf '<dict><key>TextSize</key><string>huge</string></dict>'; else printf '<dict/>'; fi
        printf '</plist>\n'
        return 0
    fi
    if [ "$1" = read ] && [ -e "$STILL_THERE" ]; then return 0; fi
    [ "$1" = read ] && return 1
    return 0
}
run_report() {
    echo "run_report $*" >> "$CALLS"
    local next
    next=$(ls "$REPORTS" | head -1)
    [ -n "$next" ] || return 1
    cat "$REPORTS/$next"; rm -f "$REPORTS/$next"
}
# A ledger's fingerprint, by its bytes: the restore compares copies, and these are plain files.
ledger_digest() { shasum -a 256 < "$1" | cut -d' ' -f1; }
"""


class Scratch(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        self.helpers = self.root / "e2e"
        self.helpers.mkdir()
        shutil.copy(HELPER, self.helpers / "reminder.py")
        self.reports = self.root / "reports"
        self.reports.mkdir()
        self.calls = self.root / "calls.txt"
        self.calls.write_text("")
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        (self.evidence / "preferences.plist").write_text("stand-in")
        support = self.root / "Application Support"
        support.mkdir()
        self.ledger = support / "ledger.sqlite"
        self.backup = self.evidence / "original-backup.sqlite"
        self.soon = time.time() + 3_600

    def tearDown(self):
        self.scratch.cleanup()

    def reader_had(self, *pending) -> None:
        (self.evidence / "reader.json").write_text(json.dumps(
            {"grant": "granted", "pending": [{"id": i, "fireAt": at} for i, at in pending]}))

    def reports_answer(self, *answers) -> None:
        for index, pending in enumerate(answers):
            (self.reports / f"{index:02d}.json").write_text(json.dumps(
                {"grant": "granted", "pending": [{"id": i, "fireAt": at} for i, at in pending]}))

    def bash(self, body: str, **flags: bool) -> subprocess.CompletedProcess:
        env = {"PATH": PATH, "CALLS": str(self.calls), "REPORTS": str(self.reports), "HOME": str(self.root),
               "FAIL_IMPORT": str(self.root / "fail-import"), "STILL_THERE": str(self.root / "still-there"),
               "EXPORT_FAILS": str(self.root / "export-fails")}
        for flag, wanted in flags.items():
            if wanted:
                (self.root / flag.replace("_", "-")).write_text("")
        return subprocess.run(["bash", "-c", STUBS + body], text=True, capture_output=True, env=env,
                              check=False, timeout=120)

    def recorded(self) -> list[str]:
        return self.calls.read_text().splitlines()


class RestorerScript:
    """The shell that defines one stage's restorer over a ledger the test made, and calls it."""

    def __init__(self, test: Scratch, name: str):
        self.test, self.name = test, name

    def prelude(self) -> str:
        t, name = self.test, self.name
        lines = [
            f'helpers="{t.helpers}"', f'app="{t.root}/XiaolaiDict.app"', f'ledger="{t.ledger}"',
            f'{name}_evidence="{t.evidence}"', f'{name}_backup="{t.backup}"', f"{name}_had_ledger=yes",
            f"{name}_restored=no", f'{name}_digest=$(ledger_digest "{t.backup}")',
        ]
        if name == "learning":
            lines.append("learning_dark_before=''")
        if name == "reminder":
            lines += ["reminder_activated=no", "reminder_first=review.2026-10-05", "reminder_hour=19",
                      function("reminder_settings")]
        for helper in ("reminder_pending", "reader_reminders_back", "domain_cleared", f"restore_{name}_fixture"):
            # Read only where defined, so the backup tests measure a restorer that predates the check.
            # `ReadersRemindersAreCheckedTests` is what requires it.
            if re.search(rf"^{helper}\(\) {{", text(), re.MULTILINE):
                lines.append(function(helper))
        return "\n".join(lines)

    def twice(self) -> str:
        restore = f"restore_{self.name}_fixture"
        return "\n".join([
            self.prelude(),
            f'{restore}; echo "first $?" >> "$CALLS"',
            f'[ -e "{self.test.backup}" ] && echo "backup kept" >> "$CALLS"',
            f'{restore}; echo "second $?" >> "$CALLS"',
            f'[ -e "{self.test.backup}" ] || echo "backup removed" >> "$CALLS"',
        ])

    def once(self) -> str:
        return "\n".join([self.prelude(), f"restore_{self.name}_fixture"])


class BackupOutlivesTheRestoreTests(Scratch):
    """#21: the retry from `on_exit` finishes a restore that failed after the ledger was back."""

    def setUp(self):
        super().setUp()
        self.backup.write_bytes(b"the reader's own ledger")
        self.ledger.write_bytes(b"the stage's fixture")
        self.reader_had()

    def check(self, name: str) -> None:
        done = self.bash(RestorerScript(self, name).twice(), fail_import=True)
        calls = self.recorded()
        self.assertIn("first 1", calls, f"{name}: the first restore should fail at the import\n{done.stderr}")
        self.assertIn("backup kept", calls,
                      f"{name}: the backup was deleted before the restore had succeeded\n{done.stderr}")
        self.assertIn("second 0", calls, f"{name}: the retry could not finish the restore\n{done.stderr}")
        self.assertIn("backup removed", calls, f"{name}: a finished restore left its backup behind")
        self.assertEqual(self.ledger.read_bytes(), b"the reader's own ledger")

    def test_the_learning_restore_keeps_its_backup_until_it_has_finished(self):
        self.check("learning")

    def test_the_review_restore_keeps_its_backup_until_it_has_finished(self):
        self.check("review")

    def test_the_reminder_restore_keeps_its_backup_until_it_has_finished(self):
        self.check("reminder")


class ReadersRemindersAreCheckedTests(Scratch):
    """#20: whatever a swapping stage launched, the reader's pending requests are proved still there."""

    FIRST = "review.2026-10-05"

    def setUp(self):
        super().setUp()
        self.backup.write_bytes(b"the reader's own ledger")
        self.ledger.write_bytes(b"the stage's fixture")

    def test_a_readers_request_gone_after_the_stage_fails_its_restore(self):
        for name in STAGES:
            with self.subTest(stage=name):
                self.calls.write_text("")
                self.reader_had((self.FIRST, self.soon))
                self.reports_answer([])
                done = self.bash(RestorerScript(self, name).once())
                self.assertNotEqual(done.returncode, 0, f"{name}: a reader's request went missing unremarked")
                self.assertIn("no longer pending", done.stderr)
                self.assertFalse(any(c.startswith("defaults write") for c in self.recorded()),
                                 f"{name}: the restore wrote the reader's reminder log: {self.recorded()}")

    def test_a_readers_request_still_pending_passes_its_restore(self):
        for name in STAGES:
            with self.subTest(stage=name):
                self.calls.write_text("")
                self.backup.write_bytes(b"the reader's own ledger")
                self.reader_had((self.FIRST, self.soon))
                self.reports_answer([(self.FIRST, self.soon)])
                done = self.bash(RestorerScript(self, name).once())
                self.assertEqual(done.returncode, 0, f"{name}: {done.stderr}")
                calls = self.recorded()
                # Checked with the app stopped and the reader's settings back, before the app is opened:
                # what is pending then is what the stage left, not what the app has since re-planned.
                self.assertLess(next(i for i, c in enumerate(calls) if c.startswith("defaults import")),
                                next(i for i, c in enumerate(calls) if c.startswith("run_report")))
                self.assertLess(next(i for i, c in enumerate(calls) if c.startswith("run_report")),
                                next(i for i, c in enumerate(calls) if c.startswith("open ")))

    def test_a_reader_with_nothing_pending_costs_no_report(self):
        for name in STAGES:
            with self.subTest(stage=name):
                self.calls.write_text("")
                self.backup.write_bytes(b"the reader's own ledger")
                self.reader_had()
                done = self.bash(RestorerScript(self, name).once())
                self.assertEqual(done.returncode, 0, f"{name}: {done.stderr}")
                self.assertFalse(any(c.startswith("run_report") for c in self.recorded()), self.recorded())


class DomainClearedBeforeImportTests(Scratch):
    """Round 3, #12: a domain the delete did not clear is never merged into.

    `defaults import` merges, which is why every restorer deletes the domain first — and the delete's
    status was thrown away (`|| true`), because it exits 1 for a domain that is not there. So a delete
    that changed nothing let the import merge the reader's export over the fixture's keys and report
    success. A read's status says nothing either — `defaults read` of a deleted domain exits 0 and prints
    `{}` (measured 2026-10-05) — so the keys left are counted from the domain's export.
    """

    def setUp(self):
        super().setUp()
        self.reader_had()

    def test_a_domain_still_there_after_the_delete_fails_before_the_import(self):
        for name in STAGES:
            with self.subTest(stage=name):
                self.calls.write_text("")
                self.backup.write_bytes(b"the reader's own ledger")
                done = self.bash(RestorerScript(self, name).once(), still_there=True)
                calls = self.recorded()
                self.assertNotEqual(done.returncode, 0,
                                    f"{name}: a domain still holding the fixture's keys was merged into: {calls}")
                self.assertFalse(any(c.startswith("defaults import") for c in calls),
                                 f"{name}: imported over a domain that was not cleared: {calls}")
                self.assertIn("still", done.stderr)

    def test_an_export_that_cannot_be_read_fails_before_the_import(self):
        for name in STAGES:
            with self.subTest(stage=name):
                self.calls.write_text("")
                self.backup.write_bytes(b"the reader's own ledger")
                done = self.bash(RestorerScript(self, name).once(), export_fails=True)
                calls = self.recorded()
                self.assertNotEqual(done.returncode, 0, f"{name}: an unread domain was taken for an empty one")
                self.assertFalse(any(c.startswith("defaults import") for c in calls), calls)
                self.assertIn("unreadable", done.stderr)

    def test_an_emptied_domain_is_counted_between_the_delete_and_the_import(self):
        """The positive control: a cleared domain passes, and is counted before anything is imported."""
        for name in STAGES:
            with self.subTest(stage=name):
                self.calls.write_text("")
                self.backup.write_bytes(b"the reader's own ledger")
                done = self.bash(RestorerScript(self, name).once())
                self.assertEqual(done.returncode, 0, f"{name}: {done.stderr}")
                calls = self.recorded()
                delete = calls.index("defaults delete com.xiaolaidict")
                counted = calls.index("defaults export com.xiaolaidict -")
                imported = next(i for i, c in enumerate(calls) if c.startswith("defaults import"))
                self.assertLess(delete, counted, calls)
                self.assertLess(counted, imported, calls)


class RemindersSetAsideTests(Scratch):
    """#20: every swapping stage launches its fixture with reminders off and no log."""

    def test_both_keys_are_taken_out_and_read_back(self):
        done = self.bash(function("reminders_set_aside") + "\nreminders_set_aside")
        self.assertEqual(done.returncode, 0, done.stderr)
        calls = self.recorded()
        for key in ("reviewReminderSettings", "reviewReminderLog"):
            self.assertIn(f"defaults delete com.xiaolaidict {key}", calls)
            self.assertIn(f"defaults read com.xiaolaidict {key}", calls)

    def test_a_key_still_there_fails(self):
        done = self.bash(function("reminders_set_aside") + "\nreminders_set_aside", still_there=True)
        self.assertNotEqual(done.returncode, 0, "a key that reads back was taken for one set aside")

    def test_every_swapping_stage_sets_them_aside_before_its_first_launch(self):
        for name in STAGES:
            with self.subTest(stage=name):
                block = stage(name)
                launch = re.search(r'^open "\$app"$', block, re.MULTILINE)
                self.assertIsNotNone(launch, f"{name}: no fixture launch found")
                before = block[:launch.start()]
                aside = before.rfind("reminders_set_aside")
                self.assertGreater(aside, -1, f"{name}: the fixture is launched with the reader's reminders on")
                self.assertGreater(before.rfind("at_exit restore_"), -1)
                self.assertLess(before.rfind("at_exit restore_"), aside,
                                f"{name}: the keys go before a restorer that would bring them back is registered")
                read = before.find("reader_reminders ")
                self.assertGreater(read, -1, f"{name}: what the reader had pending is never read")
                self.assertLess(read, aside, f"{name}: read after the reader's settings were taken away")


class ReminderPhasesTests(Scratch):
    """#28: with the reader's own requests pending, the reminder stage turns nothing on."""

    def phases(self) -> str:
        done = self.bash("\n".join([function("reminder_pending"), function("reminder_phases"),
                                    f'reminder_phases "{self.evidence / "reader.json"}"']))
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.strip()

    def test_nothing_pending_runs_every_phase(self):
        self.reader_had()
        self.assertEqual(self.phases(), "off on disabled")

    def test_the_readers_own_pending_runs_off_alone(self):
        self.reader_had(("review.2026-10-05", self.soon))
        self.assertEqual(self.phases(), "off")

    def test_the_stage_says_what_it_did_not_run_and_runs_the_phases_it_was_given(self):
        block = stage("reminder")
        self.assertIn('for reminder_phase in $reminder_run; do', block)
        self.assertRegex(block, r'reminder_run=\$\(reminder_phases "\$reminder_evidence/reader.json"\)')
        self.assertRegex(block, r"NOT RUN  reminder: the on phase")
        self.assertRegex(block, r"NOT RUN  reminder: the disabled phase")

    def off_verdict(self, reader: list, pending: list) -> str:
        """The stage's own validator for its `off` phase, read out of the script and run on a report."""
        body = re.search(r"<<'PYREMINDER'[^\n]*\n(.*?)\nPYREMINDER\n", text(), re.S).group(1)
        (self.evidence / "reader.json").write_text(json.dumps(
            {"pending": [{"id": i, "fireAt": at} for i, at in reader]}))
        (self.evidence / "off.json").write_text(json.dumps(
            {"grant": "granted", "enabled": False, "planned": [],
             "pending": [{"id": i, "fireAt": at} for i, at in pending]}))
        (self.evidence / "expect.json").write_text(json.dumps({"id": "review.2026-10-05", "fireAt": 1}))
        done = subprocess.run(["python3", "-", "off", str(self.evidence / "off.json"),
                               str(self.evidence / "expect.json"), "8", str(self.evidence / "reader.json")],
                              input=body, text=True, capture_output=True, check=False, timeout=60)
        self.assertIn("DONE", done.stdout, done.stderr)
        return next(line for line in done.stdout.splitlines() if "off, " in line and "pending" in line)

    def test_off_with_nothing_pending_passes(self):
        self.assertTrue(self.off_verdict([], []).startswith("PASS"))

    def test_off_beside_the_readers_own_passes_and_names_them(self):
        """The `off` phase still runs with the reader's own pending; theirs are not the stage's."""
        line = self.off_verdict([("review.2026-10-05", self.soon)], [("review.2026-10-05", self.soon)])
        self.assertTrue(line.startswith("PASS"), line)
        self.assertIn("the reader's own 1", line)

    def test_off_with_anything_beside_the_readers_own_fails(self):
        self.assertTrue(self.off_verdict([], [("review.2026-10-05", self.soon)]).startswith("FAIL"))
        self.assertTrue(self.off_verdict([("review.2026-10-05", self.soon)],
                                         [("review.2026-10-05", self.soon + 60)]).startswith("FAIL"))

    def test_off_with_one_of_the_readers_own_gone_fails(self):
        self.assertTrue(self.off_verdict([("review.2026-10-05", self.soon)], []).startswith("FAIL"))

    def test_nothing_reopens_the_readers_log(self):
        self.assertNotIn("reminder.py\" reopen", text())
        self.assertNotIn("def reopened", HELPER.read_text())


if __name__ == "__main__":
    unittest.main()
