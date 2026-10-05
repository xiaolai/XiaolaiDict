"""The reminder stage's helper: the settings it writes, the reminder it expects, and the log it reads.

The stage runs only on the E2E Mac, so an expectation computed wrongly here would be found out there,
after a full build and ship, as a reminder the app "got wrong". These pin the arithmetic against the
rules `ReminderPlanner` implements — the study day starts at 04:00, a time before the cutoff belongs to
the study day before, nothing at or before now — and the shapes against what the Swift side encodes.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import datetime
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest

from ledger_schema import REPO

SCRIPT = REPO / "Tools" / "e2e" / "reminder.py"
_spec = importlib.util.spec_from_file_location("reminder", SCRIPT)
reminder = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(reminder)


class InZone:
    """Runs a block with the process's local zone set, as the E2E Mac's is."""

    def __init__(self, zone: str):
        self.zone = zone

    def __enter__(self):
        self.saved = os.environ.get("TZ")
        os.environ["TZ"] = self.zone
        time.tzset()

    def __exit__(self, *_):
        if self.saved is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = self.saved
        time.tzset()


def local(year, month, day, hour, minute=0) -> float:
    return datetime.datetime(year, month, day, hour, minute).timestamp()


class ExpectedTests(unittest.TestCase):
    def test_a_time_later_today_is_todays_study_day(self):
        with InZone("Asia/Shanghai"):
            got = reminder.expected(19, now=local(2026, 10, 5, 10))
            self.assertEqual(got, {"id": "review.2026-10-05", "fireAt": local(2026, 10, 5, 19)})

    def test_a_time_already_passed_is_tomorrows(self):
        with InZone("Asia/Shanghai"):
            got = reminder.expected(9, now=local(2026, 10, 5, 10))
            self.assertEqual(got, {"id": "review.2026-10-06", "fireAt": local(2026, 10, 6, 9)})

    def test_a_time_before_the_cutoff_belongs_to_the_study_day_before(self):
        # 01:30 ends the study day that began at 04:00 the day before.
        with InZone("America/New_York"):
            got = reminder.expected(1, now=local(2026, 10, 5, 10))
            self.assertEqual(got, {"id": "review.2026-10-05", "fireAt": local(2026, 10, 6, 1)})

    def test_after_midnight_the_study_day_is_still_yesterdays(self):
        # 02:00 on the 6th is the 5th's study day; its 03:00 is still ahead.
        with InZone("Asia/Shanghai"):
            got = reminder.expected(3, now=local(2026, 10, 6, 2))
            self.assertEqual(got, {"id": "review.2026-10-05", "fireAt": local(2026, 10, 6, 3)})

    def test_never_now_or_before(self):
        with InZone("Asia/Shanghai"):
            now = local(2026, 10, 5, 19)
            self.assertGreater(reminder.expected(19, now=now)["fireAt"], now)

    def test_the_hour_chosen_is_hours_ahead(self):
        with InZone("Europe/London"):
            now = local(2026, 10, 5, 22, 40)
            hour = reminder.hour_ahead(now=now)
            self.assertEqual(hour, 1)
            self.assertGreaterEqual(reminder.expected(hour, now=now)["fireAt"] - now, 2 * 3600)


class PlannedDaysTests(unittest.TestCase):
    """**Every reminder the horizon holds**, the stage's whole-plan expectation — not one per horizon day.

    The stage asserted `len(planned) == horizon`, which holds only while today's fire time is ahead. Run
    on the E2E Mac at 01:08 on 2026-10-05, the hour chosen was 04:00, and 04:00 of the study day that
    began at 04:00 on the 4th had passed: the app rightly planned six, and the stage failed it."""

    def test_today_already_fired_is_not_planned_and_the_horizon_does_not_reach_further(self):
        with InZone("Asia/Shanghai"):
            now = local(2026, 10, 5, 1, 8)
            hour = reminder.hour_ahead(now=now)
            self.assertEqual(hour, 4)
            days = reminder.planned_days(hour, 7, now=now)
            self.assertEqual([d["id"] for d in days], [f"review.2026-10-{n:02d}" for n in range(5, 11)])
            self.assertEqual(days[0], reminder.expected(hour, now=now))

    def test_a_daytime_run_plans_every_day_of_the_horizon_today_first(self):
        with InZone("Asia/Shanghai"):
            now = local(2026, 10, 5, 14)
            days = reminder.planned_days(17, 7, now=now)
            self.assertEqual([d["id"] for d in days], [f"review.2026-10-{n:02d}" for n in range(5, 12)])
            self.assertEqual([d["fireAt"] for d in days], [local(2026, 10, n, 17) for n in range(5, 12)])

    def test_a_time_before_the_cutoff_fires_on_the_next_date_of_each_study_day(self):
        with InZone("Asia/Shanghai"):
            now = local(2026, 10, 5, 22)
            days = reminder.planned_days(1, 3, now=now)
            self.assertEqual(days, [{"id": f"review.2026-10-{n:02d}", "fireAt": local(2026, 10, n + 1, 1)}
                                    for n in range(5, 8)])

    def test_the_horizon_is_the_apps(self):
        swift = (REPO / "Sources" / "ReviewKit" / "ReminderSettings.swift").read_text()
        self.assertIn(f"public static let horizon = {reminder.HORIZON}\n", swift)
        self.assertEqual(json.loads(subprocess_expect(4))["horizon"], reminder.HORIZON)


def subprocess_expect(hour: int) -> str:
    """`reminder.py expect`, as the stage runs it."""
    return subprocess.run([sys.executable, str(SCRIPT), "expect", str(hour)], check=True,
                          capture_output=True, text=True).stdout


class SettingsTests(unittest.TestCase):
    def test_the_settings_are_json_bytes_in_hex(self):
        written = bytes.fromhex(reminder.settings_hex(True, 7))
        self.assertEqual(json.loads(written), {"isEnabled": True, "hour": 7, "minute": 0})
        self.assertEqual(json.loads(bytes.fromhex(reminder.settings_hex(False, 23)))["isEnabled"], False)


class LogTests(unittest.TestCase):
    """The log as `ReminderLog.encode(to:)` writes it, inside the app's exported preferences."""

    SAMPLE = {"entries": [
        {"day": "2026-10-05", "kind": "daily", "state": "added", "fireAt": 1_791_198_000,
         "content": {"case": "sittingReady", "predictedCount": 8}},
        {"day": "2026-10-05", "kind": "later", "state": "withdrawn", "reason": "disabled"},
    ], "later": []}

    def exported(self) -> bytes:
        return plistlib.dumps({"reviewReminderLog": json.dumps(self.SAMPLE).encode(), "other": 1})

    def test_states_are_read_by_identifier(self):
        states = reminder.log_states(self.exported())
        self.assertEqual(states, {"review.2026-10-05": "added", "review.2026-10-05.later": "withdrawn"})

    def test_no_log_is_no_states(self):
        self.assertEqual(reminder.log_states(plistlib.dumps({"other": 1})), {})

    def test_the_log_the_switch_writes_first_is_empty_and_reads(self):
        """`ReminderLog()`'s shape: both lists, empty — what the app reads as a log kept, not one lost."""
        written = bytes.fromhex(reminder.empty_log_hex())
        self.assertEqual(json.loads(written), {"entries": [], "later": []})
        exported = plistlib.dumps({"reviewReminderLog": written})
        self.assertEqual(reminder.log_states(exported), {})


class WaitDeadlineTests(unittest.TestCase):
    """**`wait` keeps its deadline even when `defaults` does not answer** (audit-fix round 3, #13).

    Each poll ran `defaults export` with no timeout, so one export that stalled — cfprefsd busy, the
    domain locked — held the stage for as long as it stalled, and the deadline the caller passed was
    checked only between polls. A stand-in `defaults` is put first on the path."""

    def run_wait(self, defaults_body: str, seconds: float) -> tuple[subprocess.CompletedProcess, float]:
        with tempfile.TemporaryDirectory() as scratch:
            fake = os.path.join(scratch, "defaults")
            with open(fake, "w") as f:
                f.write("#!/bin/bash\n" + defaults_body + "\n")
            os.chmod(fake, 0o755)
            env = {**os.environ, "PATH": scratch + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin")}
            started = time.monotonic()
            try:
                done = subprocess.run([sys.executable, str(SCRIPT), "wait", "review.2026-10-05", "added", str(seconds)],
                                      text=True, capture_output=True, check=False, env=env, timeout=seconds + 10)
            except subprocess.TimeoutExpired:
                self.fail(f"`wait {seconds:g}` was still waiting {seconds + 10:g} s later: a stalled export held it")
            return done, time.monotonic() - started

    def test_a_stalled_export_ends_at_the_deadline(self):
        done, took = self.run_wait("exec sleep 60", 1)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertLess(took, 6, "the deadline was not kept")
        self.assertIn("could not be exported", done.stdout)

    def test_a_logged_state_answers_at_once(self):
        """The positive control: an export that answers is read, and the state found ends the wait."""
        log = json.dumps({"entries": [{"day": "2026-10-05", "kind": "daily", "state": "added"}], "later": []})
        plist = plistlib.dumps({"reviewReminderLog": log.encode()}).decode()
        done, _ = self.run_wait(f"cat <<'PLIST'\n{plist}PLIST", 5)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, "review.2026-10-05 is added"), done.stderr)


class ReadersOwnRemindersTests(unittest.TestCase):
    """**The reader's own pending reminders, proved still there after a stage** (audit 2026-10-05, #28;
    audit-fix round 2, #20).

    A launch that reconciles the notification center against a stage's ledger and log removes a
    reader's pending requests, and the reader's log, imported back, still records them `added`, which the
    app reads as `gone` — those days silenced. The stages now leave them alone, and the restore compares
    what was pending before the stage with what is pending after it: one missing fails the restore. It is
    never regenerated — the app would plan it at whatever instant it chose now."""

    NOW = 1_791_000_000.0

    def report(self, *pending) -> dict:
        return {"grant": "granted", "pending": [{"id": i, "fireAt": at} for i, at in pending]}

    def test_a_request_pending_before_and_not_after_is_missing(self):
        before = self.report(("review.2026-10-05", self.NOW + 3_600), ("review.2026-10-06", self.NOW + 90_000))
        after = self.report(("review.2026-10-06", self.NOW + 90_000))
        self.assertEqual(reminder.missing(before, after, self.NOW), ["review.2026-10-05"])

    def test_the_same_identifier_at_another_instant_is_missing(self):
        """The stage plans the same identifiers at its own hour: one pending at the stage's instant is
        the stage's, not the reader's."""
        before = self.report(("review.2026-10-05", self.NOW + 3_600))
        after = self.report(("review.2026-10-05", self.NOW + 7_200))
        self.assertEqual(reminder.missing(before, after, self.NOW), ["review.2026-10-05"])

    def test_a_request_whose_time_has_passed_is_not_put_back(self):
        """No catch-up: a reminder whose time passed while the stage held the app is not asked for again."""
        before = self.report(("review.2026-10-05", self.NOW - 1), ("review.2026-10-05.later", self.NOW))
        self.assertEqual(reminder.missing(before, self.report(), self.NOW), [])

    def test_only_review_requests_are_compared(self):
        before = {"pending": [{"id": "other.thing", "fireAt": self.NOW + 60}]}
        self.assertEqual(reminder.missing(before, self.report(), self.NOW), [])

    def test_the_commands_read_reports_from_files(self):
        with tempfile.TemporaryDirectory() as scratch:
            before, after = os.path.join(scratch, "before.json"), os.path.join(scratch, "after.json")
            soon = time.time() + 3_600
            with open(before, "w") as f:
                json.dump(self.report(("review.2026-10-05", soon), ("review.2026-10-06", soon + 86_400)), f)
            with open(after, "w") as f:
                json.dump(self.report(("review.2026-10-06", soon + 86_400)), f)
            done = subprocess.run([sys.executable, str(SCRIPT), "missing", before, after],
                                  text=True, capture_output=True, check=False)
            self.assertEqual((done.returncode, done.stdout.strip()), (0, "review.2026-10-05"), done.stderr)
            with open(after, "w") as f:
                f.write("")
            done = subprocess.run([sys.executable, str(SCRIPT), "missing", before, after],
                                  text=True, capture_output=True, check=False)
            self.assertNotEqual(done.returncode, 0, "an unreadable report compared as nothing missing")


if __name__ == "__main__":
    unittest.main()
