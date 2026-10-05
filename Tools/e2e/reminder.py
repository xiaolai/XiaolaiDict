"""The reminder stage, on the E2E Mac: the settings it writes, the reminder it expects, the log it reads.

    reminder.py hour                       an hour two to three hours ahead of now, local
    reminder.py settings <on|off> <hour>   the settings as `defaults write … -data` takes them
    reminder.py log                        an empty log, as `defaults write … -data` takes it
    reminder.py expect <hour>              the first daily reminder at <hour>:00, and every one the
                                           horizon holds, as JSON
    reminder.py wait <id> <state> <secs>   polls the app's log until <id> is in <state>; exit 1 if not
    reminder.py missing <before> <after>   the review requests pending in report <before>, their time
                                           still ahead, that report <after> does not list at that time

**The expectation is computed here, independently of the app**: the study day starts at 04:00, a time
before it belongs to the study day before, nothing is planned at or before now. `ReminderPlanner` is the
implementation, and the stage holds what `--reminder-report` says against this. Local time is the
Mac's own zone; a run that crosses a daylight-saving change is the one case it does not model.

No reader prose is asserted here, and no notification is ever requested: the app asks only from its
Settings switch, which this stage never touches.
"""
from __future__ import annotations

import datetime
import json
import plistlib
import subprocess
import sys
import time

BUNDLE = "com.xiaolaidict"
# `ReminderSettingsStore.key` and `ReminderLogStore.key`.
SETTINGS_KEY = "reviewReminderSettings"
LOG_KEY = "reviewReminderLog"
# `StudyDay.defaultCutoffHour`.
CUTOFF = 4
# `ReminderRecommendation.horizon`: the study days a plan looks at, today first. `test_reminder` reads
# the Swift constant, so the two cannot drift apart unnoticed.
HORIZON = 7
PREFIX = "review."


def hour_ahead(now: float | None = None) -> int:
    """An hour whose :00 is two to three hours away: far enough that nothing fires during the stage."""
    now = time.time() if now is None else now
    return (datetime.datetime.fromtimestamp(now) + datetime.timedelta(hours=3)).hour


def settings_hex(enabled: bool, hour: int) -> str:
    """`ReminderSettings` as JSON — every field it leaves out is R3's recommendation."""
    return json.dumps({"isEnabled": enabled, "hour": hour, "minute": 0}).encode().hex()


def empty_log_hex() -> str:
    """**The log the Settings switch writes before it turns reminders on** — `ReminderLog()` as its
    decoder reads it. On with no log at all is read by the app as a log that was lost, which spends
    today's reminders (WI-8); the stage turns reminders on as the switch would, so it writes this too."""
    return json.dumps({"entries": [], "later": []}).encode().hex()


def expected(hour: int, now: float | None = None) -> dict:
    """The first daily reminder at `hour`:00 after `now`: its identifier and its instant."""
    now = time.time() if now is None else now
    today = (datetime.datetime.fromtimestamp(now) - datetime.timedelta(hours=CUTOFF)).date()
    for ahead in range(3):
        day = today + datetime.timedelta(days=ahead)
        fire = fire_instant(day, hour)
        if fire > now:
            return {"id": PREFIX + day.isoformat(), "fireAt": fire}
    raise AssertionError("no fire instant within three study days")


def fire_instant(day: datetime.date, hour: int) -> float:
    """A study day's daily reminder at `hour`:00: on its own date, or the next one before the cutoff."""
    fires_on = day if hour >= CUTOFF else day + datetime.timedelta(days=1)
    return datetime.datetime.combine(fires_on, datetime.time(hour)).timestamp()


def planned_days(hour: int, horizon: int, now: float | None = None) -> list[dict]:
    """**Every daily reminder a plan of `horizon` study days holds**, today first: each day's fire instant,
    kept only when it is after `now`. Today's has passed when the hour, on today's study day, is behind
    us — from 01:00 to 04:00 the hour three ahead lands there — so a plan can hold one fewer than its
    horizon, and nothing reaches past the horizon to make up for it."""
    now = time.time() if now is None else now
    today = (datetime.datetime.fromtimestamp(now) - datetime.timedelta(hours=CUTOFF)).date()
    days = [today + datetime.timedelta(days=ahead) for ahead in range(horizon)]
    return [{"id": PREFIX + day.isoformat(), "fireAt": fire_instant(day, hour)}
            for day in days if fire_instant(day, hour) > now]


def identifier(entry: dict) -> str:
    """`ReminderKey.identifier`: `review.<day>`, and `.later` for Later."""
    suffix = ".later" if entry.get("kind") == "later" else ""
    return PREFIX + str(entry.get("day")) + suffix


def log_states(exported: bytes) -> dict:
    """Every logged reminder's state, by identifier, from `defaults export` of the app's domain."""
    preferences = plistlib.loads(exported)
    raw = preferences.get(LOG_KEY)
    if raw is None:
        return {}
    log = json.loads(raw)
    return {identifier(entry): entry.get("state") for entry in log.get("entries", [])}


def requests(report: dict) -> dict:
    """The review requests a `--reminder-report` lists as pending: identifier → fire instant."""
    return {str(found["id"]): found.get("fireAt") for found in report.get("pending") or []
            if str(found.get("id", "")).startswith(PREFIX)}


def missing(before: dict, after: dict, now: float) -> list[str]:
    """**The reader's own requests a stage took away** (audit 2026-10-05, #28): pending in `before`,
    their time still ahead at `now`, and not pending in `after` at that same instant. The stage plans the
    same identifiers at its own hour, so an identifier pending at another instant is the stage's, not the
    reader's. One whose time has passed may have fired, and is not counted.

    **A check, never a repair.** Nothing outside the app can add a request, and the app adds only what it
    plans now — so the stages leave the reader's requests alone and fail their restore when one is gone,
    rather than have the app plan it again at whatever instant it would choose."""
    now_pending = requests(after)
    return sorted(identifier for identifier, fire_at in requests(before).items()
                  if fire_at is not None and fire_at > now and now_pending.get(identifier) != fire_at)


def exported(timeout: float) -> bytes:
    """The app's domain, as `defaults export` prints it. **Bounded**: `subprocess.run` kills an export
    still running at `timeout` and raises `TimeoutExpired` (audit-fix round 3, #13)."""
    return subprocess.run(["defaults", "export", BUNDLE, "-"], check=True, capture_output=True,
                          timeout=timeout).stdout


def wait(wanted_id: str, state: str, seconds: float) -> int:
    """Polls the log until `wanted_id` is in `state`, for `seconds` and no longer.

    **Each export is given only what is left of the deadline.** Without a timeout one stalled
    `defaults export` held the stage for as long as it stalled, and the deadline was checked only
    between polls. An export that runs out the deadline is said as such — it is not "the state was
    something else"."""
    deadline = time.monotonic() + seconds
    found = None
    while (left := deadline - time.monotonic()) > 0:
        try:
            found = log_states(exported(left)).get(wanted_id)
        except subprocess.TimeoutExpired:
            print(f"{wanted_id}: the app's preferences could not be exported within {seconds:g} s")
            return 1
        if found == state:
            print(f"{wanted_id} is {state}")
            return 0
        time.sleep(min(0.5, max(0.0, deadline - time.monotonic())))
    print(f"{wanted_id} is {found}, not {state}, after {seconds:g} s")
    return 1


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else ""
    if command == "hour":
        print(hour_ahead())
    elif command == "settings":
        print(settings_hex(argv[2] == "on", int(argv[3])))
    elif command == "log":
        print(empty_log_hex())
    elif command == "expect":
        hour, now = int(argv[2]), time.time()
        print(json.dumps({**expected(hour, now), "horizon": HORIZON, "days": planned_days(hour, HORIZON, now)}))
    elif command == "wait":
        return wait(argv[2], argv[3], float(argv[4]))
    elif command == "missing":
        # An unreadable report raises, and the exit is not 0: it is no evidence that nothing is missing.
        with open(argv[2]) as before, open(argv[3]) as after:
            print(" ".join(missing(json.load(before), json.load(after), time.time())))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
