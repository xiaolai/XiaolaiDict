"""`Tools/e2e.sh` and its helpers, held on this Mac — the failures the E2E Mac cost hours to explain (2026-10-08).

Three of them, each with a shape this file refuses and a behaviour it runs:

- **A launch that failed did not end its stage.** A restart LaunchServices refused (`-600`) was reported as "no new
  process", and the learning stage went on to "restored encounter lost after relaunch" — a sentence about lost data.
  Every launch in the remote script now goes through `launch_app`, and in a stage through `launch_or_end_stage` /
  `relaunch_or_end_stage`, each ending the stage at once with its own sentence. Run here in bash 3.2 against an
  `open` that refuses.
- **The SSH session's own grants were invisible.** Commands run there are judged by TCC as `sshd-keygen-wrapper`, so
  the learning stage's `screencapture` and hover's direct `--read-point` failed while the app's setup board was green.
  The preflight names each missing grant with the list macOS 27 keeps it in, and stops the run before any stage. Run
  here against helpers that answer each way.
- **The helpers trusted a pid of -1.** macOS 27 reports some running apps' process as -1, and every Accessibility
  request to it fails — `select-text` said "no focused element" about a TextEdit that was fine. Every helper finds its
  app through `Tools/e2e/shared/running-app.swift`; each is compiled here with it, as the install step builds it.

Run from the repository root:

    python3 -m unittest discover -s Tools/tests
"""
from __future__ import annotations

import concurrent.futures
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest

from ledger_schema import REPO

SCRIPT = REPO / "Tools" / "e2e.sh"
HELPERS = REPO / "Tools" / "e2e"
RESOLVER = HELPERS / "shared" / "running-app.swift"
# The one way a helper writes its report (`jsonLine`), compiled beside every helper as the resolver is.
REPORTER = HELPERS / "shared" / "report.swift"
# The shell the E2E Mac runs the remote script with: `#!/bin/bash` on macOS is 3.2.
BASH = "/bin/bash"


def function(name: str, text: str | None = None) -> str:
    """One shell function as `e2e.sh` defines it: from `name() {` to the first line that is `}`."""
    text = SCRIPT.read_text() if text is None else text
    found = re.search(rf"^{name}\(\) {{.*?^}}$", text, re.MULTILINE | re.DOTALL)
    assert found, f"e2e.sh defines no {name}()"
    return found.group(0)


def one_line(name: str) -> str:
    """A function `e2e.sh` writes on one line, `name() { …; }`."""
    found = re.search(rf"^{name}\(\) {{.*}}$", SCRIPT.read_text(), re.MULTILINE)
    assert found, f"e2e.sh defines no one-line {name}()"
    return found.group(0)


def remote_lines(text: str | None = None) -> list[tuple[int, str]]:
    """The remote scripts' shell lines — what runs on the E2E Mac — numbered as in the file. Comments are dropped, and
    so is the body of every heredoc inside them (the Python validators), whose braces and words are not shell."""
    text = SCRIPT.read_text() if text is None else text
    lines, inside, embedded = [], False, None
    for number, line in enumerate(text.split("\n"), 1):
        if not inside and re.search(r"<<'SH'", line):
            inside = True
            continue
        if inside and line == "SH":
            inside = False
            continue
        if not inside:
            continue
        if embedded is not None:
            if line.strip() == embedded:
                embedded = None
            continue
        opened = re.search(r"<<'([A-Za-z_][A-Za-z0-9_]*)'", line)
        if opened and not line.lstrip().startswith("#"):
            embedded = opened.group(1)
        if not line.lstrip().startswith("#"):
            lines.append((number, line))
    return lines


# A shell function opening at the left margin, with or without a comment after its brace.
OPENS = re.compile(r"([a-z_]+)\(\) \{(\s*#.*)?$")


# ---------------------------------------------------------------------------------------------------------------------
# The shape, read from the script.

def launches_outside_launch_app(text: str) -> list[str]:
    """`open "$app"` anywhere but `launch_app`: a launch nothing verifies."""
    found, inside = [], False
    for number, line in remote_lines(text):
        if OPENS.match(line) and line.startswith("launch_app()"):
            inside = True
        elif inside and line == "}":
            inside = False
        elif re.search(r'\bopen "\$app"', line) and not inside:
            found.append(f"line {number}: {line.strip()}")
    return found


def stage_launches_that_go_on(text: str) -> list[str]:
    """A stage launch whose failure does not end the stage at once: anything but `X || return 0`, or `if ! X; then`
    with `return 0` as its next line."""
    lines = remote_lines(text)
    found = []
    for index, (number, line) in enumerate(lines):
        if not re.search(r"\b(re)?launch_or_end_stage\b", line) or re.match(r"\s*(re)?launch_or_end_stage\(\) \{", line):
            continue
        if re.fullmatch(r"\s*(re)?launch_or_end_stage \|\| return 0", line):
            continue
        following = next((later for _, later in lines[index + 1:] if later.strip()), "")
        if re.fullmatch(r"\s*if ! (re)?launch_or_end_stage; then", line) and following.strip() == "return 0":
            continue
        found.append(f"line {number}: {line.strip()}")
    return found


def stage_launches_outside_a_function(text: str) -> list[str]:
    """A stage launch at the top level, where `return` cannot end the stage — or ends nothing but an error. Functions
    nest (a stage's restore is defined inside the stage), so it is a stack of the ones open at the left margin."""
    found, opened = [], []   # what each brace at the left margin opened: a function's name, or None for a group
    for number, line in remote_lines(text):
        function_opened = OPENS.match(line)
        if function_opened:
            opened.append(function_opened.group(1))
            continue
        if not line[:1].isspace() and re.search(r"\{\s*$", line):
            opened.append(None)    # `… || {` at the margin: a group, closed by the margin's next `}`
            continue
        if line == "}":
            if not opened:
                found.append(f"line {number}: a closing brace with nothing open — this scan has lost its place")
            else:
                opened.pop()
            continue
        call = re.search(r"\b(re)?launch_or_end_stage\b", line)
        if call and not re.match(r"\s*(re)?launch_or_end_stage\(\) \{", line) \
                and not any(name is not None for name in opened):
            found.append(f"line {number}: {line.strip()}")
    return found


# A positional parameter — `$1`, `${2}`, `$@`, `$*`, `$#` — but not an array's or a string's length, `${#name}`.
POSITIONAL = re.compile(r"\$[1-9@*]|\$\{[1-9@*]|\$#(?![A-Za-z_])|\$\{#\}")


def positional_parameters_in_stage_functions(text: str) -> list[str]:
    """A stage's own function reading `$1` and its kind. The stages were top-level code, where `$1` is the script's
    argument — the installed directory — and the same line inside `learning_stage()` reads the function's argument,
    unset under `set -u`: the full run of 2026-10-08 died at the learning stage's first line. A function a stage defines
    inside itself has arguments of its own, and may read them."""
    found, opened = [], []
    for number, line in remote_lines(text):
        function_opened = OPENS.match(line)
        if function_opened:
            opened.append(function_opened.group(1))
            continue
        if not line[:1].isspace() and re.search(r"\{\s*$", line):
            opened.append(None)
            continue
        if line == "}":
            if opened:
                opened.pop()
            continue
        # Nested definitions are indented; their frames are tracked by the indented `name() {` line and `}` at its depth.
        innermost = next((name for name in reversed(opened) if name is not None), None)
        if innermost and innermost.endswith("_stage") and POSITIONAL.search(line):
            found.append(f"line {number}: {line.strip()}")
    return found


def unchecked_launches(text: str) -> list[str]:
    """`launch_app` or `restart_app` called where a failure is not acted on — anything but a call whose own line
    carries `||` and a `return`, or the assignment the stage wrappers make."""
    found = []
    for number, line in remote_lines(text):
        if not re.search(r"\b(launch_app|restart_app)\b", line):
            continue
        if re.match(r"\s*(launch_app|restart_app)\(\) \{", line):
            continue
        if re.fullmatch(r"\s*why=\$\((launch_app|restart_app) 2>&1\) && return 0", line):
            continue
        if re.search(r"\b(launch_app|restart_app)\b[^|]*\|\|.*\breturn\b", line):
            continue
        if re.fullmatch(r"\s*launch_app$", line) or re.fullmatch(r"\s*elif ! why=\$\(launch_app 2>&1\); then", line):
            # `restart_app`'s own last line hands its status to its caller; the preflight's `elif` names the failure.
            continue
        found.append(f"line {number}: {line.strip()}")
    return found


# What may script another app from the SSH session, and why: an Apple event from there needs an Automation grant of
# the session's own, and asked for the first time it raises a prompt nobody is there to answer. Each is guarded.
APPLE_EVENTS = {
    # The system's appearance, read and set in one place (`dark_mode_now`, `set_dark_mode`): the learning stage's switch
    # and the hover stage's look at the card above its word in the dark (plan-card-refinements D3) have no LaunchServices
    # equivalent. The preflight requires System Events granted whenever either stage is asked for.
    "answer=$(osascript -e 'tell application \"System Events\" to tell appearance preferences to get dark mode' 2>&1)",
    "true|false) osascript -e \"tell application \\\"System Events\\\" to tell appearance preferences to set dark mode to $1\" >/dev/null ;;",
}


def unlisted_apple_events(text: str) -> list[str]:
    found = []
    for number, line in remote_lines(text):
        if "osascript" in line and not any(allowed in line for allowed in APPLE_EVENTS):
            found.append(f"line {number}: {line.strip()}")
    return found


class TheScriptsShape(unittest.TestCase):
    """Each rule on the real script, and each refusing a plant — a check that cannot fail is not a check."""

    def setUp(self):
        self.text = SCRIPT.read_text()

    def plant(self, anchor: str, extra: str) -> str:
        self.assertEqual(self.text.count(anchor), 1, f"premise: {anchor!r} is in e2e.sh once")
        return self.text.replace(anchor, anchor + extra)

    def test_every_launch_is_launch_apps(self):
        self.assertEqual(launches_outside_launch_app(self.text), [])
        planted = self.plant("launch_stage() {\n", '    open "$app"\n')
        self.assertEqual(len(launches_outside_launch_app(planted)), 1)

    def test_a_launch_in_a_stage_ends_the_stage_when_it_fails(self):
        self.assertEqual(stage_launches_that_go_on(self.text), [])
        # A floor, so the rule cannot pass by finding nothing: launch, setup twice, learning four times, review twice,
        # reminder twice.
        calls = [line for _, line in remote_lines(self.text)
                 if re.search(r"\b(re)?launch_or_end_stage\b", line) and "() {" not in line]
        self.assertGreaterEqual(len(calls), 11, calls)
        for bad in ("    relaunch_or_end_stage\n", "    relaunch_or_end_stage || true\n",
                    "    if ! launch_or_end_stage; then\n        flunk nothing\n    fi\n"):
            self.assertEqual(len(stage_launches_that_go_on(self.plant("launch_stage() {\n", bad))), 1, bad)

    def test_a_stage_that_launches_is_a_function(self):
        self.assertEqual(stage_launches_outside_a_function(self.text), [])
        planted = self.plant("if want launch; then\n", "launch_or_end_stage || return 0\n")
        self.assertEqual(len(stage_launches_outside_a_function(planted)), 1)

    def test_a_stage_function_reads_no_argument_of_the_script(self):
        self.assertEqual(positional_parameters_in_stage_functions(self.text), [])
        for bad in ('    evidence="$HOME/$1/x"\n', '    for a in "$@"; do :; done\n', '    echo "${1:-}"\n'):
            self.assertEqual(len(positional_parameters_in_stage_functions(self.plant("launch_stage() {\n", bad))), 1, bad)
        # An array's length is not an argument.
        self.assertEqual(positional_parameters_in_stage_functions(
            self.plant("launch_stage() {\n", '    [ "${#PIDS[@]}" -eq 0 ]\n')), [])

    def test_a_launch_outside_a_stage_is_acted_on(self):
        self.assertEqual(unchecked_launches(self.text), [])
        planted = self.plant("launch_stage() {\n", "    restart_app\n")
        self.assertEqual(len(unchecked_launches(planted)), 1)

    def test_no_apple_event_but_the_guarded_ones(self):
        self.assertEqual(unlisted_apple_events(self.text), [])
        planted = self.plant("launch_stage() {\n", "    osascript -e 'tell application \"Finder\" to activate'\n")
        self.assertEqual(len(unlisted_apple_events(planted)), 1)
        # And every allowed one is still there: an entry nothing matches is a hole nobody notices.
        for allowed in APPLE_EVENTS:
            self.assertIn(allowed, self.text, f"{allowed!r} is allowed and no longer in e2e.sh — delete it")

    def test_the_helpers_that_drive_the_review_stage_send_no_apple_event(self):
        self.assertNotIn("osascript", (HELPERS / "review.py").read_text())

    def test_every_helper_is_built_and_shipped(self):
        loop = re.search(r"^for helper in ([a-z -]+); do$", self.text, re.MULTILINE)
        self.assertIsNotNone(loop, "the install step's helper loop has moved")
        built = set(loop.group(1).split())
        sources = {path.stem for path in HELPERS.glob("*.swift")}
        self.assertEqual(sources - built, set(), "a helper no run builds is a check no run can make")
        self.assertEqual(built - sources, set(), "the install step builds a helper that is not there")
        self.assertIn("Tools/e2e/shared/running-app.swift", self.text[loop.end():loop.end() + 400],
                      "the helpers are no longer built with the shared resolver")
        self.assertIn("Tools/e2e/shared/report.swift", self.text[loop.end():loop.end() + 400],
                      "the helpers are no longer built with the one way they write a report")


class EveryHelperFindsTheRealProcess(unittest.TestCase):
    def test_no_helper_reads_a_reported_pid(self):
        offenders = []
        for path in sorted(HELPERS.glob("*.swift")):
            text = path.read_text()
            for pattern in (r"runningApplications\(\s*withBundleIdentifier", r"\.processIdentifier\b"):
                if re.search(pattern, text):
                    offenders.append(f"{path.name}: {pattern}")
        self.assertEqual(offenders, [], "a helper trusts NSRunningApplication's pid, which macOS 27 reports as -1")
        # The resolver is where the reported pid is read, once — the positive control for the search above.
        self.assertRegex(RESOLVER.read_text(), r"\.processIdentifier\b")

    def test_every_helper_compiles_with_the_resolver(self):
        """As the install step builds it: the helper as `main.swift`, beside the resolver. Typechecked, all at once."""
        scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-helpers-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        helpers = sorted(HELPERS.glob("*.swift"))
        self.assertGreaterEqual(len(helpers), 15)

        def typecheck(path: pathlib.Path) -> tuple[str, int, str]:
            folder = scratch / path.stem
            folder.mkdir()
            shutil.copy(path, folder / "main.swift")
            done = subprocess.run(["xcrun", "swiftc", "-typecheck", "-warnings-as-errors", str(folder / "main.swift"),
                                   str(RESOLVER), str(REPORTER)], capture_output=True, text=True, timeout=300, check=False,
                                  env={**os.environ, "TMPDIR": str(scratch)})
            return path.name, done.returncode, done.stderr[-600:]

        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            failed = [f"{name}: {said}" for name, status, said in pool.map(typecheck, helpers) if status != 0]
        self.assertEqual(failed, [])


# ---------------------------------------------------------------------------------------------------------------------
# The behaviour, run in bash 3.2 against stubs.

class Fake:
    """A scratch Mac: a `bin` first on PATH (open, ps, sleep, screencapture, kill-free), a helpers directory, and the
    files the stubs read their answers from."""

    def __init__(self, test: unittest.TestCase):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-e2e-fake-"))
        test.addCleanup(shutil.rmtree, self.root, True)
        self.bin, self.helpers, self.reports = self.root / "bin", self.root / "helpers", self.root / "reports"
        for folder in (self.bin, self.helpers, self.reports):
            folder.mkdir()
        self.exe = "/Applications/Fake.app/Contents/MacOS/XiaolaiDict"
        self.processes = self.root / "processes"     # "pid exe" lines `ps` lists
        self.processes.write_text("")
        # `sleep` does nothing, so a wait that runs out takes no time.
        self.script(self.bin / "sleep", "exit 0")
        self.script(self.bin / "ps", f'cat "{self.processes}"')
        self.script(self.helpers / "menu-click", "exit 0")

    @staticmethod
    def script(path: pathlib.Path, body: str):
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def opens(self, *, refuse: str | None = None, starts: int | None = None):
        """`open`: refuse with LaunchServices' words, or succeed and start a process (or start none)."""
        if refuse is not None:
            self.script(self.bin / "open", f'echo "{refuse}" >&2; exit 1')
        elif starts is not None:
            self.script(self.bin / "open", f'echo "{starts} {self.exe}" >> "{self.processes}"; exit 0')
        else:
            self.script(self.bin / "open", "exit 0")

    def run(self, body: str, *functions: str, wanted: str = "") -> subprocess.CompletedProcess:
        preamble = textwrap.dedent(f"""\
            set -euo pipefail
            exe="{self.exe}"; app="/Applications/Fake.app"
            helpers="{self.helpers}"; reports="{self.reports}"
            STAGE=learning; failures=0; failed_stages=" "; finished=false
            WANTED=({wanted})
            """)
        source = "\n".join([preamble, function("find_pids"), function("is_running"), one_line("pass"),
                            function("flunk"), *functions, body])
        return subprocess.run([BASH, "-c", source], text=True, capture_output=True, timeout=120, check=False,
                              env={"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.root)})


LAUNCH = ("stop_app", "launch_app", "restart_app", "launch_or_end_stage", "relaunch_or_end_stage")
REFUSED = "The application cannot be opened. LSOpenURLsWithRole() failed with error -600 for the file /Applications/Fake.app."


class ALaunchThatFailsEndsItsStage(unittest.TestCase):
    def setUp(self):
        self.fake = Fake(self)

    def stage(self, call: str) -> subprocess.CompletedProcess:
        """A stage written as the real ones are: its launch, then a check that must never run after a failed one."""
        body = textwrap.dedent(f"""\
            a_stage() {{
                {call} || return 0
                flunk "learning: restored encounter lost after relaunch"
            }}
            a_stage
            echo "run went on, failures=$failures"
            """)
        return self.fake.run(body, *(function(name) for name in LAUNCH))

    def test_launchservices_refusing_ends_the_stage_with_its_own_words(self):
        self.fake.opens(refuse=REFUSED)
        done = self.stage("launch_or_end_stage")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("FAIL  learning: XiaolaiDict could not be started — LaunchServices would not start it: "
                      "open exited 1 — " + REFUSED, done.stdout)
        self.assertNotIn("restored encounter lost", done.stdout, "the stage went on after the launch failed")
        self.assertIn("RESULT\tlearning\tfail", done.stdout)
        # The run itself goes on to the next stage: the failure is recorded, not fatal.
        self.assertIn("run went on, failures=1", done.stdout)

    def test_a_restart_refused_says_restarted(self):
        self.fake.processes.write_text(f"41 {self.fake.exe}\n")
        self.fake.opens(refuse=REFUSED)
        # The running copy quits when asked: `kill` is the shell's, so the stub process table is emptied by `ps` later.
        done = self.fake.run(textwrap.dedent(f"""\
            kill() {{ : > "{self.fake.processes}"; }}
            a_stage() {{
                relaunch_or_end_stage || return 0
                flunk "learning: restored encounter lost after relaunch"
            }}
            a_stage
            """), *(function(name) for name in LAUNCH))
        self.assertIn("FAIL  learning: XiaolaiDict could not be restarted — LaunchServices would not start it", done.stdout)
        self.assertIn("-600", done.stdout)
        self.assertNotIn("restored encounter lost", done.stdout)

    def test_open_that_starts_nothing_says_so(self):
        self.fake.opens()
        done = self.stage("launch_or_end_stage")
        self.assertIn("open exited 0 and no XiaolaiDict process appeared within 10 s", done.stdout)
        self.assertNotIn("restored encounter lost", done.stdout)

    def test_a_process_with_no_menu_bar_item_says_so(self):
        self.fake.opens(starts=77)
        self.fake.script(self.fake.helpers / "menu-click", "exit 1")
        done = self.stage("launch_or_end_stage")
        self.assertIn("pid 77 started but its menu-bar item never appeared within 20 s", done.stdout)

    def test_a_launch_that_works_lets_the_stage_go_on(self):
        self.fake.opens(starts=77)
        done = self.stage("launch_or_end_stage")
        # The positive control: with the launch working, the check after it runs.
        self.assertIn("FAIL  learning: restored encounter lost after relaunch", done.stdout)
        self.assertNotIn("could not be started", done.stdout)

    def test_starting_an_app_already_running_is_refused(self):
        self.fake.processes.write_text(f"41 {self.fake.exe}\n")
        self.fake.opens(starts=77)
        done = self.fake.run("launch_app || echo refused", function("launch_app"))
        self.assertIn("XiaolaiDict is already running (pid 41), so starting it would start nothing", done.stderr)
        self.assertIn("refused", done.stdout)


def preflight_section() -> str:
    """The remote script's launch functions and its preflight, from the first to `STAGE=setup`."""
    text = SCRIPT.read_text()
    start = text.index("# **Stopping and starting the app, written once**")
    end = text.index("STAGE=setup\n", start) + len("STAGE=setup\n")
    return text[start:end]


def unrelated_process() -> int:
    """A process to stand in for TextEdit: **not this test's child**, so that once it is ended nothing keeps it as a
    zombie — which `kill -0` would still find — exactly as launchd reaps a real app."""
    started = subprocess.run([BASH, "-c", "/bin/sleep 60 >/dev/null 2>&1 & echo $!"], capture_output=True, text=True,
                             check=True, timeout=10)
    return int(started.stdout.strip())


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class ThePreflightNamesWhatIsMissing(unittest.TestCase):
    def setUp(self):
        self.fake = Fake(self)
        helpers = self.fake.helpers
        Fake.script(helpers / "screen-state", 'echo unlocked')
        Fake.script(helpers / "on-screen", 'echo \'{"frontmost": "", "matches": [], "windows": []}\'')
        Fake.script(helpers / "panel", 'echo \'{"windows": []}\'')
        Fake.script(helpers / "select-text", "exit 0")
        self.access(accessibility=True, screenRecording=True, automation={"com.apple.systemevents": "granted"})
        self.health([{"state": "ok", "detail": "“notes.txt” holds the fixture"}])
        Fake.script(self.fake.bin / "screencapture", 'for last; do :; done; echo png > "$last"')
        self.fake.processes.write_text(f"41 {self.fake.exe}\n")
        self.fake.opens()
        # Chrome where the test puts it, so its absence can be planted on a Mac that has it.
        self.chrome = self.fake.root / "Google Chrome.app"
        self.chrome.mkdir()

    def access(self, **report):
        Fake.script(self.fake.helpers / "session-access", f"echo '{json.dumps(report)}'")

    def health(self, answers: list[dict]):
        """`app-health` answering each of `answers` in turn, the last one for ever after — and noting every sentence it
        was asked about, in `health-asked`."""
        counter = self.fake.root / "health-calls"
        counter.write_text("0")
        asked = self.fake.root / "health-asked"
        cases = "\n".join(f'  {index}) echo \'{json.dumps(answer)}\'; exit {0 if answer["state"] == "ok" else 1} ;;'
                          for index, answer in enumerate(answers[:-1]))
        last = answers[-1]
        Fake.script(self.fake.helpers / "app-health", textwrap.dedent(f"""\
            printf '%s\\n' "$2" >> "{asked}"
            n=$(cat "{counter}"); echo $((n + 1)) > "{counter}"
            case $n in
            {cases}
              *) echo '{json.dumps(last)}'; exit {0 if last["state"] == "ok" else 1} ;;
            esac"""))

    def preflight(self, wanted: str = "") -> subprocess.CompletedProcess:
        return self.fake.run(f'chrome_app="{self.chrome}"\n' + preflight_section() + '\necho "after the preflight"\n',
                             wanted=wanted)

    def failures(self, done: subprocess.CompletedProcess) -> list[str]:
        return [line for line in done.stdout.splitlines() if line.startswith("FAIL  preflight: ")]

    def test_all_in_place_passes_and_the_stages_follow(self):
        done = self.preflight()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("PASS  preflight:", done.stdout)
        self.assertIn("after the preflight", done.stdout)

    def test_the_sessions_missing_grants_are_named_with_their_lists_and_no_stage_runs(self):
        self.access(accessibility=False, screenRecording=False, automation={"com.apple.systemevents": "notAsked"})
        done = self.preflight("learning selection")
        self.assertEqual(done.returncode, 1)
        self.assertNotIn("after the preflight", done.stdout, "a stage would have run without what it needs")
        said = "\n".join(self.failures(done))
        for words in ("sshd-keygen-wrapper", "/usr/libexec/sshd-keygen-wrapper",
                      "Device Control and Data Access", "Screen & System Audio Recording",
                      "may not script System Events (notAsked)", "Automation"):
            self.assertIn(words, said)
        self.assertEqual(len(self.failures(done)), 3, said)
        self.assertIn("RESULT\tpreflight\tfail", done.stdout)

    def test_recording_is_asked_only_where_a_stage_needs_it(self):
        self.access(accessibility=True, screenRecording=False, automation={"com.apple.systemevents": "granted"})
        self.assertEqual(self.preflight("lookup").returncode, 0)
        for stage in ("learning", "hover"):
            done = self.preflight(stage)
            self.assertEqual(len(self.failures(done)), 1, done.stdout)
            self.assertIn("may not record the screen", self.failures(done)[0])

    def test_a_capture_that_makes_no_picture_is_named(self):
        Fake.script(self.fake.bin / "screencapture", 'echo "could not create image from display" >&2; exit 1')
        done = self.preflight("learning")
        self.assertIn("screencapture from this SSH session made no picture (could not create image from display)",
                      "\n".join(self.failures(done)))

    def test_a_locked_screen_is_named_and_the_fixture_is_not_asked(self):
        Fake.script(self.fake.helpers / "screen-state", "echo locked; exit 1")
        self.health([{"state": "hung", "detail": "never asked", "pid": 1}])
        done = self.preflight()
        said = "\n".join(self.failures(done))
        self.assertIn("the screen is locked", said)
        self.assertNotIn("never asked", said)

    def test_a_hung_textedit_is_ended_and_opened_again_once(self):
        hung = unrelated_process()
        self.addCleanup(lambda: alive(hung) and os.kill(hung, 9))
        self.health([{"state": "hung", "detail": "did not answer within 2 s", "pid": hung},
                     {"state": "ok", "detail": "“notes.txt” holds the fixture"}])
        done = self.preflight("selection")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("NOTE  preflight: TextEdit was hung — did not answer within 2 s; it is ended and opened again",
                      done.stdout)
        self.assertFalse(alive(hung), "the hung process was not ended")

    def test_a_sheet_on_the_fixture_is_cleared_once_and_named_if_it_comes_back(self):
        blocked = unrelated_process()
        self.addCleanup(lambda: alive(blocked) and os.kill(blocked, 9))
        self.health([{"state": "blocked", "detail": "a sheet: Revert · Keep", "pid": blocked, "onFixture": True}])
        done = self.preflight("shortcut")
        said = "\n".join(self.failures(done))
        self.assertIn("TextEdit cannot hold the fixture", said)
        self.assertIn("blocked — a sheet: Revert · Keep (after it was ended and opened again)", said)
        self.assertEqual(len(self.failures(done)), 1, said)
        self.assertFalse(alive(blocked), "the TextEdit holding a sheet over the fixture was not ended")

    def test_a_sheet_anywhere_else_is_a_persons_and_nothing_is_ended(self):
        """A dialog for the whole app, or a sheet on a document that is not the fixture: on a Mac that may be the
        owner's, answering it — or ending the app under it — is not the harness's decision."""
        for blocking in ({"onFixture": False}, {}):
            with self.subTest(blocking=blocking):
                someone = unrelated_process()
                self.addCleanup(lambda pid=someone: alive(pid) and os.kill(pid, 9))
                self.health([{"state": "blocked", "detail": "“Letter” holds a sheet: Save · Don’t Save", "pid": someone,
                              **blocking}])
                said = "\n".join(self.failures(self.preflight("selection")))
                self.assertIn("only a person can answer", said)
                self.assertIn("Save · Don’t Save", said)
                self.assertTrue(alive(someone), "an app was ended under a sheet that was not the harness's")

    def test_a_textedit_without_the_fixture_is_opened_again_without_ending_it(self):
        running = unrelated_process()
        self.addCleanup(lambda: alive(running) and os.kill(running, 9))
        self.health([{"state": "noFixture", "detail": "no window holds the fixture", "pid": running}] * 20
                    + [{"state": "ok", "detail": "“notes.txt” holds the fixture"}])
        done = self.preflight("model")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("it is opened again on the fixture", done.stdout)
        self.assertTrue(alive(running), "TextEdit was ended where opening the fixture again was enough")

    def test_every_sentence_a_stage_selects_in_is_asked_for(self):
        """The meeting line every lookup-driving stage selects in, **and the typo line `lookup` selects since
        2026-10-09** (plan-spelling-suggestion): a TextEdit holding an older copy of the fixture shows the first and not
        the second, and asking only the first passed it — measured on the E2E Mac, where `select-text` then found no
        typo to select."""
        done = self.preflight("lookup")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        asked = (self.fake.root / "health-asked").read_text().splitlines()
        self.assertIn("The meeting ended after we stopped meeting at noon.", asked)
        self.assertIn("We will recieve the parcel tomorrow.", asked)
        fixture = (REPO / "Tools" / "e2e" / "notes.txt").read_text()
        for sentence in set(asked):
            self.assertIn(sentence, fixture, "the preflight asks for a sentence the fixture does not hold")

    def test_a_textedit_holding_an_older_fixture_has_its_window_closed_and_the_fixture_opened_again(self):
        """**`open` brings a document already open forward and never reads it again from disk** — measured 2026-10-09:
        the fixture gained a line, `rsync` replaced the file, and TextEdit on the E2E Mac went on showing the old one.
        The fixture's window is the harness's own document, so it is closed and the fixture opened again; TextEdit and
        whatever else it holds are left alone."""
        closed = self.fake.root / "closed"
        Fake.script(self.fake.helpers / "close-window", f'echo "$@" >> "{closed}"; exit 0')
        running = unrelated_process()
        self.addCleanup(lambda: alive(running) and os.kill(running, 9))
        self.health([{"state": "noFixture", "pid": running,
                      "detail": "no window of com.apple.TextEdit holds the sentence (1 window(s): notes.txt)"}] * 20
                    + [{"state": "ok", "detail": "“notes.txt” holds the fixture"}])
        done = self.preflight("selection")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("NOTE  preflight: TextEdit held an older copy of the fixture", done.stdout)
        # **By the fixture's own file, never its title** (audit round 3): another document called notes.txt is not ours.
        self.assertEqual(closed.read_text().splitlines(), [f"--document {self.fake.helpers}/notes.txt com.apple.TextEdit"])
        self.assertTrue(alive(running), "TextEdit was ended where closing the fixture's window was enough")

    def test_a_textedit_not_running_is_opened_again_without_ending_anything(self):
        # Not running for longer than the poll waits — an `open` that started nothing — and then opened again.
        self.health([{"state": "notRunning", "detail": "com.apple.TextEdit is not running"}] * 20
                    + [{"state": "ok", "detail": "“notes.txt” holds the fixture"}])
        done = self.preflight("deadline")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("NOTE  preflight: TextEdit was notRunning — com.apple.TextEdit is not running; it is opened "
                      "again on the fixture", done.stdout)

    def test_a_session_without_accessibility_does_not_blame_textedit(self):
        self.access(accessibility=False, screenRecording=True, automation={"com.apple.systemevents": "granted"})
        self.health([{"state": "hung", "detail": "never asked", "pid": 1}])
        said = "\n".join(self.failures(self.preflight("selection")))
        self.assertIn("may not use Accessibility", said)
        self.assertNotIn("TextEdit", said)

    def test_chrome_is_required_only_for_hover(self):
        self.assertEqual(self.preflight("hover").returncode, 0)
        self.chrome.rmdir()
        self.assertEqual(self.preflight("lookup").returncode, 0)
        self.assertIn("Google Chrome is not installed", "\n".join(self.failures(self.preflight("hover"))))

    def test_an_app_that_cannot_be_started_is_named(self):
        self.fake.processes.write_text("")
        self.fake.opens(refuse=REFUSED)
        said = "\n".join(self.failures(self.preflight("lookup")))
        self.assertIn("XiaolaiDict could not be started: LaunchServices would not start it: open exited 1", said)

    def test_the_provider_stage_needs_the_fixture_it_looks_up_in(self):
        """The provider stage drives two real lookups in TextEdit, so the preflight proves the fixture for it — and only
        where a stage that selects in it is asked for: `crash` drives the dictionary service alone. **`lookup` selects
        the fixture's typo since 2026-10-09** (plan-spelling-suggestion), so it needs the fixture too."""
        self.health([{"state": "notRunning", "detail": "com.apple.TextEdit is not running"}])
        self.assertEqual(self.preflight("crash").returncode, 0)
        for stage in ("provider", "lookup"):
            said = "\n".join(self.failures(self.preflight(stage)))
            self.assertIn("TextEdit cannot hold the fixture", said, stage)
            self.assertIn(stage, said)


class EveryRunReportsItsCleanups(unittest.TestCase):
    """A `cleanup` row filed as failed by one run stood after every later run that put everything back: `on_exit` wrote
    a `cleanup` result only when a cleanup failed. It writes one every run now; `e2e-status.sh record` takes a stage as
    failed when any of its lines failed, so the pass cannot cover a failure printed beside it."""

    def run_exit(self, cleanup_status: int) -> subprocess.CompletedProcess:
        fake = Fake(self)
        body = textwrap.dedent(f"""\
            put_back() {{ return {cleanup_status}; }}
            cleanups=(put_back); finished=true; died_at=""
            on_exit
            """)
        return fake.run(body, function("on_exit"))

    def test_cleanups_that_finished_record_a_pass(self):
        done = self.run_exit(0)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("RESULT\tcleanup\tpass", done.stdout)
        self.assertNotIn("RESULT\tcleanup\tfail", done.stdout)

    def test_a_cleanup_that_failed_is_still_recorded_failed(self):
        done = self.run_exit(1)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("RESULT\tcleanup\tfail", done.stdout)
        # The record's own rule, from the script that files it: a fail anywhere wins over a pass.
        record = (REPO / "Tools" / "e2e-status.sh").read_text()
        self.assertIn('if ($3 == "fail") seen[$2] = "fail"; else if (!($2 in seen)) seen[$2] = "pass"', record)


class TheHoverStagesChromeIsItsOwn(unittest.TestCase):
    """The hover stage reads Chrome through an instance of its own, on a profile made for the run: the reader's Chrome,
    started cold, restored their session over `page.html`, and quitting it took an Apple event the session may not send."""

    def setUp(self):
        self.fake = Fake(self)
        text = SCRIPT.read_text()
        self.instance = function("chrome_instance")
        found = re.search(r"^    quit_chrome\(\) \{.*?^    \}$", text, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(found, "the hover stage no longer defines quit_chrome")
        self.quit_chrome = textwrap.dedent(found.group(0))

    def test_the_instance_is_the_browser_process_on_this_profile(self):
        chrome = "/Applications/Google Chrome.app"
        listing = "\n".join([
            # The reader's own Chrome: its own profile.
            f"  101 {chrome}/Contents/MacOS/Google Chrome --restore-last-session",
            # A helper of the stage's instance: the profile, under another executable.
            f"  202 {chrome}/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper "
            "(Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer) --type=renderer --user-data-dir=/tmp/p1",
            # The stage's instance.
            f"  303 {chrome}/Contents/MacOS/Google Chrome --user-data-dir=/tmp/p1 --no-first-run",
            f"  404 {chrome}/Contents/MacOS/Google Chrome --user-data-dir=/tmp/p2 --no-first-run",
        ])
        Fake.script(self.fake.bin / "ps", f"cat <<'LISTING'\n{listing}\nLISTING")
        done = self.fake.run(f'chrome_app="{chrome}"\n{self.instance}\nchrome_instance /tmp/p1', )
        self.assertEqual(done.stdout.strip(), "303", done.stderr)
        done = self.fake.run(f'chrome_app="{chrome}"\n{self.instance}\nchrome_instance /tmp/p3 || echo failed')
        self.assertEqual(done.stdout.strip(), "", "a profile nobody started named a process")

    def test_quitting_ends_that_process_and_removes_the_profile_with_no_apple_event(self):
        instance = unrelated_process()
        self.addCleanup(lambda: alive(instance) and os.kill(instance, 9))
        profile = self.fake.root / "profile"
        profile.mkdir()
        sent = self.fake.root / "osascript-calls"
        Fake.script(self.fake.bin / "osascript", f'echo "$*" >> "{sent}"')
        done = self.fake.run(f'chrome_pid={instance}\nchrome_profile="{profile}"\n{self.quit_chrome}\nquit_chrome',
                             function("end_process"))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(alive(instance), "the stage's Chrome was not ended")
        self.assertFalse(profile.exists(), "the run's profile was left behind")
        self.assertFalse(sent.exists(), "an Apple event was sent")

    def test_the_stage_starts_its_own_instance_on_a_profile_of_its_own(self):
        stage = re.search(r"^if want hover; then\n(.*?)(?=^if want )", SCRIPT.read_text(), re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(stage)
        body = stage.group(1)
        self.assertRegex(body, r'open -na "\$chrome_app" --args --user-data-dir="\$chrome_profile" --no-first-run')
        self.assertIn('--assistive --pid "$chrome_pid"', body)
        self.assertNotIn("quit app", body)


# ---------------------------------------------------------------------------------------------------------------------
# The language model is a service the reader already has (ADR-0053, plan §8 P5).

def stage_block(name: str) -> str:
    """One stage's block in the remote script: from `if want <name>; then` to the next stage's, or the run's end."""
    found = re.search(rf"^if want {name}; then\n(.*?)(?=^if want |^finished=true)", SCRIPT.read_text(),
                      re.MULTILINE | re.DOTALL)
    assert found, f"e2e.sh has no {name} stage"
    return found.group(1)


def set_aside_before_written(block: str, restorer: str, key: str) -> bool:
    """Whether `at_exit <restorer>` comes before the first `defaults write` of `key` — the order the run takes them in,
    since nothing here is called before the line that registers it."""
    registered = block.find(f"at_exit {restorer}")
    written = block.find(f"defaults write com.xiaolaidict {key}")
    return registered != -1 and written != -1 and registered < written


class EveryVerdictKindIsSaid(unittest.TestCase):
    def test_a_skipped_check_says_so_and_records_nothing(self):
        """A check that could not run here — a CLI not installed, nobody signed in — is neither a pass nor a failure,
        and it is never silent."""
        done = Fake(self).run(textwrap.dedent("""\
            STAGE=provider
            consume_verdicts provider "$(printf 'PASS\\tprovider: a\\nSKIPPED\\tprovider: claudeCLI is not installed\\nDONE')"
            """), function("consume_verdicts"))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("SKIPPED  provider: claudeCLI is not installed", done.stdout)
        self.assertIn("PASS  provider: a", done.stdout)
        self.assertNotIn("fail", done.stdout)


class TheProviderStage(unittest.TestCase):
    """The stage that points the app at a stub on the E2E Mac — an endpoint under a URL it reads as on this Mac and
    under one it must refuse, and the reader's own `claude`, which is remote — and asks each installed CLI through the
    app's own preflight."""

    KEYS = ("LanguageModelProvider", "ProviderEndpointURL", "ProviderEndpointModel", "SubscriptionCLIsEnabled",
            "ClaudeCLIPath", "ClaudeCLIModel")

    def setUp(self):
        self.text = SCRIPT.read_text()
        self.block = stage_block("provider")

    def test_it_is_a_registered_stage_run_as_a_function(self):
        self.assertRegex(self.text, r"KNOWN_STAGES=\([a-z ]*\bprovider\b[a-z ]*\)")
        self.assertRegex(self.block, r"(?m)^provider_stage\(\) \{")
        self.assertRegex(self.block, r"(?m)^provider_stage$")

    def test_the_readers_settings_are_set_aside_before_any_is_written_and_all_put_back(self):
        for key in self.KEYS:
            self.assertTrue(set_aside_before_written(self.block, "restore_provider_settings", key), key)
        restore = function("restore_provider_settings") + function("restore_provider_claude")
        self.assertIn("restore_provider_claude", function("restore_provider_settings"))
        for key in self.KEYS:
            self.assertIn(f"restore_default {key} ", restore, key)
        self.assertRegex(restore, r"restore_default SubscriptionCLIsEnabled .* -bool")

    def test_the_stub_ships_with_the_helpers_and_listens_only_on_loopback(self):
        install = re.search(r"^cp -p Tools/e2e/notes\.txt .*$", self.text, re.MULTILINE)
        self.assertIsNotNone(install, "the install step's fixture copy has moved")
        self.assertIn("Tools/e2e/provider-stub.py", install.group(0))
        self.assertIn('"$helpers/provider-stub.py" serve', self.block)

    def test_both_tiers_are_driven_and_judged(self):
        self.assertIn('provider-stub.py" judge', self.block)
        self.assertRegex(self.block, r"judge [^\n]*onThisMac")
        self.assertRegex(self.block, r"judge [^\n]*remote")

    def test_an_address_the_app_must_refuse_is_refused_by_its_preflight_and_sent_nothing(self):
        """Plain HTTP to a public host, or a name or password in the address, is not sent to (`EndpointAddress`): the
        app's own preflight must say so, and the stub must hear nothing under that arm's model."""
        self.assertRegex(self.block, r'provider_endpoint remote "\$\(provider_refused_url "\$port"\)" [^\n]* endpointUnusable')
        self.assertRegex(self.block, r"judge [^\n]*refused")
        self.assertIn("@localhost", one_line("provider_refused_url"))

    def test_the_remote_tier_is_the_stub_installed_as_the_readers_claude_and_the_real_one_is_checked_after(self):
        arm = function("provider_claude_arm")
        self.assertIn('claude %q "$@"', arm, "the launcher does not run the stub as claude")
        self.assertIn("defaults write com.xiaolaidict ClaudeCLIPath", arm)
        self.assertIn('ClaudeCLIModel -string "$provider_remote_model"', arm)
        self.assertLess(self.block.index("provider_claude_arm\n    relaunch_or_end_stage"),
                        self.block.index("provider_reading remote"))
        # The reader's own `claude` is found where their settings say, not the stand-in.
        self.assertLess(self.block.index("restore_provider_claude\n"), self.block.index("provider_cli_check claudeCLI"))

    def test_the_stand_in_claude_is_written_as_data_and_chosen_behind_its_switch(self):
        fake = Fake(self)
        written = fake.root / "defaults-calls"
        Fake.script(fake.bin / "defaults", f'echo "$*" >> "{written}"')
        report = fake.root / "report.json"
        report.write_text(json.dumps({"source": "claudeCLI", "tier": "remote", "sendsDictionaryText": False,
                                      "asksSenseOnLookup": False, "asksSenseOnTap": False, "readiness": "ready",
                                      "answeredInSeconds": 0.4, "version": "9.9.9"}))
        evidence = fake.root / "evidence with a space"
        evidence.mkdir()
        done = fake.run(textwrap.dedent(f"""\
            STAGE=provider
            XIAOLAIDICT_PYTHON=/opt/chosen/python3.14
            provider_evidence="{evidence}"; provider_stub_log="{evidence}/stub.jsonl"
            provider_remote_model=xiaolaidict-e2e-remote
            run_report() {{ cat "{report}"; }}
            provider_claude_arm
            echo "failures=$failures"
            """), function("consume_verdicts"), function("provider_status_verdicts"), function("provider_claude_arm"))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("failures=0", done.stdout)
        self.assertRegex(done.stdout, r"PASS  provider: claudeCLI answered the app.s preflight")
        calls = written.read_text()
        self.assertIn("write com.xiaolaidict SubscriptionCLIsEnabled -bool YES", calls)
        self.assertIn(f"write com.xiaolaidict ClaudeCLIPath -string {evidence}/claude", calls)
        launcher = (evidence / "claude").read_text()
        self.assertTrue(launcher.startswith("#!/bin/sh\nexec /opt/chosen/python3.14 "),
                        f"the launcher does not run the chosen Python (Tools/python.sh): {launcher}")
        self.assertIn("provider-stub.py claude", launcher)
        self.assertIn("evidence\\ with\\ a\\ space/stub.jsonl", launcher, "a path was spliced in unquoted")

    def test_a_refused_endpoint_that_the_app_would_ask_fails(self):
        for readiness, failures in (("endpointUnusable", 0), ("ready", 1), ("endpointFailed", 1)):
            with self.subTest(readiness=readiness):
                fake = Fake(self)
                report = {"source": "endpoint", "tier": "remote", "sendsDictionaryText": False,
                          "asksSenseOnLookup": False, "asksSenseOnTap": False, "readiness": readiness}
                done = fake.run(textwrap.dedent(f"""\
                    STAGE=provider
                    consume_verdicts provider "$(provider_status_verdicts provider endpoint remote endpointUnusable '{json.dumps(report)}')"
                    echo "failures=$failures"
                    """), function("consume_verdicts"), function("provider_status_verdicts"))
                self.assertIn(f"failures={failures}", done.stdout, done.stdout + done.stderr)

    # The CLI check, run in bash 3.2 against a `run_report` that answers what the app's preflight would.

    def cli_check(self, report: dict | str) -> tuple[subprocess.CompletedProcess, str]:
        fake = Fake(self)
        written = fake.root / "defaults-calls"
        Fake.script(fake.bin / "defaults", f'echo "$*" >> "{written}"')
        answer = fake.root / "report.json"
        answer.write_text(report if isinstance(report, str) else json.dumps(report))
        done = fake.run(textwrap.dedent(f"""\
            STAGE=provider
            run_report() {{ cat "{answer}"; }}
            provider_cli_check claudeCLI
            echo "failures=$failures"
            """), function("consume_verdicts"), function("provider_status_verdicts"), function("provider_cli_check"))
        return done, written.read_text() if written.exists() else ""

    @staticmethod
    def cli_report(**readiness) -> dict:
        return {"source": "claudeCLI", "tier": "remote", "sendsDictionaryText": False, "asksSenseOnLookup": False,
                "asksSenseOnTap": False, **readiness}

    def test_the_cli_is_chosen_with_its_switch_through_the_readers_own_defaults(self):
        _, written = self.cli_check(self.cli_report(readiness="notInstalled"))
        self.assertIn("write com.xiaolaidict LanguageModelProvider -string claudeCLI", written)
        self.assertIn("write com.xiaolaidict SubscriptionCLIsEnabled -bool YES", written)

    def test_a_cli_that_is_not_there_is_skipped_by_name_and_its_disclosure_still_checked(self):
        for readiness in ({"readiness": "notInstalled"}, {"readiness": "notSignedIn"},
                          {"readiness": "overrideUnusable"}, {"readiness": "unavailable", "failure": "rateLimited"}):
            with self.subTest(readiness=readiness):
                done, _ = self.cli_check(self.cli_report(**readiness))
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertRegex(done.stdout, rf"SKIPPED  provider: claudeCLI[^\n]*{readiness['readiness']}")
                self.assertIn("failures=0", done.stdout)
                # Skipped is not passed: the round trip is not claimed, while what it may be sent still is.
                self.assertNotIn("answered", done.stdout)
                self.assertRegex(done.stdout, r"PASS  provider: claudeCLI[^\n]*remote")

    def test_a_cli_that_answered_passes_with_its_time(self):
        done, _ = self.cli_check(self.cli_report(readiness="ready", version="2.1.294", answeredInSeconds=0.9))
        self.assertIn("failures=0", done.stdout)
        self.assertRegex(done.stdout, r"PASS  provider: claudeCLI answered the app.s preflight in 0\.9 s")
        self.assertNotIn("SKIPPED", done.stdout)

    def test_a_cli_that_is_installed_and_will_not_answer_fails(self):
        for readiness in ({"readiness": "unavailable", "failure": "timedOut"}, {"readiness": "tooOld", "version": "1"}):
            with self.subTest(readiness=readiness):
                done, _ = self.cli_check(self.cli_report(**readiness))
                self.assertIn("failures=1", done.stdout)
                self.assertIn("FAIL  provider: claudeCLI", done.stdout)

    def test_a_cli_read_as_on_this_mac_fails(self):
        done, _ = self.cli_check({**self.cli_report(readiness="ready", answeredInSeconds=1.0), "tier": "onThisMac",
                                  "sendsDictionaryText": True})
        self.assertNotIn("failures=0", done.stdout)
        self.assertIn("FAIL  provider: claudeCLI", done.stdout)

    def test_a_preflight_that_printed_nothing_fails(self):
        done, _ = self.cli_check("")
        self.assertIn("failures=1", done.stdout)
        self.assertIn("--provider-status printed nothing for claudeCLI", done.stdout)


class TheBundledModelIsHiddenNotRemoved(unittest.TestCase):
    def test_the_setup_stage_sets_the_flag_aside_before_it_shows_the_row(self):
        block = stage_block("setup")
        self.assertTrue(set_aside_before_written(block, "restore_local_model_setup", "ShowLocalModelSetup"))
        self.assertRegex(function("restore_local_model_setup"), r"restore_default ShowLocalModelSetup .* -bool")
        # And the row is asserted hidden before the flag is written: the default is what a fresh reader sees.
        self.assertLess(block.find("is hidden on a Mac with no model"),
                        block.find("defaults write com.xiaolaidict ShowLocalModelSetup"))

    def test_the_model_stage_runs_with_the_local_model_selected(self):
        block = stage_block("model")
        self.assertTrue(set_aside_before_written(block, "restore_model_source", "LanguageModelProvider"))
        self.assertIn("defaults write com.xiaolaidict LanguageModelProvider -string localModel", block)
        self.assertIn("restore_default LanguageModelProvider ", function("restore_model_source"))


if __name__ == "__main__":
    unittest.main()


class TheSpellingStepReadsThePanelExactly(unittest.TestCase):
    """`spelling_state`, the `lookup` stage's reading of the panel for "Look up “…”" (audit, 2026-10-09; the owner's ruling
    of 2026-10-11). It took any text holding "receive" for the corrected word's card — a heading "receiver", a definition,
    the reader's sentence — and any control holding the word for the button, and never asked whether the walk finished.
    Each of those is a control here: the panel that should be called the card is, and every one that should not is not —
    and it counts the buttons, since a card offering two words is the defect the ruling removed."""

    TYPO_MISS = "No entry for “recieve” in your dictionaries."
    LINE = "Look up “receive”"

    def state(self, texts: list[str], controls: list[str] | None = None, complete: bool = True,
              term: str | None = None, word: str | None = None) -> list[str]:
        report = {"complete": complete, "frontmost": "com.apple.TextEdit", "incomplete": [] if complete else ["deadline"],
                  "windows": [{"title": "Lookup", "texts": texts, "controls": controls or []}]}
        source = function("spelling_state") + '\nspelling_state "$@"\n'
        arguments = [json.dumps(report, ensure_ascii=False)] + [a for a in (term, word) if a is not None]
        done = subprocess.run([BASH, "-c", source, "spelling_state", *arguments],
                              capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.split()

    def test_the_corrected_words_card_is_headed_by_the_word_itself(self):
        self.assertIn("card", self.state(["Lookup", "receive", "to be given something", "We will recieve the parcel."]))

    def test_a_card_for_another_word_that_holds_the_word_is_not_its_card(self):
        for texts in (["Lookup", "receiver", "A person appointed to receive money."],
                      ["Lookup", "parcel", "They will receive it tomorrow."],
                      ["Lookup", "receiving"]):
            with self.subTest(texts=texts):
                self.assertNotIn("card", self.state(texts))

    def test_a_walk_that_did_not_finish_says_nothing_about_the_card(self):
        self.assertNotIn("card", self.state(["Lookup", "receive", "to be given something"], complete=False))

    def test_a_card_still_waiting_or_missing_is_not_the_words_card(self):
        self.assertNotIn("card", self.state(["Lookup", "receive", "Looking up “receive” in your dictionaries…"]))
        self.assertNotIn("card", self.state(["Lookup", "receive", "No entry for “receive” in your dictionaries."]))

    def test_the_miss_and_the_button_are_read_by_their_own_words(self):
        self.assertEqual(self.state(["Lookup", "recieve", self.TYPO_MISS], [self.LINE]), ["miss", "line", "offers=1"])
        # A miss of another word, and a button naming another word, are neither — though the button is still counted.
        self.assertEqual(self.state(["Lookup", "receiver", "No entry for “receiver” in your dictionaries."],
                                    ["Look up “receiver”", "Look up “receive” instead"]), ["offers=1"])
        # The retired wording is no button.
        self.assertEqual(self.state(["Lookup", "recieve", self.TYPO_MISS], ["Did you mean “receive”?"]), ["miss", "offers=0"])

    def test_two_buttons_are_counted_as_two(self):
        """The owner's ruling of 2026-10-11: one offer or none. A card offering the regular form and the checker's word
        side by side must read as two, so the stage can refuse it."""
        self.assertEqual(self.state(["Lookup", "heavied", "No entry for “heavied” in your dictionaries."],
                                    ["Look up “heavy”", "Look up “heavier”"], term="heavied", word="heavy"),
                         ["miss", "line", "offers=2"])
        self.assertEqual(self.state(["Lookup", "heavied", "No entry for “heavied” in your dictionaries."], [],
                                    term="heavied", word="-"), ["miss", "offers=0"])

    def test_the_dictionaries_exit_is_read_by_its_exact_name(self):
        """plan-card-refinements WI-1: every answered card carries "Dictionaries…"; a control merely holding the word,
        or named without its ellipsis, is not it."""
        self.assertEqual(self.state(["Lookup", "recieve", self.TYPO_MISS], [self.LINE, "Dictionaries…"]),
                         ["miss", "line", "offers=1", "exit"])
        self.assertNotIn("exit", self.state(["Lookup", "receive"], ["Dictionaries", "Choose Another Dictionary…"]))


class CloseWindowFindsTheFixtureByItsDocument(unittest.TestCase):
    """`close-window --document`, which the preflight uses to put away a TextEdit window holding an older copy of the
    fixture (audit round 3, 2026-10-09). By title it closed the first window called notes.txt — another document of that
    name, which an unedited close discards from view and an edited one answers with a Save sheet on a Mac that may be
    someone's. The fixture is found by its canonical file URL, and a match that is missing, doubled or cannot be checked
    is refused. Asked through `--decide`, the same choice without Accessibility, of the helper as it is compiled."""

    binary: pathlib.Path

    @classmethod
    def setUpClass(cls):
        scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-close-window-"))
        cls.addClassCleanup(shutil.rmtree, scratch, True)
        (scratch / "src").mkdir()
        shutil.copy(HELPERS / "close-window.swift", scratch / "src" / "main.swift")
        cls.binary = scratch / "close-window"
        built = subprocess.run(["xcrun", "swiftc", str(scratch / "src" / "main.swift"), str(RESOLVER), "-o", str(cls.binary)],
                               capture_output=True, text=True, timeout=300, check=False)
        assert built.returncode == 0, built.stderr
        # A real fixture under /tmp, which macOS reaches through the /private/tmp symlink — the same file by two paths.
        cls.home = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-fixture-", dir="/tmp"))
        cls.addClassCleanup(shutil.rmtree, cls.home, True)
        cls.fixture = cls.home / "notes.txt"
        cls.fixture.write_text("Intro line.\n")

    def decide(self, *documents: str) -> str:
        done = subprocess.run([str(self.binary), "--decide", str(self.fixture), *documents],
                              capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return done.stdout.strip()

    def test_another_document_with_the_fixtures_title_is_never_the_fixture(self):
        """Two windows titled notes.txt, the reader's first: the fixture is the second, by its file."""
        theirs = "file:///Users/someone/Documents/notes.txt"
        self.assertEqual(self.decide(theirs, self.fixture.as_uri()), "window 1")

    def test_the_fixture_is_found_by_its_canonical_file(self):
        private = "file:///private" + str(self.fixture)
        self.assertTrue(str(self.fixture).startswith("/tmp/"), "the fixture must be reached through the symlink")
        self.assertEqual(self.decide("none", private), "window 1")

    def test_a_missing_doubled_or_unreadable_match_is_refused(self):
        self.assertEqual(self.decide("file:///Users/someone/Documents/notes.txt", "none"), "no window")
        self.assertEqual(self.decide(self.fixture.as_uri(), self.fixture.as_uri()), "ambiguous 0,1")
        # A window whose document cannot be read could be the fixture, or could be the window the fixture is not.
        self.assertEqual(self.decide("unreadable", self.fixture.as_uri()), "unverifiable 0")


class TheReadersLedgerIsLeftAsFound(unittest.TestCase):
    """`ledger_digest` and `ledger_left`, the check that an instrument run left the E2E Mac's ledger exactly as it found it
    (audit of 2026-10-10). It compared the newest lookup id, which a run passes while deleting another process's reading
    below it, or leaving a study note behind — both of which the instruments' clean-up could do. The whole ledger is
    compared now, and each of those is a control here."""

    SCHEMA = """
        CREATE TABLE lookups (id INTEGER PRIMARY KEY, surface TEXT NOT NULL);
        CREATE TABLE sense_encounters (lookup_id INTEGER NOT NULL, sense TEXT NOT NULL);
        CREATE TABLE study_notes (id TEXT PRIMARY KEY, created_at REAL NOT NULL);
        INSERT INTO lookups (id, surface) VALUES (1, 'meeting'), (2, 'fine'), (3, 'receive');
        INSERT INTO sense_encounters VALUES (2, 'fine.1');
    """

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.ledger = pathlib.Path(self.scratch.name) / "ledger.sqlite"
        subprocess.run(["sqlite3", str(self.ledger)], input=self.SCHEMA, text=True, check=True, timeout=30)

    def tearDown(self):
        self.scratch.cleanup()

    def verdict(self, change: str | None, ledger: pathlib.Path | None = None) -> str:
        """`ledger_left` after `change` is made to the ledger between the two readings, as the run would make it."""
        source = "\n".join([
            f"ledger={json.dumps(str(ledger or self.ledger))}",
            'pass() { echo "PASS $*"; }', 'flunk() { echo "FAIL $*"; }',
            function("ledger_source"), function("ledger_digest"), function("ledger_left"),
            'before=$(ledger_digest "$ledger") || before=""',
            f"sqlite3 {json.dumps(str(self.ledger))} {json.dumps(change)}" if change else ":",
            'ledger_left "instrument" "$before"',
        ])
        done = subprocess.run([BASH, "-c", source], capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.strip()

    def test_a_ledger_left_alone_passes(self):
        self.assertTrue(self.verdict(None).startswith("PASS"), self.verdict(None))

    def test_every_change_an_instrument_could_make_fails(self):
        for change in ("INSERT INTO study_notes VALUES ('n1', 1.0)",  # a note left, the newest lookup unchanged
                       "DELETE FROM lookups WHERE id = 2",  # another process's reading deleted below the newest
                       "INSERT INTO lookups (id, surface) VALUES (4, 'fine')",  # a reading left
                       "DELETE FROM sense_encounters",  # a sense met, gone
                       "UPDATE lookups SET surface = 'fines' WHERE id = 1"):
            with self.subTest(change=change):
                self.assertTrue(self.verdict(change).startswith("FAIL"), self.verdict(change))

    def test_a_ledger_that_could_not_be_read_is_not_one_left_alone(self):
        missing = pathlib.Path(self.scratch.name) / "absent" / "ledger.sqlite"
        self.assertTrue(self.verdict(None, ledger=missing).startswith("FAIL"))


class ThePunctuatedSelectionIsBoxedByItsWord(unittest.TestCase):
    """`punctuated_box`, the selection stage's check that a short word selected inside asymmetric punctuation — “Q…”,
    (“ox, — is boxed by the word itself, run as `e2e.sh` writes it against a stand-in browser helper and app (audit of
    2026-10-10). It checked the text and that the box's middle across fell on the word, so a box on the wrong line, a
    thousand points tall, or one the app only said *contains* the word passed. Each of those is a control here: the
    box must be the word's own, `exact`, every edge within a point of the word selected alone."""

    WORD = {"x": 162.0, "y": 207.0, "width": 14.0, "height": 18.0}
    WHOLE = {"x": 155.0, "y": 207.0, "width": 44.0, "height": 18.0}

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        (self.root / "helpers").mkdir()
        self.count = self.root / "count"
        self.count.write_text("0")
        # The browser helper: selects, and for the punctuated selection prints the whole selection's box.
        helper = self.root / "helpers" / "select-web"
        helper.write_text("#!/bin/bash\n[ \"$2\" = Q ] && exit 0\nprintf '%s\\n' \"$STUB_WHOLE\"\n")
        helper.chmod(0o755)
        # The app: the word alone at the first read, the punctuated selection at the second.
        app = self.root / "XiaolaiDict"
        app.write_text(textwrap.dedent(f"""\
            #!/bin/bash
            n=$(cat {self.count}); echo $((n + 1)) > {self.count}
            [ "$n" = 0 ] && printf '%s\\n' "$STUB_ALONE" || printf '%s\\n' "$STUB_READING"
            """))
        app.chmod(0o755)

    def tearDown(self):
        self.scratch.cleanup()

    def verdicts(self, reading_bounds: dict | None, text: str = "Q", quality: str = "exact") -> list[str]:
        self.count.write_text("0")  # each run reads the word alone first
        alone = {"text": "Q", "bounds": {**self.WORD, "quality": "exact"}}
        reading = {"text": text, "bounds": None if reading_bounds is None else {**reading_bounds, "quality": quality}}
        source = "\n".join([
            f"helpers={json.dumps(str(self.root / 'helpers'))}", f"exe={json.dumps(str(self.root / 'XiaolaiDict'))}",
            f"reports={json.dumps(str(self.root))}",
            'pass() { echo "PASS $*"; }', 'flunk() { echo "FAIL $*"; }',
            "consume_verdicts() { printf '%s\\n' \"$2\" | grep -E '^(PASS|FAIL)'; }",
            function("punctuated_verdicts"), function("punctuated_box"), 'punctuated_box Q "“Q…”"',
        ])
        env = {**os.environ, "STUB_ALONE": json.dumps(alone), "STUB_READING": json.dumps(reading),
               "STUB_WHOLE": json.dumps({"selected": self.WHOLE})}
        done = subprocess.run([BASH, "-c", source], capture_output=True, text=True, timeout=60, check=False, env=env)
        self.assertEqual(done.returncode, 0, done.stderr)
        return [line.split("\t")[0].split(" ")[0] for line in done.stdout.splitlines()]

    def test_the_words_own_box_passes(self):
        self.assertEqual(set(self.verdicts(self.WORD)), {"PASS"})

    def test_a_box_within_a_point_of_the_words_passes(self):
        self.assertEqual(set(self.verdicts({**self.WORD, "x": 162.6, "height": 18.8})), {"PASS"})

    def test_every_box_that_is_not_the_words_fails(self):
        for label, box in (("on another line", {**self.WORD, "y": 237.0}), ("a thousand points tall", {**self.WORD, "height": 1000.0}),
                           ("the whole selection's", self.WHOLE), ("wider to the right", {**self.WORD, "width": 20.0}),
                           ("none", None)):
            with self.subTest(box=label):
                self.assertIn("FAIL", self.verdicts(box))

    def test_a_box_the_app_only_says_contains_the_word_fails(self):
        self.assertIn("FAIL", self.verdicts(self.WORD, quality="containing"))

    def test_another_word_read_fails(self):
        self.assertIn("FAIL", self.verdicts(self.WORD, text="Q…"))


class TheAppearanceIsChangedOnlyWhenItCanBePutBack(unittest.TestCase):
    """`placement_above`, the hover stage's look at the card above its word in the light and the dark appearance, run as
    `e2e.sh` writes it against a stand-in `osascript` (audit of 2026-10-10). It read the appearance with its failure
    suppressed, changed it anyway, and put back only a value that was `true` or `false` — so a read that failed left the
    E2E Mac dark, and a restoration that failed said nothing. Each of those is a control here."""

    OSASCRIPT = textwrap.dedent("""\
        #!/bin/bash
        case "$*" in
            *"get dark mode"*)
                [ "$STUB_GET" = fail ] && { echo "execution error: Not authorised (-1743)" >&2; exit 1; }
                echo "$STUB_GET" ;;
            *"set dark mode to "*)
                all="$*"; value=${all##*set dark mode to }
                echo "$value" >> "$STUB_LOG"
                [ "${STUB_SET_FAILS_TO:-}" = "$value" ] && [ "$(grep -c . "$STUB_LOG")" -gt 2 ] && exit 1
                exit 0 ;;
        esac
        """)

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.scratch.name)
        (root / "bin").mkdir()
        tool = root / "bin" / "osascript"
        tool.write_text(self.OSASCRIPT)
        tool.chmod(0o755)
        self.path = f"{root / 'bin'}:{os.environ['PATH']}"
        self.log = root / "sets"

    def tearDown(self):
        self.scratch.cleanup()

    def run_stage(self, get: str, set_fails_to: str = "") -> tuple[list[str], list[str]]:
        """The verdicts, and every appearance set, in order — the cleanup `at_exit` registered run last, as `on_exit`
        runs it."""
        self.log.write_text("")
        names = [name for name in ("dark_mode_now", "set_dark_mode") if f"\n{name}() {{" in SCRIPT.read_text()]
        source = "\n".join([
            'pass() { echo "PASS $*"; }', 'flunk() { echo "FAIL $*"; }',
            "cleanups=(); at_exit() { cleanups+=(\"$1\"); }",
            'placement_at() { :; }', 'placement_evidence=/tmp',
            'last_placement=\'{"screen": {"x": 0, "y": 0, "width": 1512, "height": 982}}\'',
            *[function(name) for name in names], function("placement_above"),
            "placement_above",
            'for cleanup in "${cleanups[@]}"; do "$cleanup" || echo "FAIL cleanup $cleanup"; done',
        ])
        env = {**os.environ, "PATH": self.path, "STUB_GET": get, "STUB_LOG": str(self.log),
               "STUB_SET_FAILS_TO": set_fails_to}
        done = subprocess.run([BASH, "-c", source], capture_output=True, text=True, timeout=60, check=False, env=env)
        self.assertEqual(done.returncode, 0, done.stderr)
        verdicts = [line.split(" ")[0] for line in done.stdout.splitlines() if line.startswith(("PASS", "FAIL"))]
        return verdicts, self.log.read_text().split()

    def test_an_appearance_read_is_put_back_after_both_are_seen(self):
        for was in ("true", "false"):
            with self.subTest(was=was):
                verdicts, sets = self.run_stage(was)
                self.assertNotIn("FAIL", verdicts)
                self.assertEqual(sets[:2], ["false", "true"])
                self.assertEqual(sets[-1], was, "the appearance was not put back")

    def test_an_appearance_that_could_not_be_read_is_never_changed(self):
        for get in ("fail", "missing value", ""):
            with self.subTest(get=get):
                verdicts, sets = self.run_stage(get)
                self.assertEqual(sets, [], "the appearance was changed with nothing to put back")
                self.assertIn("FAIL", verdicts)

    def test_a_restoration_that_failed_is_reported(self):
        verdicts, sets = self.run_stage("false", set_fails_to="false")
        self.assertEqual(sets[-1], "false")
        self.assertIn("FAIL", verdicts, "the appearance was left dark and nothing said so")


class TheFollowedCardStaysWhereTheReaderLeftIt(unittest.TestCase):
    """`replaced_in_place`, the lookup stage's check that pressing "Look up “…”" after dragging the miss card aside
    replaces it where the reader left it (audit of 2026-10-10: the replacement was placed afresh against the
    misspelling). The card held where the drag left it passes; one that jumped back, or a drag that never moved it, fails."""

    BEFORE = {"x": 400.0, "y": 300.0, "width": 396.0, "height": 120.0}
    AFTER = {"x": 480.0, "y": 360.0, "width": 396.0, "height": 120.0}

    def verdicts(self, drag: dict, now: dict | None) -> list[str]:
        nodes = [{"role": "AXWindow", "frame": now}] if now else []
        view = {"windows": [{"title": "Lookup", "nodes": nodes, "texts": [], "controls": []}]}
        source = function("replaced_in_place") + '\nreplaced_in_place "$1" "$2"\n'
        done = subprocess.run([BASH, "-c", source, "replaced_in_place", json.dumps(drag), json.dumps(view)],
                              capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        return [line.split("\t")[0] for line in done.stdout.splitlines()]

    def test_a_card_left_where_the_drag_put_it_passes(self):
        grown = {**self.AFTER, "height": 290.0}
        self.assertEqual(self.verdicts({"before": self.BEFORE, "after": self.AFTER}, grown), ["PASS", "PASS", "DONE"])

    def test_a_card_that_jumped_back_fails(self):
        self.assertIn("FAIL", self.verdicts({"before": self.BEFORE, "after": self.AFTER}, self.BEFORE))

    def test_a_drag_that_moved_nothing_fails_both(self):
        self.assertEqual(self.verdicts({"before": self.BEFORE, "after": self.BEFORE}, self.BEFORE), ["FAIL", "FAIL", "DONE"])

    def test_no_frame_for_the_card_fails(self):
        self.assertIn("FAIL", self.verdicts({"before": self.BEFORE, "after": self.AFTER}, None))


def remote_scripts(text: str | None = None) -> dict[str, str]:
    """Every script `e2e.sh` sends to the E2E Mac, assembled as it assembles them: each `<<'SH'` body, after
    `common.sh` where the line that opens it reads `common.sh` first — the run, and the install step."""
    lines = (SCRIPT.read_text() if text is None else text).split("\n")
    openings = [i for i, line in enumerate(lines) if "<<'SH'" in line]

    def body(start: int) -> list[str]:
        end = lines.index("SH", start + 1)
        return lines[start + 1:end]

    common = next(body(i) for i in openings if 'cat >"$remote_scripts/common.sh"' in lines[i])
    scripts = {}
    for i in openings:
        prefix = common if 'cat "$remote_scripts/common.sh" -' in lines[i] else []
        scripts[f"line {i + 1}"] = "\n".join(prefix + body(i)) + "\n"
    return scripts


class TheRemoteScriptsParseUnderTheMacsOwnBash(unittest.TestCase):
    """**Every script sent to the E2E Mac parses under `/bin/bash`, macOS's Bash 3.2** (third audit of 2026-10-10). The
    E2E Mac happens to run Homebrew's Bash 5 for `bash -s`, so a run passed while the assembled run script did not parse
    under the system's own: Bash 3.2 cannot parse a heredoc inside a command substitution whose body holds an apostrophe
    — four validators did, from `got.get('correction')` to a comment's "card's". AGENTS.md names the same hazard for a
    `python3 -c` block. Parsed as assembled, and a plant of the hazard is refused, so the check can fail."""

    def parses(self, script: str) -> subprocess.CompletedProcess:
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
            handle.write(script)
        try:
            return subprocess.run([BASH, "-n", handle.name], capture_output=True, text=True, timeout=60, check=False)
        finally:
            os.unlink(handle.name)

    def test_the_bash_is_the_systems_own(self):
        version = subprocess.run([BASH, "--version"], capture_output=True, text=True, check=True).stdout
        self.assertIn("version 3.2", version, "the check is only worth having against the Bash macOS ships")

    def test_every_assembled_remote_script_parses(self):
        scripts = remote_scripts()
        self.assertGreaterEqual(len(scripts), 4, f"the assembly found only {sorted(scripts)}")
        for name, script in scripts.items():
            with self.subTest(script=name):
                done = self.parses(script)
                self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_validator_inside_a_substitution_with_an_apostrophe_is_refused(self):
        planted = 'f() {\n    x="$(python3 - <<\'PYPLANT\' || true\nprint(got.get(\'correction\') or \'nothing\')\n' \
                  "# the card's own words\nPYPLANT\n)\"\n}\n"
        self.assertNotEqual(self.parses(planted).returncode, 0, "the plant parsed, so this check cannot fail")


class TheDragHelperIsBoundedBeforeItPresses(unittest.TestCase):
    """`drag-card` refuses a distance no card travels **before it asks Accessibility anything, let alone presses the
    button** (third audit of 2026-10-10): `1e100` trapped on its step count after the button went down, with no mouse-up
    to follow. Built as the install step builds it, and run with each distance; a bounded one goes on to the next check."""

    @classmethod
    def setUpClass(cls):
        cls.scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-drag-card-"))
        source = cls.scratch / "main.swift"
        shutil.copy(HELPERS / "drag-card.swift", source)
        cls.helper = cls.scratch / "drag-card"
        subprocess.run(["xcrun", "swiftc", "-O", str(source), str(RESOLVER), str(REPORTER), "-o", str(cls.helper)], check=True,
                       capture_output=True, timeout=600, env={**os.environ, "TMPDIR": str(cls.scratch)})

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.scratch, True)

    def run_helper(self, dx: str, dy: str) -> subprocess.CompletedProcess:
        return subprocess.run([str(self.helper), "com.example.nothing", "Lookup", "No entry for", dx, dy],
                              capture_output=True, text=True, timeout=60, check=False)

    def test_a_distance_no_card_travels_is_refused_as_usage(self):
        for dx, dy in (("1e100", "0"), ("0", "-1e100"), ("inf", "0"), ("nan", "1"), ("2001", "0"), ("0", "-2001")):
            with self.subTest(dx=dx, dy=dy):
                done = self.run_helper(dx, dy)
                self.assertEqual(done.returncode, 2, done.stderr)
                self.assertIn("at most 2000 points", done.stderr)

    def test_a_bounded_distance_goes_on_to_the_next_check(self):
        done = self.run_helper("80", "-2000")
        self.assertNotEqual(done.returncode, 2, done.stderr)


class EveryHelperWritesItsReportThroughOneCheckedDoor(unittest.TestCase):
    """**No helper hands `JSONSerialization` a report it has not asked `isValidJSONObject` about** (third audit of
    2026-10-10). On Darwin `JSONSerialization.data(withJSONObject:)` *raises* for NaN or infinity — an Objective-C exception
    no `try` sees — so a helper whose report held one frame of NaN died instead of answering (AGENTS.md). Five helpers called
    it directly; they write through `jsonLine` in `shared/report.swift` now, which asks first. A scan for the call, a plant
    the scan refuses, and the door itself run on NaN."""

    REPORT = HELPERS / "shared" / "report.swift"

    @staticmethod
    def direct_calls(sources: dict[str, str]) -> list[str]:
        return [name for name, text in sources.items() if "JSONSerialization.data(" in text]

    def test_no_helper_serialises_a_report_itself(self):
        sources = {path.name: path.read_text() for path in HELPERS.glob("*.swift")}
        self.assertGreaterEqual(len(sources), 15)
        self.assertEqual(self.direct_calls(sources), [], "these serialise a report without asking whether it can be")
        planted = {"plant.swift": 'print(try! JSONSerialization.data(withJSONObject: ["x": 1]))'}
        self.assertEqual(self.direct_calls(planted), ["plant.swift"], "the scan cannot see a direct call")

    def test_the_door_asks_before_it_serialises(self):
        code = "\n".join(line for line in self.REPORT.read_text().split("\n") if not line.strip().startswith("//"))
        self.assertLess(code.index("isValidJSONObject"), code.index("JSONSerialization.data("))

    def test_the_door_answers_nothing_for_a_report_it_cannot_write_and_a_line_for_one_it_can(self):
        scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-report-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        main = scratch / "main.swift"
        main.write_text('print(jsonLine(["x": Double.nan]) == nil ? "refused" : "written")\n'
                        'print(jsonLine(["y": 1, "x": "a"]) ?? "nothing")\n')
        binary = scratch / "door"
        subprocess.run(["xcrun", "swiftc", str(main), str(self.REPORT), "-o", str(binary)], check=True,
                       capture_output=True, timeout=600, env={**os.environ, "TMPDIR": str(scratch)})
        done = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.split("\n")[:2], ["refused", '{"x":"a","y":1}'])


class ALedgerTheBuildCannotOpenStopsTheRun(unittest.TestCase):
    """`ledger_schema_refusal`, asked before anything is installed (2026-10-11). The E2E Mac's ledger is shared by every
    branch's build, and a build refuses a ledger newer than its own schema (`LedgerError.newerSchema`) — so after a
    newer branch's build migrated it, this branch's build recorded no lookup at all, and the lookup stage's ledger check
    failed as "got: nothing" with no word about why. A ledger newer than the build stops the run and says so; one at
    the build's schema or older, or none, does not."""

    def refusal(self, found: str, supported: str) -> tuple[int, str]:
        source = function("ledger_schema_refusal") + '\nledger_schema_refusal "$@"\n'
        done = subprocess.run([BASH, "-c", source, "ledger_schema_refusal", found, supported],
                              capture_output=True, text=True, timeout=60, check=False)
        return done.returncode, done.stdout

    def test_a_newer_ledger_is_refused_by_name(self):
        status, said = self.refusal("14", "13")
        self.assertEqual(status, 1)
        self.assertIn("schema 14", said)
        self.assertIn("13", said)

    def test_a_ledger_this_build_can_open_is_not(self):
        for found in ("13", "12", "0"):
            with self.subTest(found=found):
                self.assertEqual(self.refusal(found, "13"), (0, ""))

    def test_an_unreadable_answer_is_refused_rather_than_passed(self):
        status, said = self.refusal("", "13")
        self.assertEqual(status, 1)
        self.assertTrue(said)


class NoVariableIsFollowedByANonAsciiCharacter(unittest.TestCase):
    """macOS's own `/bin/bash` is 3.2, and it reads the first byte of a character after a bare `$name` as part of the
    name: `"“$term”"` failed on the Mac mini as `term\\xe2: unbound variable` while the Homebrew bash 5 on the other
    E2E Mac read it correctly (2026-10-12). The E2E script runs on whichever bash the test Mac puts first on its PATH,
    so every variable directly before a non-ASCII character — a curly quote, a dash, an ellipsis — is braced."""

    BARE = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]")

    def test_the_pattern_finds_the_shape_that_failed(self):
        # A positive control: a check that cannot fail is not a check.
        self.assertTrue(self.BARE.search('echo "“$term” was never looked up"'))
        self.assertIsNone(self.BARE.search('echo "“${term}” was never looked up"'))

    def test_the_e2e_script_braces_every_such_variable(self):
        found = [f"line {number}: {line.strip()[:100]}"
                 for number, line in enumerate(SCRIPT.read_text(encoding="utf-8").splitlines(), 1)
                 if self.BARE.search(line)]
        self.assertEqual(found, [], "bare variable before a non-ASCII character; write ${name}")

    def test_the_stage_helpers_brace_them_too(self):
        found = [f"{path.name}:{number}"
                 for path in sorted(HELPERS.rglob("*.sh"))
                 for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
                 if self.BARE.search(line)]
        self.assertEqual(found, [])


class TheProviderStubEndsWhenItsPidIsEnded(unittest.TestCase):
    """On the E2E Mac the remote `python3` is a **shell function** (the interpreter chosen by version), and under macOS's
    own bash 3.2 `$!` of a backgrounded function is the wrapping subshell, not the Python inside it. The stage ended that
    pid, the real stub survived with the SSH channel as its stdout, and the run waited on the channel for ever — twice,
    on the Mac mini, 49 minutes and 1 h 47 min after every stage had already finished (2026-10-12). `mbp16`'s bash 5 ends
    the function's process directly, so nothing there ever showed it."""

    def run_it(self, extra: str = "") -> tuple[str, str]:
        scratch = pathlib.Path(tempfile.mkdtemp(prefix="xiaolaidict-stub-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        stub = scratch / "provider-stub.py"
        stub.write_text("import sys, time\ntime.sleep(120)\n")
        script = "\n".join([
            "set -u",
            f'XIAOLAIDICT_PYTHON="{sys.executable}"',
            'python3() { "$XIAOLAIDICT_PYTHON" "$@"; }',
            f'helpers="{scratch}"; provider_stub_log="{scratch}/log"; provider_evidence="{scratch}"',
            function("end_process"), function("start_provider_stub"), function("stop_provider_stub"),
            "start_provider_stub; sleep 1; stop_provider_stub; echo ended-$?",
            "sleep 0.5",
            f'pgrep -f "{stub}" | wc -l',
        ]) + extra
        # To files, never pipes: a stub left holding a pipe is the very fault, and would hang this test as it hung the run.
        with open(scratch / "out", "w") as out, open(scratch / "err", "w") as err:
            subprocess.run([BASH, "-c", script], stdout=out, stderr=err, timeout=60, check=False)
        # Whatever was left running is ended here, so a failing test leaves nothing behind.
        subprocess.run(["pkill", "-f", str(stub)], check=False)
        return (scratch / "out").read_text().split(), (scratch / "err").read_text()

    def test_no_stub_is_left_running_and_none_holds_the_channel(self):
        out, err = self.run_it()
        self.assertEqual(out[0], "ended-0", err)
        self.assertEqual(out[1], "0", "the stub outlived the stage that ended it; the SSH channel stays open on it")


class TheSetupStageClicksTheLanguageModelRowByItsIdentifier(unittest.TestCase):
    """The setup stage clicked a button called "Choose…" and refused when two were enabled, which they are on a Mac that
    has no study dictionary chosen of its own (the dictionary row says "Choose…" too, `SetupView`): MacMini-001,
    2026-10-12, where `mbp16` had one chosen and so showed "Change…" there. A stage that depends on what the machine has
    accumulated measures the machine; the row's button is named by an identifier the view declares."""

    IDENTIFIER = "setup-language-model-choose"

    def test_the_stage_clicks_the_identifier_not_the_shared_label(self):
        stage = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(f'click-element" com.xiaolaidict "{self.IDENTIFIER}"', stage)
        self.assertNotIn('click-element" com.xiaolaidict "Choose…"', stage)

    def test_the_view_declares_that_identifier_once(self):
        view = (REPO / "Sources" / "XiaolaiDictUI" / "SetupView.swift").read_text(encoding="utf-8")
        self.assertEqual(view.count(f'.accessibilityIdentifier("{self.IDENTIFIER}")'), 1)
