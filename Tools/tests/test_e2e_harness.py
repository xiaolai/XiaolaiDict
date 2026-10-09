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
import tempfile
import textwrap
import unittest

from ledger_schema import REPO

SCRIPT = REPO / "Tools" / "e2e.sh"
HELPERS = REPO / "Tools" / "e2e"
RESOLVER = HELPERS / "shared" / "running-app.swift"
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
    # The learning stage's appearance switch: no LaunchServices equivalent. The preflight requires System Events
    # granted whenever the learning stage is asked for.
    "learning_dark_before=$(osascript -e 'tell application \"System Events\" to tell appearance preferences to get dark mode'",
    "true|false) osascript -e \"tell application \\\"System Events\\\" to tell appearance preferences to set dark mode to $learning_dark_before\"",
    "if ! osascript -e \"tell application \\\"System Events\\\" to tell appearance preferences to set dark mode to $wanted_dark\"",
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
                                   str(RESOLVER)], capture_output=True, text=True, timeout=300, check=False,
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
        """`app-health` answering each of `answers` in turn, the last one for ever after."""
        counter = self.fake.root / "health-calls"
        counter.write_text("0")
        cases = "\n".join(f'  {index}) echo \'{json.dumps(answer)}\'; exit {0 if answer["state"] == "ok" else 1} ;;'
                          for index, answer in enumerate(answers[:-1]))
        last = answers[-1]
        Fake.script(self.fake.helpers / "app-health", textwrap.dedent(f"""\
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
        where a stage that selects in it is asked for."""
        self.health([{"state": "notRunning", "detail": "com.apple.TextEdit is not running"}])
        self.assertEqual(self.preflight("lookup").returncode, 0)
        said = "\n".join(self.failures(self.preflight("provider")))
        self.assertIn("TextEdit cannot hold the fixture", said)
        self.assertIn("provider", said)


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
        self.assertTrue(launcher.startswith("#!/bin/sh\nexec "), launcher)
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
