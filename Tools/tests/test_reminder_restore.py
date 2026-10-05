"""The `reminder` stage's restore, run exactly as `Tools/e2e.sh` writes it, against a stand-in app.

`restore_reminder_fixture` is what puts the reader's ledger, preferences and notification requests back
after the stage — on its own way out, and from `at_exit` when the stage dies. It runs only on the E2E
Mac, where the notification grant is `notAsked` and nothing is ever pending, so its paths for a Mac
where a person gave the grant never run there. These run them, with every command that could reach
this Mac's real app — `open`, `defaults`, the report, stopping the app — replaced by a recorder:

- **#29: whatever turned reminders on is taken back**, whether or not the phase's report was written.
  The restore used to decide by the `on` phase's report, so a stage interrupted after its launch had
  added requests and before the report was written left them pending on the reader's Mac.
- **#28: the reader's own pending requests are proved still there, never regenerated.** The stage's
  launches used to remove them, and the restore opened those days again in the reader's log for the app
  to plan anew — at whatever instant it chose now, which for a request planned in another zone was not
  the one the reader had. The stage now leaves them alone (`test_fixture_restore`), and the restore
  fails, writing nothing, when one is not pending at its own instant.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import json
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import time
import unittest

from ledger_schema import REPO

SCRIPT = REPO / "Tools" / "e2e.sh"
HELPER = REPO / "Tools" / "e2e" / "reminder.py"
PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
FIRST = "review.2026-10-05"


def function(name: str) -> str:
    """One shell function, as `e2e.sh` defines it: from `name() {` to the first line that is `}`."""
    found = re.search(rf"^{name}\(\) {{.*?^}}$", SCRIPT.read_text(), re.MULTILINE | re.DOTALL)
    assert found, f"e2e.sh defines no {name}()"
    return found.group(0)


# `defaults export`, as `reminder.py wait` runs it: the plist the test put in STUB_EXPORT.
DEFAULTS = """#!/bin/bash
echo "defaults-binary $*" >> "$CALLS"
[ "$1" = export ] && cat "$STUB_EXPORT"
exit 0
"""


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.scratch.name)
        self.root = root
        self.evidence = root / "reminder-evidence"
        self.evidence.mkdir()
        self.helpers = root / "e2e"
        self.helpers.mkdir()
        shutil.copy(HELPER, self.helpers / "reminder.py")
        self.stubs = root / "stubs"
        self.stubs.mkdir()
        tool = self.stubs / "defaults"
        tool.write_text(DEFAULTS)
        tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
        self.reports = root / "reports"
        self.reports.mkdir()
        self.calls = root / "calls.txt"
        self.calls.write_text("")
        self.soon = time.time() + 3_600
        # The reader's own log: today's reminder added, yesterday's long gone.
        self.reader_log = {"entries": [
            {"day": "2026-10-05", "kind": "daily", "state": "added", "fireAt": self.soon,
             "content": {"case": "sittingReady", "predictedCount": 3}},
            {"day": "2026-10-04", "kind": "daily", "state": "gone"},
        ], "later": []}
        (self.evidence / "preferences.plist").write_bytes(plistlib.dumps(
            {"reviewReminderLog": json.dumps(self.reader_log).encode(), "PrimaryDictionary": "noad"}))
        self.export(FIRST, "withdrawn")

    def tearDown(self):
        self.scratch.cleanup()

    def export(self, identifier: str, state: str) -> None:
        """What `defaults export` answers while the restore waits for a state in the log."""
        day = identifier.removeprefix("review.")
        log = {"entries": [{"day": day, "kind": "daily", "state": state, "reason": "disabled",
                            "fireAt": self.soon, "content": {"case": "sittingReady"}}], "later": []}
        (self.root / "export.plist").write_bytes(plistlib.dumps({"reviewReminderLog": json.dumps(log).encode()}))

    def reader_had(self, *pending) -> None:
        (self.evidence / "reader.json").write_text(json.dumps(
            {"grant": "granted", "pending": [{"id": i, "fireAt": at} for i, at in pending]}))

    def reports_answer(self, *answers) -> None:
        """What each `--reminder-report` run says, in turn: the requests pending at that point."""
        for index, pending in enumerate(answers):
            (self.reports / f"{index:02d}.json").write_text(json.dumps(
                {"grant": "granted", "pending": [{"id": i, "fireAt": at} for i, at in pending]}))

    def restore(self, activated: bool) -> subprocess.CompletedProcess:
        script = "\n".join([
            "set -uo pipefail",
            # The recorder: nothing reaches this Mac's app or its preferences.
            'stop_app() { echo "stop_app" >> "$CALLS"; }',
            'open() { echo "open $*" >> "$CALLS"; }',
            # A deleted domain exports as an empty dictionary, as the real one does (`domain_cleared`).
            'defaults() { echo "defaults $*" >> "$CALLS"; [ "$1" = export ] '
            '&& printf \'<?xml version="1.0" encoding="UTF-8"?>\\n<plist version="1.0"><dict/></plist>\\n\'; return 0; }',
            'run_report() { echo "run_report $*" >> "$CALLS"; local next; '
            'next=$(ls "$REPORTS" | head -1); [ -n "$next" ] || return 0; '
            'cat "$REPORTS/$next"; rm -f "$REPORTS/$next"; }',
            f'helpers="{self.helpers}"',
            f'app="{self.root}/XiaolaiDict.app"',
            f'ledger="{self.root}/ledger.sqlite"',
            f'reminder_evidence="{self.evidence}"',
            f'reminder_first="{FIRST}"',
            "reminder_hour=19",
            "reminder_had_ledger=no",
            "reminder_restored=no",
            f"reminder_activated={'yes' if activated else 'no'}",
            function("reminder_settings"),
            function("reminder_pending"),
            function("reader_reminders_back"),
            function("domain_cleared"),
            function("restore_reminder_fixture"),
            'restore_reminder_fixture; status=$?; echo "restore exited $status" >> "$CALLS"; exit $status',
        ])
        env = {"PATH": f"{self.stubs}:{PATH}", "CALLS": str(self.calls), "REPORTS": str(self.reports),
               "STUB_EXPORT": str(self.root / "export.plist"), "HOME": str(self.root)}
        return subprocess.run(["bash", "-c", script], text=True, capture_output=True, env=env,
                              check=False, timeout=120)

    def recorded(self) -> list[str]:
        return self.calls.read_text().splitlines()

    def index(self, calls: list[str], prefix: str) -> int:
        return next(i for i, call in enumerate(calls) if call.startswith(prefix))

    # --- #29: what the stage turned on is taken back

    def test_requests_added_before_the_on_report_was_written_are_taken_back(self):
        """Interrupted after the on phase's launch and before its report: no `on.json` at all."""
        self.reader_had()
        self.reports_answer([(FIRST, self.soon + 7_200)], [])
        done = self.restore(activated=True)
        calls = self.recorded()
        self.assertEqual(done.returncode, 0, done.stderr + "\n".join(calls))
        self.assertTrue(any(c.startswith("defaults write com.xiaolaidict reviewReminderSettings") for c in calls),
                        calls)
        withdrawn = self.index(calls, "open ")
        self.assertLess(withdrawn, self.index(calls, "defaults import"),
                        "the stage's requests were not withdrawn by the app before the reader's settings came back")
        self.assertEqual(json.loads((self.evidence / "restore.json").read_text())["pending"], [])

    def test_requests_still_pending_after_the_withdrawal_fail_the_restore(self):
        self.reader_had()
        self.reports_answer([(FIRST, self.soon + 7_200)], [(FIRST, self.soon + 7_200)])
        done = self.restore(activated=True)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("still pending", done.stderr)
        self.assertFalse(any(c.startswith("defaults import") for c in self.recorded()),
                         "the reader's preferences went back over a request this stage left pending")

    def test_an_unreadable_report_is_withdrawn_through_the_app_too(self):
        """A report that says nothing is no evidence that nothing is pending."""
        self.reader_had()
        self.reports_answer()
        done = self.restore(activated=True)
        self.assertNotEqual(done.returncode, 0, "an unreadable report let the restore through")
        self.assertTrue(any(c.startswith("open ") for c in self.recorded()), self.recorded())

    def test_a_stage_that_never_turned_reminders_on_launches_nothing_to_withdraw(self):
        self.reader_had()
        done = self.restore(activated=False)
        calls = self.recorded()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([c for c in calls if c.startswith(("open ", "run_report"))], [f"open {self.root}/XiaolaiDict.app"])

    # --- #28: the reader's own pending requests are checked, never regenerated

    def test_a_readers_request_that_is_gone_fails_the_restore_and_writes_nothing(self):
        self.reader_had((FIRST, self.soon))
        self.export(FIRST, "added")
        self.reports_answer([])
        done = self.restore(activated=False)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("no longer pending", done.stderr)
        calls = self.recorded()
        self.assertFalse(any("reviewReminderLog" in c for c in calls), calls)
        self.assertFalse(any(c.startswith("open ") for c in calls),
                         "the app was opened to plan the reader's request again")

    def test_a_readers_request_still_pending_is_left_alone(self):
        self.reader_had((FIRST, self.soon))
        self.reports_answer([(FIRST, self.soon)])
        done = self.restore(activated=False)
        calls = self.recorded()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(any("reviewReminderLog" in c for c in calls), calls)


if __name__ == "__main__":
    unittest.main()
