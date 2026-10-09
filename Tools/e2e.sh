#!/bin/bash
# End-to-end tests, on the E2E machine — never on the machine that builds. They run the published
# bundle there, as a user would: launched by LaunchServices, answering through its XPC service,
# surviving that service's death. Which machine, and why it is set up as it is, is in the
# developer's private notes; this script only takes its SSH name.
#
#   e2e.sh <ssh-host> [stage...]   ship .build/XiaolaiDict.app to the host and run stages there
#
# With no stage names every stage runs. With them, only those — a full run costs minutes and most
# changes touch one or two. The names are `KNOWN_STAGES` below, and a name that is not one of them
# is refused: a typo that ran nothing used to print "all stages passed" and exit 0.
#
# Each result is filed by `Tools/e2e-status.sh` against the build it ran on, which is also what
# `make e2e-status` reads. A pass is only a fact about that build, so one carried over from an older
# build is shown as stale rather than as a pass: a green mark that outlives what it tested is worse
# than no mark.
#
# Each stage asserts what it saw, including that the thing it tested happened at all: a test that
# silently did nothing must not look like one that passed.

set -euo pipefail
# Resolved before the `cd`: "$0" is relative to wherever the script was started, and the parse guard
# below reads the script by it. After the `cd`, a run started as ./e2e.sh from Tools/ read a file
# that does not exist.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly SELF
cd "$(dirname "$SELF")/.."

host=${1:?usage: e2e.sh <ssh-host> [stage...]}
shift
STAGES="$*"
# **Validated here, before anything is sent.** `ssh host cmd a b` hands the arguments to a remote
# *shell*, which reparses them — so a stage name carrying `;` or a backtick would run as a command
# there, and the remote allowlist that rejects unknown names never gets the chance. Stage names are
# lower-case words; anything else is refused by shape, on this side of the connection.
case $STAGES in
    *[!a-z\ ]*) echo "e2e: FAIL: a stage name is a lower-case word; got '$STAGES'" >&2; exit 1 ;;
esac
readonly APP=.build/XiaolaiDict.app
readonly REMOTE_DIR=XiaolaiDictE2E
fail() { echo "e2e: FAIL: $*" >&2; exit 1; }
# **One run at a time against a given host.** Two runs share the remote installation, the app's
# preferences, the model stash and the local helper directory — so one quits the other's app
# mid-assertion, restores a preference the other is still using, and `stash_models` refuses
# because a stash it did not make is already there. The second run is refused rather than allowed
# to corrupt the first: an `flock` on a per-host file, released when this process exits.
RUN_LOCK="${TMPDIR:-/tmp}/xiaolaidict-e2e-$(printf '%s' "$host" | tr -c 'A-Za-z0-9' '_').lock"
readonly RUN_LOCK
exec 9>"$RUN_LOCK" || fail "could not open the run lock at $RUN_LOCK"
if command -v flock >/dev/null 2>&1; then
    flock -n 9 || fail "another e2e run is already using $host (lock: $RUN_LOCK)"
else
    # macOS has no flock(1); shlock's pid file is the portable equivalent and is what this uses.
    #
    # **No `trap` of its own here.** This half of the script sets its `EXIT` trap three times, each
    # replacing the last — `$release_lock` is part of every one of them, so whichever is in force when
    # the run ends releases the lock. (`on_exit`, further down, is the *remote* script's trap; it runs
    # on the test Mac, where this lock does not exist — a release registered there died on
    # `RUN_LOCK: unbound variable` and failed a run whose stages had all passed, 2026-10-03.)
    #
    # `shlock` refuses only while the pid it holds is alive, so a lock left by a run killed before its
    # first trap is still taken over by the next run; the traps are so nothing is left by one that ends.
    if ! /usr/bin/shlock -f "$RUN_LOCK.pid" -p $$; then
        fail "another e2e run is already using $host (lock: $RUN_LOCK.pid)"
    fi
fi
stage() { echo; echo "== $*"; }

[ -d "$APP" ] || fail "$APP does not exist; run make first"
ssh_e2e() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" "$@"; }

# **The scripts sent to the E2E machine are parsed here, before anything is shipped.** They are
# quoted heredocs, so `bash -n` on this file skips straight over them and nothing reads them until
# the far machine does — after the bundle has been built and copied. An apostrophe inside a `sed`
# bracket expression closed its quote and ended a run that way, at stage 11 of 11, with nothing
# measured. Parsing costs milliseconds; not parsing cost the run.
# The lock's own two files, removed by every local `EXIT` trap below.
release_lock='rm -f "$RUN_LOCK" "$RUN_LOCK.pid"'
heredocs=$(mktemp -d)
# Removed however this section ends — `fail` exits, and would leave the directory behind.
trap 'rm -rf "$heredocs"; '"$release_lock" EXIT
awk -v dir="$heredocs" '
    /<<'"'"'SH'"'"'/ { inside = 1; n++; file = dir "/remote-" n ".sh"; next }
    inside && /^SH$/ { inside = 0; close(file); next }
    inside { print > file }
' "$SELF"
# **And the Python inside the remote scripts is compiled, for the same reason.** A syntax error in
# a `python3 -c '…'` block is invisible to `bash -n` and to the parse above — the shell sees a
# string — so the far machine finds it ten minutes into a run, after the report it was meant to
# judge has already been produced. Measured 2026-09-23: an f-string whose escaped quotes were valid
# shell and not valid Python, in the check that reads the translation.
#
# **Two spellings, because for a while it only knew one.** This looked for `python3 -c '` alone,
# and every report validator in this file is written the other way — `python3 - <<'MARKER'`. Six
# blocks, including the three that judge the drawer, the settings window and the panel, were never
# compiled by the guard written to compile them: a scan is only as wide as the spelling it searches
# for. Both counts are reported below, so either form falling to zero is loud rather than silent.
python3 - "$SELF" <<'GUARD' || fail "the inline Python in this script does not compile"
import ast
import re
import sys

# **Comment lines are not openers.** This file explains both forms in prose, and a sentence naming
# `python3 - <<'"'"'MARKER'"'"'` matched the search for one — opening a block that was never closed, which
# failed the guard on its own documentation. Only the opener is filtered: a `#` inside a block is
# Python'"'"'s own comment and must reach the parser.
lines = [line for line in open(sys.argv[1]).read().split("\n")]
def isComment(line): return line.lstrip().startswith("#")
blocks = []          # (first line number, what kind, the body)

# **Form one: `python3 -c '…'`.** It opens with a line ending in that quote and closes at the next
# apostrophe, which cannot appear inside it — the body is a single-quoted shell string, so an
# apostrophe would end it there too. That is what makes the extraction exact rather than a guess at
# the shape of the closing line.
current, started = None, 0
for number, line in enumerate(lines, 1):
    if current is None:
        if not isComment(line) and line.rstrip().endswith("python3 -c '"):
            current, started = [], number
    elif "'" in line:
        current.append(line[:line.index("'")])
        blocks.append((started, "python3 -c", "\n".join(current)))
        current = None
    else:
        current.append(line)
if current is not None:
    sys.exit("a python3 -c block is never closed")
dashC = len(blocks)

# **Form two: `python3 - <<'MARKER'`.** Every report validator in this file is written this way, and
# the guard did not know the spelling. A quoted delimiter is required by the match: an unquoted one
# would have the shell substitute into the body before Python ever saw it, which is a different
# defect and one this file forbids elsewhere.
opener = re.compile(r"""python3 .*<<'([A-Za-z_][A-Za-z0-9_]*)'""")
current, marker, started = None, None, 0
for number, line in enumerate(lines, 1):
    if current is None:
        found = None if isComment(line) else opener.search(line)
        if found:
            marker, current, started = found.group(1), [], number
    elif line.rstrip() == marker:
        blocks.append((started, f"heredoc {marker}", "\n".join(current)))
        current = None
    else:
        current.append(line)
if current is not None:
    sys.exit(f"the python3 heredoc opened at line {started} is never closed by {marker}")
heredocs = len(blocks) - dashC

# Each form counted, so one of them falling to zero says so. A single total would let this go on
# reporting a healthy number while half the file stopped being covered.
if not dashC:
    sys.exit("no `python3 -c` block was found, so that half of this check covers nothing")
if not heredocs:
    sys.exit("no `python3 - <<MARKER` block was found, so that half of this check covers nothing")
for started, kind, block in blocks:
    try:
        ast.parse(block)
    except SyntaxError as error:
        sys.exit(f"the {kind} block at line {started}, line {error.lineno} of it: {error.msg}"
                 f"\n    {(error.text or '').rstrip()}")
print(f"{dashC} `python3 -c` and {heredocs} heredoc Python block(s) compile")

# **Nothing here may use a bash 5 builtin.** The shebang is `#!/bin/bash`, which is 3.2 on macOS,
# and under `set -u` an undefined dynamic variable ends the run rather than reading as empty.
# `$EPOCHREALTIME` reached line 893 and would have aborted the deadline stage at its one timing
# measurement; `now_seconds` replaces it. The others are listed because they fail the same way.
bash5 = [
    (number, line.strip())
    for number, line in enumerate(lines, 1)
    if re.search(r"\$\{?(EPOCHREALTIME|EPOCHSECONDS|SRANDOM|BASH_ARGV0)\b", line)
    and not isComment(line)
]
if bash5:
    sys.exit("bash 5 builtins are unbound under this file's `#!/bin/bash` (3.2 on macOS) and "
             "`set -u` ends the run on one:\n    "
             + "\n    ".join(f"line {n}: {t}" for n, t in bash5))

# **A report assignment must not be able to end the run.** `x=$(f)` takes f's exit status, and
# `set -e` acts on it — so a report that came back malformed killed the script before the `flunk`
# written for that very case could run, and the stage recorded a line number in another stage's
# heredoc. Every one of these had a guarded failure path that was unreachable; this is what keeps
# the fourth call site from being written the same way.
unguarded = [
    (number, line.strip())
    for number, line in enumerate(lines, 1)
    if re.search(r"=\$\((run_report|history_report|settings_report|read_point)\b", line)
    and not line.rstrip().endswith("|| true")
    and not isComment(line)
]
if unguarded:
    sys.exit("a report assignment under `set -e` can end the run; write `|| true`:\n    "
             + "\n    ".join(f"line {n}: {t}" for n, t in unguarded))
# The scan must be able to see one. A spelling nobody matches guards nothing.
if not [line for line in lines if re.search(r"=\$\((run_report|history_report|settings_report|read_point)\b", line)]:
    sys.exit("no report assignment was found, so that guard covers nothing")
GUARD

checked=0
for script in "$heredocs"/remote-*.sh; do
    [ -f "$script" ] || continue
    bash -n "$script" 2>"$heredocs/why" \
        || fail "the remote script $(basename "$script") does not parse: $(cat "$heredocs/why")"
    checked=$((checked + 1))
done
rm -rf "$heredocs"
trap - EXIT
# At least one, or the extraction matched nothing and every script "passed" by not existing.
[ "$checked" -gt 0 ] || fail "found no remote scripts to check — the heredoc marker has changed"

# ---------------------------------------------------------------------------------------------
# **The shell both remote scripts need, written once.** Quitting the installed copy and running the
# stages are two SSH sessions, so each carries whatever they share — and two copies of one function
# is one function nobody keeps: these two had already drifted, in the name of a loop variable, and
# both were wrong in the same way. Prepended to each script rather than shipped with the helpers,
# because the first of the two runs before anything has been copied to the machine. It is a quoted
# heredoc like the scripts themselves, so the guard above parses it too; it does move the line
# numbers the remote ERR trap reports, which are relative to the remote script either way.
remote_scripts=$(mktemp -d)
# Removed however this script ends. The later `trap … EXIT` for the run log *replaces* this one
# rather than adding to it, so that line removes this directory as well.
trap 'rm -rf "$remote_scripts"; '"$release_lock" EXIT
cat >"$remote_scripts/common.sh" <<'SH'
# Sets PIDS to the processes started from exactly the executable path $1 — by the executable `ps`
# reports, so arguments LaunchServices adds cannot hide one; by string equality, never a pattern;
# and never by name, which would match any other process called the same.
#
# **Not a `$(…)` function, and that is the whole point.** A `ps` that fails has to stop the run:
# "could not look" is not "nothing is running". Answering on stdout put every caller inside a
# command substitution, where `exit 1` ends only the subshell and leaves the empty string behind —
# so the gate that refuses a model service left over from an earlier run passed on a failed `ps`
# and every check after it measured the old process, and quitting the installed copy reported a
# cold machine that still had the previous build running. `Tools/build-bundle.sh` has `find_pids`
# in this shape for this reason, with the same comment beside it.
find_pids() {
    local table pid executable
    table=$(ps -axww -o pid=,comm=) || { echo "ps failed, so whether $1 is running cannot be told" >&2; exit 1; }
    PIDS=()
    while read -r pid executable; do
        [ "$executable" != "$1" ] || PIDS+=("$pid")
    done <<<"$table"
}

is_running() {  # $1: an executable path. Stops the run, rather than answering, if `ps` fails.
    find_pids "$1"
    [ "${#PIDS[@]}" -gt 0 ]
}
SH

# ---------------------------------------------------------------------------------------------
stage "machine"
# The whole point is a second machine. Refuse this one, whatever the SSH name resolves to.
local_uuid=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}')
remote=$(ssh_e2e bash -s <<'SH'
uuid=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}')
printf '%s|%s|%s|%s|%s\n' "$uuid" "$(scutil --get LocalHostName)" "$(sysctl -n hw.model)" \
    "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
SH
) || fail "cannot reach $host over SSH"
IFS='|' read -r remote_uuid remote_name remote_model remote_os remote_build <<<"$remote"
[ -n "$remote_uuid" ] || fail "$host did not report a hardware UUID"
[ "$remote_uuid" != "$local_uuid" ] || fail "$host is this Mac; E2E tests run on the E2E machine, not the one that builds"
echo "$remote_name — $remote_model, macOS $remote_os ($remote_build)"

# ---------------------------------------------------------------------------------------------
# Runs on the E2E machine: quit a running copy of the E2E bundle, by its exact executable path.
remote_quit() {
    cat "$remote_scripts/common.sh" - <<'SH' | ssh_e2e bash -s -- "$REMOTE_DIR"
set -euo pipefail
app="$HOME/$1/XiaolaiDict.app"
for exe in "$app/Contents/MacOS/XiaolaiDict" "$app/Contents/XPCServices/XiaolaiDictService.xpc/Contents/MacOS/XiaolaiDictService" \
           "$app/Contents/XPCServices/XiaolaiDictModelService.xpc/Contents/MacOS/XiaolaiDictModelService"; do
    find_pids "$exe"
    [ "${#PIDS[@]}" -eq 0 ] || kill -TERM "${PIDS[@]}"
    for _ in $(seq 1 50); do is_running "$exe" || continue 2; sleep 0.1; done
    echo "still running after 5 s: $exe" >&2; exit 1
done
SH
}

stage "install"
# The selection helpers, built here for the same macOS and architecture, and the files they select in.
#
# **Each is built with the one resolver every helper shares**, `Tools/e2e/shared/running-app.swift`: macOS 27 reports
# some running apps' process as -1, and a helper that trusted it answered "no focused element" about an app that was
# fine — every Accessibility request to pid -1 fails (measured 2026-10-08, TextEdit). A file compiled beside another
# holds top-level code only as `main.swift`, so each helper is copied to that name in a directory of its own; a
# compile error names `.build/e2e-src/<helper>/main.swift`. `Tools/tests/test_e2e_harness.py` compiles them all the
# same way on every `make test`, so a helper that does not build is found before a run rather than at its start.
rm -rf .build/e2e .build/e2e-src && mkdir -p .build/e2e
for helper in select-text select-web keys panel claim-escape word-point window-frame menu-click screen-state close-window click-element on-screen session-access app-health drawer-interactions; do
    mkdir -p ".build/e2e-src/$helper" && cp "Tools/e2e/$helper.swift" ".build/e2e-src/$helper/main.swift" \
        && swiftc -O ".build/e2e-src/$helper/main.swift" Tools/e2e/shared/running-app.swift -o ".build/e2e/$helper" \
        || fail "could not build $helper"
done
# **`-p`, so a fixture that has not changed is not rewritten there.** `rsync -a` below sends a file whose time differs,
# and a plain `cp` gave every fixture a new time on every run — so `notes.txt` was replaced under the TextEdit
# document holding it open, each run, a change TextEdit has to reconcile and that nothing in a run needs.
cp -p Tools/e2e/notes.txt Tools/e2e/page.html Tools/e2e/ladder-gate.py Tools/e2e/library-layout.py Tools/e2e/review.py Tools/e2e/reminder.py Tools/e2e/provider-stub.py .build/e2e/
remote_quit || fail "could not quit the running E2E copy"
ssh_e2e "mkdir -p '$REMOTE_DIR'"
rsync -a --delete "$APP" .build/e2e "$host:$REMOTE_DIR/" || fail "could not copy the bundle and helpers"
local_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
remote_version=$(ssh_e2e "/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '$REMOTE_DIR/XiaolaiDict.app/Contents/Info.plist'")
[ "$local_version" = "$remote_version" ] || fail "shipped build $local_version, found $remote_version"
ssh_e2e "codesign --verify --strict --deep '$REMOTE_DIR/XiaolaiDict.app'" || fail "the shipped bundle does not verify there"
echo "build $remote_version installed and verified"

# ---------------------------------------------------------------------------------------------
# The remaining stages run there, in one session, and report each result as one line.
stage "run${STAGES:+: $STAGES}"
RUN_LOG=$(mktemp)
# This *replaces* the trap that removes the shared shell, so it removes that too.
trap 'rm -f "$RUN_LOG"; rm -rf "$remote_scripts"; '"$release_lock" EXIT
# Assembled into a file rather than piped into ssh, so `${PIPESTATUS[0]}` below is still the ssh —
# with a `cat … |` in front of it, it would be the cat, and every run would read as having passed.
cat "$remote_scripts/common.sh" - >"$remote_scripts/run.sh" <<'SH'
set -euo pipefail
app="$HOME/$1/XiaolaiDict.app"; exe="$app/Contents/MacOS/XiaolaiDict"
service="$app/Contents/XPCServices/XiaolaiDictService.xpc/Contents/MacOS/XiaolaiDictService"
failures=0
# The stages asked for; none means all of them.
# `${@:2}`, not `$2`: ssh rejoins its arguments into one command line and the remote shell splits
# them again, so a quoted "a b c" arrives as three separate arguments. Reading only $2 ran the
# first stage named and silently skipped the rest.
WANTED=("${@:2}")
# **Every stage named has to exist.** A typo ran no stage at all, printed "all stages passed", and
# exited 0 — a green mark for a run that tested nothing, which is the one thing this file is written
# to make impossible. This is the only list of the names; the header points at it rather than
# naming them again, because two lists of one thing are one list nobody keeps.
KNOWN_STAGES=(launch lookup crash accessibility selection shortcut deadline hover drawer recogniser setup scenes panel provider model learning review reminder)
for wanted in ${WANTED[@]+"${WANTED[@]}"}; do
    found=""
    for known in "${KNOWN_STAGES[@]}"; do [ "$wanted" = "$known" ] && { found=yes; break; }; done
    [ -n "$found" ] || {
        echo "no stage called '$wanted'; the stages are: ${KNOWN_STAGES[*]}" >&2
        exit 2
    }
done
# **Until a stage claims it, what is running is setup**, and setup is a name the record can hold.
# Left empty, `flunk` before the first `want` printed a RESULT line with no stage on it, which the
# recording loop skips — so the menu-bar gate below failed the run while every stage's *previous*
# pass stayed in the table, unmarked. A green mark that outlives what it tested is worse than none.
STAGE=setup
want() {  # want <name>: is this stage wanted? Also names it, for the result lines.
    STAGE=$1
    [ ${#WANTED[@]} -eq 0 ] && return 0
    local w
    for w in "${WANTED[@]}"; do [ "$w" = "$1" ] && return 0; done
    return 1
}
# RESULT lines are for the caller to record; PASS/FAIL lines are for a person to read.
pass() { echo "PASS  $*"; printf 'RESULT\t%s\tpass\n' "$STAGE"; }
# **The names of the stages that failed, not just a count of checks.** `failures` counts
# assertions, so a stage failing three of its checks used to report "3 stage(s) failed" beside a
# board listing one — two numbers for the same run, disagreeing, the wrong one first. A space-padded
# string because this is bash 3.2, which has no associative arrays; `case` is safe in a function
# body, unlike inside `$( )`, which this file records separately.
failed_stages=" "
flunk() {
    echo "FAIL  $*"
    failures=$((failures + 1))
    case "$failed_stages" in
        *" $STAGE "*) ;;
        *) failed_stages="$failed_stages$STAGE " ;;
    esac
    printf 'RESULT\t%s\tfail\n' "$STAGE"
}

# **A stage that dies part-way is a failed stage, and says where it died.** `set -e` ends this
# script at the first unguarded failure, silently, and every assertion after it simply never runs
# — which a per-stage record reads as "no failures". Measured: a helper that exits 1 by design,
# inside an unguarded `$(…)`, ended the scenes stage after its first four checks. Those four
# happened to include a failure; had they all passed, the stage would have been recorded green with
# half of it never run. `-E` so the line is known even when the death is inside a function.
set -E
finished=false
died_at=""
trap 'died_at=$LINENO' ERR
# A function, run from the one EXIT trap. A stage with cleanup of its own registers it with
# `at_exit` rather than setting a trap — `trap cleanup EXIT` alone *replaces* this, and the deadline
# stage once did exactly that: every stage after it lost the detector.
# Cleanup a stage needs however the script ends — resuming a stopped service, putting back a
# setting it changed. Registered, run in order by `on_exit`, and each tolerated to fail: a stage
# used to install its own EXIT trap, which *replaced* whatever was there, so every stage after it
# lost the check below.
cleanups=()
at_exit() { cleanups+=("$1"); }
on_exit() {
    local cleanup i
    # **Reverse registration order, and a failure is recorded rather than swallowed.**
    #
    # *Reverse* because a later cleanup can depend on an earlier one not having run yet:
    # `restore_setup_shown` is registered before any launch, `unstash_models` inside the setup
    # stage — and unstashing restarts the app, which writes that very flag. In registration order
    # the flag was restored and then overwritten by the restart that followed it, so the machine
    # kept this run's value under a green mark. Releasing in the reverse of acquisition is the
    # ordering that makes a dependency between two cleanups expressible at all.
    #
    # *Recorded* because `|| true` made an unsuccessful restoration indistinguishable from a
    # successful one: `unstash_models` could fail to put three gigabytes of weights back and the run
    # still exited 0. Each is still allowed to fail without stopping the others — a cleanup that
    # gives up must not strand the ones after it — but the run is no longer called a pass.
    for (( i = ${#cleanups[@]} - 1; i >= 0; i-- )); do
        cleanup=${cleanups[$i]}
        "$cleanup" || {
            echo "FAIL  cleanup: $cleanup did not finish, so this machine may be left changed"
            failures=$((failures + 1))
            printf 'RESULT\tcleanup\tfail\n'
        }
    done
    # **And every run reports its cleanups**, so a `cleanup fail` filed by an earlier run of this build does not stand
    # after a run that put everything back — it did, on 2026-10-08, because a result was written only on a failure.
    # `e2e-status.sh record` takes a stage as failed when any of its lines failed, so this pass cannot cover a failure
    # printed above, or by `restore_default`.
    printf 'RESULT\tcleanup\tpass\n'
    if [ "$finished" != true ]; then
        echo "FAIL  $STAGE: the script stopped at line ${died_at:-?} before the stage finished"
        printf "RESULT\t%s\tfail\n" "$STAGE"
    fi
    # **The status is settled here, last.** The trap runs *after* the script's own exit line, so a
    # cleanup that failed — a setting this run could not put back — was printed in the table and
    # then exited 0 over the top of it. `exit` inside an EXIT trap replaces the status and does not
    # re-enter the trap.
    [ "$failures" -eq 0 ] || exit 1
}
trap on_exit EXIT

# restore_default <key> <had> <value> [type-flag]: puts a setting back the way this run found it.
#
# **`defaults write` prints a page of usage and still exits 0** when the value is empty — measured
# 2026-09-23 with `-bool ""`, which is how a restore with nothing to restore dumped that page into
# a run that had just reported every stage green, with nothing to say which setting it was. So an
# empty value deletes the key instead, and **what was written is read back**: an exit code that is
# 0 either way is not evidence that the reader got their setting back.
restore_default() {
    local key=$1 had=$2 wanted=$3 flag=${4:-} value=$3 now
    if [ "$had" != yes ] || [ -z "$wanted" ]; then
        defaults delete com.xiaolaidict "$key" 2>/dev/null || true
        # **Read back, exactly as the write path does.** `defaults delete` on a key that cfprefsd is
        # still holding exits 0 having changed nothing, so the branch that puts a *missing* setting
        # back was the one branch of this function with no evidence behind it — the asymmetry is the
        # defect, since "there was no such key" is the commonest case on a fresh machine.
        if defaults read com.xiaolaidict "$key" >/dev/null 2>&1; then
            echo "FAIL  cleanup: $key still exists after being deleted, so this machine keeps a setting this run made"
            failures=$((failures + 1))
            printf 'RESULT\tcleanup\tfail\n'
        fi
        return 0
    fi
    # **`defaults read` prints a boolean as 1, and `defaults write -bool` does not accept 1.** Its
    # grammar is `true | false | yes | no`; given `1` it prints its usage, writes nothing, and exits
    # **0**. So the reader's setup flag was never actually put back by any run, and the only reason
    # the machine looked right afterwards is that the app writes that flag itself.
    if [ "$flag" = -bool ]; then
        case $value in 1|true|yes) value=true ;; 0|false|no) value=false ;; esac
    fi
    if [ -n "$flag" ]; then
        defaults write com.xiaolaidict "$key" "$flag" "$value"
    else
        defaults write com.xiaolaidict "$key" "$value"
    fi
    # Compared against what was *read*, not what was written: a boolean goes in as `true` and comes
    # back as `1`, and comparing the written form would call a correct restore a failure.
    now=$(defaults read com.xiaolaidict "$key" 2>/dev/null || echo "")
    if [ "$now" != "$wanted" ]; then
        # **A run that changed the reader's settings and could not change them back is not a run
        # that passed.** Printed and swallowed, this left the machine altered under a green mark,
        # and the next run then measured the setting this one forced.
        echo "FAIL  cleanup: $key was not put back — wanted '$wanted', found '$now'"
        failures=$((failures + 1))
        printf "RESULT\tcleanup\tfail\n"
    fi
}

outcomes() { python3 -c 'import json,sys; print(" ".join(json.loads(l)["outcome"] for l in sys.stdin if l.strip()))'; }
# expect <json> key=value ...: every field as stated (a value starting with * matches as a suffix,
# which is how a path is asserted without the directory it happens to be under); prints the
# mismatches.
expect() {
    python3 - "$@" <<'PY'
import json, sys
try:
    got = json.loads(sys.argv[1])
except ValueError:
    sys.exit(f"not JSON: {sys.argv[1]}")
wrong = []
for pair in sys.argv[2:]:
    key, want = pair.split("=", 1)
    have = str(got.get(key))
    # The reports are Swift's, so "nil" is how a missing value is written when asking for one.
    # Python stringifies JSON null as "None", and comparing those two spellings fails a test that
    # is actually passing.
    if want == "nil":
        if got.get(key) is None: continue
        wrong.append(f"{key}: wanted nothing, got {have!r}")
        continue
    ok = have.endswith(want[1:]) if want.startswith("*") else have == want
    if not ok: wrong.append(f"{key}: wanted {want!r}, got {have!r}")
sys.exit("; ".join(wrong) if wrong else 0)
PY
}
# select_then_read <label> <bundle-id> <selector...> -- <expectations...>
select_then_read() {
    local label=$1 app_id=$2; shift 2
    local selector=()
    while [ "$1" != -- ]; do selector+=("$1"); shift; done; shift
    local why reading
    if ! why=$("${selector[@]}" 2>&1); then flunk "$label: could not select ($why)"; return; fi
    reading=$("$exe" --read-selection "$app_id" 2>&1 || true)
    if why=$(expect "$reading" "$@" 2>&1); then pass "$label"; else flunk "$label: $why"; fi
}

# Shared by several stages, so it is defined once and before any of them. Written inside the
# stage that first needed it, selecting stages turned this into an unbound variable.
helpers="$HOME/$1/e2e"
# Where this run keeps what a person may want to look at afterwards: the installed bundle's own directory.
e2e_home="$HOME/$1"
# The browser the hover stage reads through the bounds-scan dialect, asked for by the preflight and the stage alike.
chrome_app="/Applications/Google Chrome.app"
ledger="$HOME/Library/Application Support/XiaolaiDict/ledger.sqlite"

# Where this run's reports are written. **Its own directory, made fresh and readable only by this
# user**: the fixed `/tmp/xiaolaidict-<name>.json` names they replaced are in a world-writable
# sticky directory, opened with `>` and `open --stdout`, both of which follow a symlink — so anyone
# on the machine could choose what those writes landed on, and two runs at once clobbered each
# other. The backdrop captures keep their fixed names: the bundle writes those, and they are kept
# on purpose for looking at afterwards.
reports=$(mktemp -d /tmp/xiaolaidict-e2e.XXXXXX) || { echo "could not make a reports directory" >&2; exit 1; }
chmod 700 "$reports"
drop_reports() { rm -rf "$reports"; }
at_exit drop_reports

# **A query that failed is not a ledger with no rows.** Falling back to 0 made every historical
# lookup count as evidence of the one the stage had just driven — the baseline is what tells this
# run's row from every earlier run's, so a baseline nobody could read has to stop the stage.
newest_row_id() {
    local answer
    if ! answer=$(sqlite3 -readonly "$ledger" "select coalesce(max(id), 0) from lookups" 2>&1); then
        flunk "the ledger baseline could not be read, so no row count below means anything ($answer)"
        printf '%s' "-1"
        return 0
    fi
    printf '%s' "$answer"
}
# Rows for one lookup: newer than id $1, of the word $2, read in the app $3. Both halves narrow it
# — the ledger holds other lookups of the same word from earlier runs and other stages, and the
# deadline stage looks up this very word. Quotes in the word are doubled rather than trusted: the
# callers pass literals this script chose, and a helper that is only safe while that stays true is
# a trap for whoever passes something else.
sql_text() { printf "%s" "${1//\'/\'\'}"; }
rows_of() { sqlite3 -readonly "$ledger" "select count(*) from lookups where id > $1 and surface = '$(sql_text "$2")' and source_app = '$(sql_text "$3")'" 2>/dev/null || echo 0; }
row_id_of() { sqlite3 -readonly "$ledger" "select coalesce(min(id), 0) from lookups where id > $1 and surface = '$(sql_text "$2")' and source_app = '$(sql_text "$3")'" 2>/dev/null || echo 0; }

# **The ledger row is written after the panel closes, not before it.** `LookupRunner.run` returns
# the row only once the sense resolver has answered, and that can be a model round trip — so a
# count read the instant the panel goes away is reading before the write, not instead of it.
# Measured 2026-09-21: the row landed after the assertion twice in a row, and the run that followed
# each time found it already there — 97, then 98, then 99, one per run, every one correct, every
# one counted a run too late. Waits for **this lookup's** row, and prints how long it waited so the
# number stays visible rather than becoming a bound nobody reads. Fails by timing out, so a row
# that is never written is still a failure.
#
# It waits for the word, not for the count and not for the newest id: either of those is satisfied
# by *any* row landing in the meantime, and the assertion that follows would then read somebody
# else's lookup — failing the stage for something the app got right. What is asserted afterwards is
# this lookup's own row, and that there is exactly one of it.
row_after() {
    local baseline=$1 surface=$2 app=$3 waited=0
    while [ "$(rows_of "$baseline" "$surface" "$app")" -eq 0 ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
    printf '%s' "$((waited / 10)).$((waited % 10))"
}

# **A lookup's sense is written on a later await than its row**, so the row appearing says nothing
# about it. Since ADR-0044 a reading is recorded before its sense is chosen; waiting for the row and
# then reading the sense measured that race, not the path — on the E2E Mac lookups 59 and 60 read as
# "neither a choice nor an abstention" and carried `chosen_by=model` moments later. This waits for
# this lookup's own answer, up to 30 s, and sets `sense_chosen`, `sense_abstained` and `sense_waited`
# (globals: bash 3.2 has no other way to hand back three values).
sense_after() {
    local id=$1 waited=0
    sense_chosen=""; sense_abstained=""
    while [ "$waited" -lt 300 ]; do
        sense_chosen=$(sqlite3 -readonly "$ledger" "select coalesce(group_concat(chosen_by), '') from sense_encounters where lookup_id = $id and chosen_by is not null" 2>/dev/null || echo "")
        sense_abstained=$(sqlite3 -readonly "$ledger" "select coalesce(sense_abstention, '') from lookups where id = $id" 2>/dev/null || echo "")
        [ -n "$sense_chosen$sense_abstained" ] && break
        sleep 0.1; waited=$((waited + 1))
    done
    sense_waited="$((waited / 10)).$((waited % 10))"
}

# **A wall clock with sub-second resolution, on the shell this file actually runs under.**
#
# `$EPOCHREALTIME` is bash 5. The shebang here is `#!/bin/bash`, which on macOS is **3.2** — this
# file says so itself elsewhere, where it explains why it has no associative arrays — and 3.2 does
# not define it. Under `set -u` that is not a zero, it is `unbound variable` and the end of the
# run: the one measurement in the deadline stage that needs a clock would have taken the stage
# with it. Verified 2026-09-30: `/bin/bash -c 'set -u; x=$EPOCHREALTIME'` prints
# `EPOCHREALTIME: unbound variable`.
#
# Python because it is already a hard dependency of this file — every report validator is one —
# so it costs no new requirement, and `date +%s.%N` is GNU-only anyway.
now_seconds() { python3 -c 'import time; print(f"{time.monotonic():.6f}")'; }

# **A stage establishes what it needs rather than inheriting it.** `make e2e STAGES="deadline"`
# assumed TextEdit already held the fixture and a dictionary service was already running, and
# `STAGES="drawer"` assumed the ledger already had rows — all of them side effects of stages that
# had not run. A single stage is how anyone debugs one, and each of these failed on a machine
# where nothing was wrong.
# **Open and in front, not merely running.** The lookup shortcut reads the selection of the app in
# front; a TextEdit that was running behind Finder — which is what a relaunch of XiaolaiDict leaves
# when nothing else has activated it — answered "Nothing to look up" three presses in a row and the
# stage called the fixture uncreatable (E2E Mac, 2026-10-02). `open -a` on a running app activates it.
# **Which app is in front is read from `on-screen`, never by scripting System Events** (2026-10-08): an Apple event from
# this SSH session needs an Automation grant of its own, and asked for the first time it raises an Allow prompt on the
# test Mac's screen with nobody there to answer it.
ensure_fixture_open() {
    local front=""
    open -a TextEdit "$helpers/notes.txt"
    for _ in $(seq 1 40); do
        front=$("$helpers/on-screen" com.apple.TextEdit 2>/dev/null | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p' || true)
        [ "$front" = com.apple.TextEdit ] && return 0
        sleep 0.25
    done
    echo "the TextEdit fixture would not come to the front (${front:-nothing} is in front)" >&2
    return 1
}

# **The lookup panel alone, out of a report of every window.** Two checks asked whether "meeting"
# was anywhere in the app, and an open Library answers yes for ever: its cards carry the same
# sentence. Measured 2026-10-02 — a dismissed panel read as still showing, and one filled panel read
# as two. Fails loudly on a report it cannot parse, so a broken report is never an empty answer.
lookup_windows() {
    python3 -c '
import json, sys
report = json.loads(sys.stdin.read(), strict=False)
report["windows"] = [w for w in report["windows"] if w.get("title") == "Lookup"]
print(json.dumps(report, ensure_ascii=False))'
}

# Drives one real lookup, which is what starts the dictionary service and what puts a row in the
# ledger. Used by the stages that need either and create neither.
#
# **Pressed until it takes, and every refusal says which step refused.** The menu-bar item answering
# is not the hot key being registered: straight after a launch on an empty ledger the first press
# was lost one run in two (E2E Mac, 2026-10-02: failed, passed, failed on one bundle), and the
# caller could only say "could not be created".
ensure_one_lookup() {
    ensure_fixture_open || return 1
    local baseline attempt why
    baseline=$(newest_row_id)
    assert_default_shortcut || true
    for attempt in 1 2 3; do
        why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1) \
            || { echo "could not select the fixture word: $why" >&2; return 1; }
        "$helpers/keys" 2 control option
        row_after "$baseline" meeting com.apple.TextEdit >/dev/null
        [ "$(rows_of "$baseline" meeting com.apple.TextEdit)" -eq 0 ] || break
        echo "press $attempt of the lookup shortcut recorded nothing in 10 s" >&2
    done
    [ "$(rows_of "$baseline" meeting com.apple.TextEdit)" -ne 0 ] || return 1
    if [ "${1:-}" = answered ]; then
        local fresh
        fresh=$(row_id_of "$baseline" meeting com.apple.TextEdit)
        for _ in $(seq 1 80); do
            [ "$(sqlite3 "$ledger" "SELECT result FROM lookups WHERE id=$fresh;")" != pending ] && break
            sleep 0.25
        done
        [ "$(sqlite3 "$ledger" "SELECT result FROM lookups WHERE id=$fresh;")" != pending ] || { echo "lookup remained pending after 20 seconds" >&2; return 1; }
    fi
    "$helpers/keys" 53 2>/dev/null || true
    [ "$(row_id_of "$baseline" meeting com.apple.TextEdit)" -ne 0 ]
}

# **Four stages press ⌃⌥D, so one of them has to check it is the shortcut.**
#
# Nothing established that: a reader who had customised the combination — which the Settings pane
# exists to let them do — made every lookup-driving stage fail with "no answer card", a sentence
# about the product over a harness pressing the wrong keys. `lookUpShortcut` is absent while the
# default is in force, so absent is the answer these stages need; anything else is named.
assert_default_shortcut() {
    local saved
    saved=$(defaults read com.xiaolaidict lookUpShortcut 2>/dev/null || true)
    [ -z "$saved" ] && return 0
    flunk "this Mac has a customised lookup shortcut, and these stages press ⌃⌥D: $saved"
    return 1
}

# **Why a lookup produced nothing, when the app itself knows.**
#
# Seven checks in this file drive a real lookup, and every one of them fails the same way on a Mac
# where the app has not been granted Accessibility: it cannot read the selection, so no row is
# written. They reported that as "no answer card", "0 rows for this lookup" and "the lookup wrote
# no ledger row" — three sentences for one cause, none of them naming it, each reading as a defect
# in the thing being measured. Measured 2026-09-30: `com.xiaolaidict|0` in the system TCC database,
# and every one of those seven red.
#
# The app says so itself, on the panel, and this is that sentence — empty when the app is not
# refusing for want of a permission, so a caller can lead with it and fall back to its own words.
# **Not a guess from the absence of a row**: a missing grant and a broken lookup path both write
# nothing, and only the app can tell them apart.
#
# **It cannot fail, and that is load-bearing.** "No notice" is an answer, not an error. The first
# version ended in `grep | head`, and this file runs under `pipefail`: with no match the grep's 1
# reached the caller's `refusal=$(missing_grant)`, which `set -e` turned into the end of the run —
# the model stage died before reaching a single one of its own assertions. The very class of
# defect this helper was added to explain, reintroduced by the explanation.
missing_grant() {
    local shown notice
    shown=$("$helpers/panel" com.xiaolaidict 2>/dev/null) || return 0
    notice=$(printf '%s' "$shown" | grep -o "XiaolaiDict needs [A-Za-z ]*access" | head -1) || true
    printf '%s' "$notice"
    return 0
}

# **One way to run an in-bundle report**, with its budget and its cleanup — defined here, before
# every stage, because more than one stage uses it: defined inside the first that did, a run of
# the other stage alone died on `run_report: command not found`. Each report used to
# carry its own copy of this, and the history report's gave up after 60 s against an instrument
# whose own deadlines allow nearly 100: three captures of 30 s each, plus settling, appearing and
# closing. A report past the harness's patience was declared silent and left running — still able
# to capture the screen during whatever stage came next.
# run_bounded <flag> <out> <seconds> <label>: runs an in-bundle report directly — no window, so no
# LaunchServices — and gives up on it at the deadline. Its stderr goes to the terminal as well as to
# a file, so a download that takes half an hour is visible while it runs rather than afterwards.
# Answers with the report's own exit status, and fails the stage on a non-zero one. Both of the
# model stage's reports go through it: each had grown its own copy of the waiting, and one of them
# had none at all.
#
# **The exit status is the report's verdict, and throwing it away made every finished run a pass.**
# An instrument that writes plausible JSON and then exits non-zero — one that measured a service it
# could not reach, or a rung that never answered — was recorded as having passed, because the only
# thing looked at afterwards was whether some keys could be read out of its output.
run_bounded() {
    local flag=$1 out=$2 budget=$3 label=$4
    : > "$out"
    "$exe" "$flag" >"$out" 2> >(tee "$reports/${label}.err" >&2) &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$budget" ]; do sleep 1; waited=$((waited + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        flunk "$STAGE: $flag did not finish within $((budget / 60)) minutes"
        return 1
    fi
    local status=0
    wait "$pid" || status=$?
    if [ "$status" -ne 0 ]; then
        flunk "$STAGE: $flag exited $status"
    fi
    return "$status"
}

# **One place that ends an instrument, and it matches *this* bundle rather than any bundle.**
#
# `pkill -f "MacOS/XiaolaiDict $flag"` matched a substring of the command line, so a second checkout's
# copy of the app, or another run on this machine, was a candidate for the kill — including `pkill -9`.
# Anchored to `$exe`, the absolute path of the bundle under test, the pattern can only reach processes
# this run started.
#
# And it is **waited for before it is killed, then insisted on**, because an instrument that is still
# running is not finished with the screen: two simultaneous `SCScreenshotManager` captures deadlock,
# 6 trials of 6. `read_point` returned as soon as output appeared and never reaped anything, so the
# recogniser stage's grid started each capture beside the last one still running — the harness
# breaking a rule this project measured and wrote down.
# `pgrep -f` takes a **regular expression**, and a filesystem path is not one: a `+` or a `.` in
# the checkout's name changes what it matches, and an unanchored pattern reaches any process whose
# command line merely contains this path. Escaped, and anchored at the start.
#
# **Anchored at the start only.** A trailing `$` would be tighter and is the wrong trade: an
# instrument launched with any further argument would stop matching, and a pattern that matches
# nothing makes this function return "already finished" — the loud failure becomes a silent one,
# and the next capture starts beside a screen recorder still running.
escaped_pattern() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\\]/\\&/g'; }

end_instrument() {  # end_instrument <flag>: wait for this bundle's instrument to end, then insist
    local pattern
    pattern="^$(escaped_pattern "$exe $1")"
    for _ in $(seq 1 40); do pgrep -f "$pattern" >/dev/null || return 0; sleep 0.25; done
    pkill -f "$pattern" 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -f "$pattern" >/dev/null || return 0; sleep 0.25; done
    pkill -9 -f "$pattern" 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -f "$pattern" >/dev/null || return 0; sleep 0.25; done
    # **A flunk, not a note.** An instrument that survives its own killing can still capture the
    # screen, and two simultaneous captures deadlock — measured, 6 of 6. Printed as a note, every
    # check after it ran beside a known-live recorder and reported whatever it got.
    flunk "$1 would not die; every capture after this would run beside it"
    return 1
}

consume_verdicts() {  # consume_verdicts <stage-name> <verdicts>: PASS/NOTE/NOTRUN/SKIPPED/FAIL lines, then DONE
    # A here-string, never a pipe: `flunk` increments a counter, and a pipe would run it in a
    # subshell where the increment is thrown away — a stage that reported its failures and then
    # passed.
    local name=$1 verdicts=$2 verdict text
    while IFS=$'\t' read -r verdict text; do
        case "$verdict" in
            PASS) pass "$text" ;;
            NOTE) echo "NOTE  $text" ;;
            # A claim that could not be exercised here, with the reason: neither a pass nor a failure,
            # and never silent.
            NOTRUN) echo "NOT RUN  $text" ;;
            # **A check whose prerequisite this Mac lacks and only a person can supply** — a CLI not installed, nobody
            # signed in to it. Said by name, with what the app's own preflight answered, and recorded as nothing: the
            # stage's other checks are what pass it, so a skip can never be the reason a stage is green.
            SKIPPED) echo "SKIPPED  $text" ;;
            FAIL) flunk "$text" ;;
        esac
    done <<<"$verdicts"
    # **The marker, or the stage did not finish.** A validator that died part-way emits some
    # PASS lines and no DONE, and without this the stage is green on the ones it reached.
    printf '%s' "$verdicts" | grep -qx DONE \
        || flunk "$name: the report's validator stopped before it finished: $(printf '%s' "$verdicts" | tail -3)"
}

run_report() {  # run_report <flag> <budget-seconds>: the report's JSON on stdout, or nothing
    local flag=$1 budget=$2 name=${1#--}
    local out="$reports/$name.json" err="$reports/$name.err"
    rm -f "$out" "$err"
    open -n --stdout "$out" --stderr "$err" "$app" --args "$flag"
    local waited=0
    while [ ! -s "$out" ] && [ "$waited" -lt $((budget * 2)) ]; do sleep 0.5; waited=$((waited + 1)); done
    # Past its budget it is stopped; within it, it exits by itself once it has written. Waited for
    # either way, so no report outlives its stage.
    [ -s "$out" ] || pkill -f "$exe $flag" 2>/dev/null || true
    end_instrument "$flag" || true
    # **The contract in this function's own first line, now enforced: valid JSON, or nothing.**
    # An instrument launched through `open` has no exit status to read — LaunchServices returns as
    # soon as it has started the process — so the thing that *can* be checked is the product. A
    # report that printed a prefix and died, or wrote a diagnostic where JSON belongs, satisfied
    # `[ -s "$out" ]` and reached the caller as text, where one caller parsed it and another only
    # asked whether it was empty. That divergence is the defect: the drawer stage validated the JSON
    # itself while the settings stage accepted anything non-empty.
    #
    # Nothing is printed and the status is non-zero when the report is not JSON, so every caller's
    # existing empty check now covers a malformed report too. The reason stays in `$err`, which is
    # what each caller tails into its failure message.
    #
    # **Every caller must write `x=$(run_report …) || true`.** Under `set -e` a bare assignment
    # takes the substitution's status, so returning 1 here ended the *run* instead of reaching the
    # `flunk` each caller had already written for exactly this case — measured: the panel stage
    # produced no output at all, and the record read "the script stopped at line 1701", a line in
    # another stage's heredoc. The guard below checks the spelling at every call site.
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null; then
        return 1
    fi
    cat "$out" 2>/dev/null || true
}

# provider_status_verdicts <stage> <source> <tier> <readiness: ready|none|cli> <report>: PASS/FAIL/SKIPPED lines and DONE
# about one `--provider-status` report (ADR-0053) — where the language-model source runs, what it may be sent, and what
# its trivial question came to. Defined before every stage: the provider stage asks it of every source, and the model
# stage of the bundled model it selects.
provider_status_verdicts() {
    python3 - "$1" "$2" "$3" "$4" "$5" 2>&1 <<'PYSTATUS' || true
import json, sys
stage, source, tier, wanted = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def say(ok, good, bad): print(("PASS\t" + good) if ok else ("FAIL\t" + bad))
try:
    r = json.loads(sys.argv[5])
except ValueError:
    r = None
if not isinstance(r, dict):
    say(False, "", f"{stage}: --provider-status for {source} wrote something that is not a report")
else:
    label = f"{stage}: {source}"
    say(r.get("source") == source, f"{label} is the source in force",
        f"{label} was chosen and the app reports {r.get('source')} as the source")
    # **What it may be sent, read off the client itself** (ProviderReport asks a ProviderClient over a provider that
    # only notes what it was handed). On this Mac: everything. Remote: neither the dictionary text nor a sense question
    # — not on a lookup, and, while RemoteDisclosure.dictionaryTextMayLeave is false, not on a tap either.
    on = tier == "onThisMac"
    sent = (r.get("tier"), r.get("sendsDictionaryText"), r.get("asksSenseOnLookup"), r.get("asksSenseOnTap"))
    say(sent == (tier, on, on, on),
        f"{label} is {tier}, and " + ("may be sent the dictionary text and asked senses" if on
                                       else "is sent no dictionary text and asked no sense question"),
        f"{label}: tier, dictionary text, sense on lookup, sense on tap are {sent}; wanted {(tier, on, on, on)}")
    readiness = r.get("readiness")
    if wanted == "none":
        say(readiness is None, f"{label} is asked nothing to be checked",
            f"{label} was checked as though it were a provider: {readiness}")
    elif wanted == "endpointUnusable":
        # An address the app must not send to: plain HTTP to a public host, or one carrying a name or a password.
        say(readiness == "endpointUnusable", f"{label} is refused by the app's preflight, which sends it nothing",
            f"{label} was not refused: its preflight says {readiness} {r.get('failure') or ''}".rstrip())
    elif wanted == "ready":
        say(readiness == "ready",
            f"{label} answered the app's preflight in {r.get('answeredInSeconds')} s",
            f"{label} did not answer the app's preflight: {readiness} {r.get('failure') or ''}".rstrip())
    elif readiness == "ready":
        say(True, f"{label} answered the app's preflight in {r.get('answeredInSeconds')} s "
                  f"(version {r.get('version')})", "")
    elif readiness in ("notInstalled", "notSignedIn", "overrideUnusable") \
            or (readiness == "unavailable" and r.get("failure") == "rateLimited"):
        # A prerequisite only a person at this Mac can supply: install it, sign in to it, or wait out its quota.
        print(f"SKIPPED\t{label} was not asked a question here: the app's preflight says {readiness}"
              + (f" ({r.get('failure')})" if r.get("failure") else "")
              + " — install it and sign in on this Mac to run this check")
    else:
        say(False, "", f"{label} is installed and its preflight says {readiness}"
                       + (f" ({r.get('failure')})" if r.get("failure") else "")
                       + (f", version {r.get('version')}" if r.get("version") else ""))
print("DONE")
PYSTATUS
}

# **The setup flag is captured before the app is launched, not inside the stage that uses it.**
# Launching XiaolaiDict can open the setup board by itself and write this flag — that is the whole
# behaviour — so a backup taken later records the value the app just wrote, and "restoring" it
# leaves the machine changed. Read here, ahead of every launch, and put back however the run ends.
if setup_shown_original=$(defaults read com.xiaolaidict SetupWindowShown 2>/dev/null); then
    setup_shown_had=yes
else
    setup_shown_had=no
    setup_shown_original=""
fi
restore_setup_shown() {
    restore_default SetupWindowShown "$setup_shown_had" "$setup_shown_original" -bool
}
at_exit restore_setup_shown

# **Which pane Settings opens on is set aside too, for the same reason and at the same moment.**
# Settings opens on the pane the reader last chose once setup is finished, and the setup stage
# finds the window by the title "Setup" — so on a Mac where someone last looked at Reading, every
# check of the board would be reading another pane. Deleted before any launch, so the window opens
# on Setup as a fresh install does, and put back however the run ends.
if settings_pane_original=$(defaults read com.xiaolaidict SettingsPane 2>/dev/null); then
    settings_pane_had=yes
else
    settings_pane_had=no
    settings_pane_original=""
fi
if setup_unfinished_original=$(defaults read com.xiaolaidict SettingsSetupUnfinished 2>/dev/null); then
    setup_unfinished_had=yes
else
    setup_unfinished_had=no
    setup_unfinished_original=""
fi
restore_settings_pane() {
    restore_default SettingsPane "$settings_pane_had" "$settings_pane_original"
    restore_default SettingsSetupUnfinished "$setup_unfinished_had" "$setup_unfinished_original" -bool
}
at_exit restore_settings_pane
defaults delete com.xiaolaidict SettingsPane 2>/dev/null || true
defaults delete com.xiaolaidict SettingsSetupUnfinished 2>/dev/null || true

# ---------------------------------------------------------------------------------------------
# **Stopping and starting the app, written once**, for the preflight below and for every stage that quits XiaolaiDict
# and starts it again.

# stop_app: asks XiaolaiDict to quit and waits up to 10 s; fails unless it is gone. The process
# that already exited between `ps` and `kill` is the reason `kill` alone is not the verdict — the
# wait is.
stop_app() {
    find_pids "$exe"
    [ "${#PIDS[@]}" -eq 0 ] || kill -TERM "${PIDS[@]}" 2>/dev/null || true
    for _ in $(seq 1 100); do is_running "$exe" || return 0; sleep 0.1; done
    return 1
}

# launch_app: start the bundle through LaunchServices, then wait for its process and for its menu-bar item. Prints why
# not on stderr and returns 1; it records nothing, because what a launch that failed means is its caller's to say.
#
# **`open`'s own answer is the first evidence, and it was thrown away.** A restart LaunchServices refused on the E2E
# Mac (reported 2026-10-08: `LSOpenURLsWithRole() failed with error -600` on the terminal) waited ten seconds and said
# only "no new XiaolaiDict process appeared after open" — and the stage went on to report "restored encounter lost
# after relaunch", which reads as data loss. `open`'s status and its words are kept and said. Refused for an app that
# is already running, where `open` would only bring it forward and a launch could not be told from no launch.
launch_app() {
    local said status=0
    find_pids "$exe"
    if [ "${#PIDS[@]}" -gt 0 ]; then
        echo "XiaolaiDict is already running (pid ${PIDS[*]}), so starting it would start nothing" >&2
        return 1
    fi
    said=$(open "$app" 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "LaunchServices would not start it: open exited $status${said:+ — $said}" >&2
        return 1
    fi
    for _ in $(seq 1 100); do is_running "$exe" && break; sleep 0.1; done
    find_pids "$exe"
    if [ "${#PIDS[@]}" -eq 0 ]; then
        echo "open exited 0 and no XiaolaiDict process appeared within 10 s${said:+ (open said: $said)}" >&2
        return 1
    fi
    # **And wait for the menu, which is not the same as waiting for the process.** Immediately after the pid
    # appears the menu-bar item is not in the Accessibility tree yet — measured deterministically, 3 restarts out of
    # 3 — and a menu-driven check that ran first then failed, a different one each run.
    for _ in $(seq 1 100); do
        "$helpers/menu-click" com.xiaolaidict --ready >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    echo "pid ${PIDS[*]} started but its menu-bar item never appeared within 20 s" >&2
    return 1
}

# restart_app: quit XiaolaiDict, start it again, wait for its menu-bar item. Prints why not, and returns 1.
restart_app() {
    local before
    find_pids "$exe"
    before="${PIDS[*]+${PIDS[*]}}"
    if ! stop_app; then
        echo "XiaolaiDict would not quit (pid ${before:-none}), so nothing was restarted" >&2
        return 1
    fi
    launch_app
}

# **In a stage, a launch that failed ends the stage at once, with its own sentence.** Every check after it would read
# an app that is not there, and each would fail with a sentence about the product. Called from inside the stage's
# own function, always as `launch_or_end_stage || return 0` — the failure is already recorded, and a non-zero return
# from a stage's function would end the whole run under `set -e`. `Tools/tests/test_e2e_harness.py` holds every call
# to that spelling, and runs both against an `open` that refuses.
launch_or_end_stage() {
    local why
    why=$(launch_app 2>&1) && return 0
    flunk "$STAGE: XiaolaiDict could not be started — $why. The rest of this stage did not run: every check after it would read an app that is not there"
    return 1
}
relaunch_or_end_stage() {
    local why
    why=$(restart_app 2>&1) && return 0
    flunk "$STAGE: XiaolaiDict could not be restarted — $why. The rest of this stage did not run: every check after it would read an app that is not there"
    return 1
}

# ---------------------------------------------------------------------------------------------
# **The preflight: what the stages asked for need, proved before any of them runs — and each thing missing named, with
# where it is granted or what to do.** Added 2026-10-08, after hours went to failures whose cause was no stage's
# subject. Commands run from this SSH session are judged by TCC as the session — the process macOS holds responsible
# for it, `sshd-keygen-wrapper` — and not as XiaolaiDict, so they need grants of their own that the app's setup board,
# all green, cannot show: the learning stage's `screencapture` and hover's directly run `--read-point` failed that way.
# A TextEdit no helper could use took four stages with "no focused element". A refused launch read as lost data. Every
# check runs, so one run names everything missing; then, if anything is, the run stops before any stage.
STAGE=preflight
# wants_any <stage...>: is any of these asked for? Unlike `want`, it names nothing — the preflight is not a stage a
# run selects, and it runs before every one.
wants_any() {
    local name w
    [ ${#WANTED[@]} -eq 0 ] && return 0
    for name in "$@"; do
        for w in "${WANTED[@]}"; do [ "$w" = "$name" ] && return 0; done
    done
    return 1
}
# One sentence a line: what is missing, which stages need it, and what a person at the Mac does about it.
missing=""
lacks() { missing="$missing$1"$'\n'; }
# The client a person grants, as macOS 27's lists name it: not XiaolaiDict, and not a terminal app.
readonly session_client="sshd-keygen-wrapper (/usr/libexec/sshd-keygen-wrapper, which macOS holds responsible for an SSH session; add it with +)"

json_field() {  # json_field <key> [<key>]: one field — or one field of one field — of the JSON object on stdin
    python3 -c '
import json, sys
try:
    value = json.loads(sys.stdin.read())
    for key in sys.argv[1:]:
        value = value.get(key) if isinstance(value, dict) else None
except ValueError:
    value = "unreadable"
if value is True:
    print("yes")
elif value is False:
    print("no")
elif value is None:
    print("absent")
else:
    print(value)' "$@"
}

# end_process <pid>: TERM, then KILL, each waited for; fails unless it is gone. For TextEdit when the preflight has found
# it unusable, and nothing else.
end_process() {
    local pid=$1
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
    return 1
}

# fixture_health: `app-health`'s report on TextEdit and the fixture once it is `ok`, or the last one after 10 s — a
# document opened a moment ago is still loading. Hung, blocked and no Accessibility are answers at once.
fixture_health() {
    local health="" state
    for _ in $(seq 1 20); do
        health=$("$helpers/app-health" com.apple.TextEdit "The meeting ended after we stopped meeting at noon." 2>&1) && break
        state=$(printf '%s' "$health" | json_field state)
        if [ "$state" = hung ] || [ "$state" = blocked ] || [ "$state" = noAccessibility ]; then break; fi
        sleep 0.5
    done
    printf '%s' "$health"
}

# fixture_ready: TextEdit open on the fixture, answering, nothing covering it, and the fixture's word selectable from
# this session — what `select-text` needs in every stage that drives a lookup. Once, it is put right where the harness
# may: opened again on the fixture when TextEdit is not running or holds no fixture, and **ended first only where
# nobody could answer it** — hung — **or where what covers it is a sheet on the fixture's own window**, which is the
# harness's. A sheet on any other document, or a dialog for the whole app, is a person's to answer, on a Mac that may
# be theirs, and is named instead. Says on stdout what it did, prints why not on stderr, and returns 1.
fixture_ready() {
    local attempt health state detail pid why on_fixture again=""
    for attempt in 1 2; do
        open -a TextEdit "$helpers/notes.txt" 2>/dev/null || true
        health=$(fixture_health)
        state=$(printf '%s' "$health" | json_field state)
        [ "$state" = ok ] && break
        detail=$(printf '%s' "$health" | json_field detail)
        on_fixture=$(printf '%s' "$health" | json_field onFixture)
        if [ "$state" = blocked ] && [ "$on_fixture" != yes ]; then
            echo "TextEdit shows something only a person can answer — $detail; answer it at the Mac, since the stages that select in the fixture cannot get past it" >&2
            return 1
        fi
        if [ "$attempt" = 2 ] || [ "$state" = noAccessibility ]; then
            echo "TextEdit cannot hold the fixture the selection, shortcut, deadline, hover, drawer, learning, model and provider stages select in: $state — $detail$again" >&2
            return 1
        fi
        pid=$(printf '%s' "$health" | json_field pid)
        if { [ "$state" = hung ] || [ "$state" = blocked ]; } && [ -n "${pid##*[!0-9]*}" ]; then
            echo "NOTE  preflight: TextEdit was $state — $detail; it is ended and opened again on the fixture"
            again=" (after it was ended and opened again)"
            end_process "$pid" || { echo "TextEdit was $state ($detail) and would not end (pid $pid)" >&2; return 1; }
        else
            echo "NOTE  preflight: TextEdit was $state — $detail; it is opened again on the fixture"
            again=" (after it was opened again)"
        fi
    done
    why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1) \
        || { echo "the fixture's word could not be selected in TextEdit from this session: $why" >&2; return 1; }
}

# 1. **The screen, unlocked.** The test Mac locks itself when idle, whatever its screen-lock setting reports, and a
#    lock does not stop XiaolaiDict's windows being drawn: the window list still has them, so every "is it on screen"
#    check passes. It covers them. Measured on 2026-09-21: a capture of the drawer came back as the lock screen's
#    aerial image and read as "the glass does not work", and keystrokes for the shortcut recorder went to the password
#    field with `loginwindow` in front.
screen_ok=yes
if ! lock_state=$("$helpers/screen-state" 2>&1); then
    screen_ok=no
    lacks "the screen is ${lock_state:-locked} — unlock the test Mac at its keyboard; every stage looks at the screen or types into it, and nothing that needs the screen was checked further"
fi

# 2. **No system alert nobody answered.** `click-element` refuses a control something is covering, which is right — a
#    click posted through an alert goes to the alert — but the refusal then reads as the control not existing. Measured
#    2026-09-23: an unanswered "Allow …to find devices on local networks?" had sat at (734, 222) since 2026-09-20, over
#    the settings window's tab strip, and two stages failed as though the app were at fault. Answering it is a decision
#    for whoever owns the machine, so it is named, never clicked.
alert_windows=$("$helpers/on-screen" com.apple.UserNotificationCenter 2>/dev/null || true)
if printf '%s' "$alert_windows" | grep -q '"windows":\[{'; then
    alert_text=$("$helpers/panel" com.apple.UserNotificationCenter 2>/dev/null | head -c 300 || true)
    lacks "a system alert is on the test Mac's screen and would swallow the stages' clicks — answer it at the Mac: $alert_text"
fi

# 3. **This session's own grants**, asked of APIs that never prompt (`session-access`).
access=$("$helpers/session-access" com.apple.systemevents 2>&1) || access=""
session_accessibility=$(printf '%s' "$access" | json_field accessibility)
if [ "$session_accessibility" != yes ]; then
    lacks "this SSH session may not use Accessibility ($session_accessibility), and every helper and instrument a stage runs here is judged as the session, not as XiaolaiDict — at the Mac, add $session_client in System Settings › Privacy & Security › Device Control and Data Access (macOS 27's name for the Accessibility list)"
fi
if wants_any learning hover; then
    session_recording=$(printf '%s' "$access" | json_field screenRecording)
    if [ "$session_recording" != yes ]; then
        lacks "this SSH session may not record the screen ($session_recording), which the learning stage's screencapture and the hover stage's --read-point (run directly here, falling back to the pixels) need — at the Mac, add $session_client in System Settings › Privacy & Security › Screen & System Audio Recording; XiaolaiDict's own grant does not cover a command run over SSH"
    elif ! screencapture -x "$reports/preflight-screen.png" 2>"$reports/preflight-screen.err" \
         || [ ! -s "$reports/preflight-screen.png" ]; then
        lacks "screencapture from this SSH session made no picture ($(head -c 200 "$reports/preflight-screen.err")) although the session reads as allowed to record — the learning stage's captures would fail the same way"
    fi
fi
if wants_any learning; then
    scripting=$(printf '%s' "$access" | json_field automation com.apple.systemevents)
    if [ "$scripting" = notRunning ]; then
        # Asked of a running System Events only; starting it is a LaunchServices launch, and sends no Apple event.
        open -gb com.apple.systemevents 2>/dev/null || true
        for _ in $(seq 1 25); do
            scripting=$("$helpers/session-access" com.apple.systemevents 2>/dev/null | json_field automation com.apple.systemevents) \
                || scripting=unreadable
            [ "$scripting" != notRunning ] && break
            sleep 0.2
        done
    fi
    if [ "$scripting" != granted ]; then
        lacks "this SSH session may not script System Events ($scripting), which the learning stage uses to switch the system's appearance — at the Mac, allow $session_client to control System Events in System Settings › Privacy & Security › Automation (notAsked means the first stage that scripts it would raise the Allow prompt on that screen, with nobody there to answer)"
    fi
fi

# 4. **Google Chrome, for the hover stage's bounds-scan dialect.**
if wants_any hover && [ ! -d "$chrome_app" ]; then
    lacks "Google Chrome is not installed at $chrome_app, and the hover stage covers the bounds-scan dialect in it — install it there, or run the other stages without hover"
fi

# 5. **TextEdit, answering and holding the fixture**, where a stage selects in it — and only where this session can use
#    Accessibility on an unlocked screen, or every answer here would be about that instead.
if [ "$screen_ok" = yes ] && [ "$session_accessibility" = yes ] \
   && wants_any selection shortcut deadline hover drawer learning model provider; then
    fixture_ready 2>"$reports/fixture-ready.err" || lacks "$(cat "$reports/fixture-ready.err")"
fi

# 6. **XiaolaiDict, started and showing its menu-bar item.** Nearly every stage needs it running, so having it running
#    is part of the preflight; the `launch` stage is what asserts a fresh start, and stays a stage of its own.
if is_running "$exe"; then
    menu_ready=""
    for _ in $(seq 1 200); do
        if "$helpers/menu-click" com.xiaolaidict --ready >/dev/null 2>&1; then menu_ready=yes; break; fi
        sleep 0.1
    done
    [ -n "$menu_ready" ] || lacks "XiaolaiDict is running but its menu-bar item never appeared within 20 s — every menu-driven stage would be void"
elif ! why=$(launch_app 2>&1); then
    lacks "XiaolaiDict could not be started: $why"
fi

# **Every missing thing recorded, then the run stops before any stage.** Through `flunk`, so each is filed against the
# preflight rather than only printed, and `make e2e-status` shows it.
if [ -n "$missing" ]; then
    while IFS= read -r sentence; do
        if [ -n "$sentence" ]; then flunk "preflight: $sentence"; fi
    done <<<"$missing"
    echo
    echo "the preflight found something the stages need missing on this Mac, so no stage ran"
    finished=true
    exit 1
fi
pass "preflight: the screen, this session's grants, the fixtures and the app the stages asked for are in place"
STAGE=setup

# **The content fingerprint and the backup of a ledger, for the stages that set the reader's ledger
# aside.** Used by `learning`, `review` and `reminder`, so they are defined before every stage: inside
# the first that needed them, a run of another alone would have died on `ledger_digest: command not
# found` with the ledger moved. `Tools/tests/test_ledger_set_aside.py` runs them as they are written here.
ledger_source() {  # ledger_source <path>: the name sqlite3 opens a ledger by to read it, and nothing else
    # **A WAL-mode file with nothing in its -wal is complete by itself, and is read as immutable.** The
    # ledger is WAL, so its backup, the staged copy and the restored ledger all carry WAL in their header
    # with no -shm beside them — and /usr/bin/sqlite3 3.54 refuses a read-only open of exactly that:
    # CANTOPEN (14), because a read-only connection cannot create the -shm. Measured on the E2E Mac.
    # The live ledger, while the app writes it, has its newest commits in a non-empty -wal that
    # `immutable` would skip, so it alone is opened plainly — the writer keeps its -shm there.
    local db="$1"
    if [ ! -s "$1-wal" ]; then
        db=${1//\%/%25}; db=${db// /%20}; db=${db//\?/%3f}; db=${db//\#/%23}
        db="file:$db?immutable=1"
    fi
    printf '%s' "$db"
}
ledger_digest() {  # ledger_digest <path>: content fingerprint of a ledger that passes integrity_check
    local out
    out=$(sqlite3 -readonly "$(ledger_source "$1")" 'PRAGMA integrity_check;' 'PRAGMA user_version;' '.sha3sum --schema' 2>&1) \
        || { echo "ledger_digest: $1 could not be read: $out" >&2; return 1; }
    [ "$(printf '%s\n' "$out" | head -1)" = ok ] || { echo "ledger_digest: $1 fails integrity_check: $out" >&2; return 1; }
    printf '%s\n' "$out"
}
# **A backup reads the ledger the way its fingerprint does**, or the two disagree about which ledgers
# can be read at all. It opened the ledger plainly, which is CANTOPEN for the reader's own ledger exactly
# when the app has not opened it since it was put back — no -wal, no -shm: the `reminder` stage, run
# straight after `review` had restored it and started the app, got a 0-byte backup and stopped on
# "the ledger backup does not match the ledger" (E2E Mac, 2026-10-05). Every stage that sets the
# ledger aside goes through here.
ledger_backup() {  # ledger_backup <ledger> <copy>: SQLite's own backup of the ledger into <copy>
    sqlite3 -readonly "$(ledger_source "$1")" ".backup '$2'"
}

# **The reader's review reminders, around a stage that launches the app on a ledger that is not theirs.**
#
# The app re-plans its reminders at every launch, from the ledger it opens and the settings and log in
# its domain, and the notification center it adds to and removes from is the app's, not the ledger's.
# `learning`, `review` and `reminder` launched their fixture ledgers with the reader's settings on and
# their log in place, so the app planned from the fixture — an empty one plans nothing — and removed the
# reader's pending requests; the reader's log, imported back at the restore, still said `added`, which
# the app reads as `gone` once a request is not pending, and those days were silenced (audit-fix round 2,
# #20). So each of the three reads what the reader has pending before any launch, takes the two keys out
# of the domain before its first fixture launch — off, with no log, the app touches nothing (WI-7) — and
# its restore fails unless every one of those requests is pending again at its own instant.
#
# **Cost**: one `--reminder-report` run per stage before it starts, a few seconds and bounded at 60, and a
# second at its restore only where the reader had something pending — never on a Mac nobody gave the
# notification grant, the E2E Mac among them.
reminder_pending() {  # reminder_pending <report>: how many review requests it lists as pending, or -1
    python3 - "$1" 2>/dev/null <<'PYPENDING' || echo -1
import json, sys
report = json.load(open(sys.argv[1]))
print(sum(1 for found in report.get("pending", []) if str(found.get("id", "")).startswith("review.")))
PYPENDING
}
# reader_reminders <evidence>: what the reader has pending, read into <evidence>/reader.json with their own
# ledger and settings and the app stopped. Non-zero when it cannot be read: a stage that could not see
# them could not say it left them alone.
reader_reminders() {
    printf '%s' "$(run_report --reminder-report 60 || true)" > "$1/reader.json"
    [ "$(reminder_pending "$1/reader.json")" != -1 ]
}
# domain_cleared: the app's whole domain deleted, and proved empty before a restorer imports into it.
# `defaults import` *merges*, so an import over a domain the delete did not clear keeps every key the
# stage wrote and reports success. `defaults delete` exits 1 for a domain that is not there, so its
# status says nothing either way — and `defaults read` of a deleted domain exits 0 and prints `{}`
# (measured 2026-10-05), so a read's status says nothing either. What the domain *holds* is counted
# from its export, and anything but zero keys — or an export that cannot be read — fails the restore
# (audit-fix round 3, #12).
domain_cleared() {
    local left
    defaults delete com.xiaolaidict >/dev/null 2>&1 || true
    left=$(defaults export com.xiaolaidict - 2>/dev/null \
        | python3 -c 'import plistlib, sys; print(len(plistlib.loads(sys.stdin.buffer.read())))' 2>/dev/null) \
        || left=unreadable
    if [ "$left" != 0 ]; then
        echo "restore: com.xiaolaidict still holds ${left:-unreadable} key(s) after being deleted, so the preferences were not imported over it" >&2
        return 1
    fi
}
reminders_set_aside() {  # reminders_set_aside: the reminder settings and log out of the app's domain
    local key
    for key in reviewReminderSettings reviewReminderLog; do
        defaults delete com.xiaolaidict "$key" >/dev/null 2>&1 || true
        # `defaults delete` exits 1 for a key that was never there, so its status says nothing: the key
        # is read back, and one that still reads is a fixture about to launch with the reader's on.
        if defaults read com.xiaolaidict "$key" >/dev/null 2>&1; then
            echo "reminders_set_aside: $key is still in the domain" >&2
            return 1
        fi
    done
}
# reader_reminders_back <evidence>: every review request <evidence>/reader.json lists, its time still
# ahead, pending again at its own instant — read with the app stopped and the reader's settings back, so
# what is pending is what the stage left and not what the app has since planned. Fails loudly otherwise:
# nothing outside the app can add a request, so nothing here puts one back.
reader_reminders_back() {
    local evidence=$1 report left
    [ "$(reminder_pending "$evidence/reader.json")" = 0 ] && return 0
    report=$(run_report --reminder-report 60) || true
    printf '%s' "$report" > "$evidence/restored.json"
    left=$(python3 "$helpers/reminder.py" missing "$evidence/reader.json" "$evidence/restored.json") \
        || { echo "restore: what is pending could not be compared with what the reader had pending" >&2; return 1; }
    [ -z "$left" ] || { echo "restore: the reader's own reminder(s) $left are no longer pending" >&2; return 1; }
}

if want launch; then
# 1. LaunchServices starts it, and it stays up — **a process of its own, quit and started again**. The preflight has
#    the app running already, so the `open` this stage used to make only brought that one forward, and the stage passed
#    whether or not LaunchServices could start XiaolaiDict at all.
launch_stage() {
    relaunch_or_end_stage || return 0
    sleep 1
    if is_running "$exe"; then pass "launch: started by LaunchServices, and still running after 1 s"; else flunk "launch: not running 1 s after it started"; fi
}
launch_stage
fi

if want lookup; then
# 2. A lookup through the real XPC path answers with entries.
if lookup=$("$exe" --lookup ephemeral 2>&1) && [ "$(printf '%s\n' "$lookup" | outcomes)" = entries ]; then
    pass "lookup: entries through the dictionary service"
else
    flunk "lookup: $lookup"
fi
fi

if want crash; then
# 3. The service dies mid-run: the next lookups fall back, saying why, and later ones recover.
out=$(mktemp)
"$exe" --lookup ephemeral --repeat 4 --interval 4 >"$out" 2>&1 &
client=$!
killed=""
# Every instance: each client gets its own, and the one serving this client is not told apart.
for _ in $(seq 1 30); do
    find_pids "$service"
    if [ "${#PIDS[@]}" -gt 0 ] && [ "$(wc -l <"$out")" -ge 1 ]; then
        killed="${PIDS[*]}"; kill -KILL "${PIDS[@]}"; break
    fi
    sleep 0.1
done
wait "$client" || true
seq=$(outcomes <"$out")
if [ -z "$killed" ]; then
    flunk "crash recovery: never saw a service to kill — the test did not happen ($seq)"
elif [[ "$seq" =~ ^entries\ .*(plainText|notFound).*\ entries$ ]]; then
    pass "crash recovery: $seq"
else
    flunk "crash recovery: expected entries, then a fallback, then entries again — got: $seq"
fi
rm -f "$out"
fi

if want accessibility; then
# 4. Accessibility, which the selection tests need: said plainly either way.
#
# **A positive answer is required, not merely the absence of one sentence.** This read
# `--read-selection` with `2>&1 || true` and passed unless the output held the words "Accessibility
# access … is off" — so *every other* way of not answering passed too. A release bundle, where the
# instrument is compiled out, prints "--read-selection is a development instrument" and would have
# been recorded as Accessibility being granted; reproduced locally against the refusal string. So
# would a crash, and so would silence.
#
# The instrument writes JSON on stdout in each of its three reachable outcomes — a selection, a
# `{"nothing": reason}`, or an `{"error": …}` — so valid JSON *is* the positive signal: it says the
# instrument ran and answered. stderr is captured apart from it rather than merged, because merging
# lets a stray line on stderr corrupt an otherwise valid report and read as a permission failure.
reading=$("$exe" --read-selection com.apple.finder 2>"$reports/read-selection.err" || true)
if ! python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$reading" 2>/dev/null; then
    flunk "accessibility: --read-selection gave no report, so whether Accessibility is granted is unknown ($(head -c 200 "$reports/read-selection.err" 2>/dev/null))"
    echo; echo "$failures assertion(s) failed, in 1 stage(s)"; exit 1
fi
if printf '%s' "$reading" | grep -q "Accessibility access for XiaolaiDict is off"; then
    flunk "accessibility: not granted to this session — the selection tests cannot run"
    echo; echo "$failures assertion(s) failed, in 1 stage(s)"; exit 1
fi
# **And an error is not an answer either.** Valid JSON says the instrument ran; it does not say
# Accessibility works. `{"error": "Finder is not running"}` is valid JSON with no denial sentence
# in it, and passed this gate — recording a permission as granted on the strength of a report
# about something else entirely. Only a selection, or a `nothing` that is not a refusal, is
# evidence; the two of them are exactly "the instrument reached Accessibility and used it".
if printf '%s' "$reading" | python3 -c 'import json,sys; sys.exit(0 if "error" in json.load(sys.stdin) else 1)' 2>/dev/null; then
    flunk "accessibility: the instrument answered with an error, which says nothing about the grant ($(printf '%s' "$reading" | head -c 200))"
    echo; echo "$failures assertion(s) failed, in 1 stage(s)"; exit 1
fi
pass "accessibility: readable"
fi

if want selection; then
# 5. Selections, read as the reader would see them. Fixtures open through LaunchServices, so no
#    Automation prompt can block the screen. They need an unlocked screen — while it is locked,
#    Accessibility reports each app's only window, and its focused element, as the app itself — and
#    the setup gate above has already refused a locked screen for every stage. This stage used to
#    ask a second time and ask it wrong: `… || echo false` reads "the session could not be asked"
#    as "the screen is unlocked", which is the nil-session hole `screen-state` was written to close
#    by failing closed. Two answers to one question, and the weaker one ran last.
open -a TextEdit "$helpers/notes.txt"; sleep 2
select_then_read "TextEdit: the second of two words is the one read (range dialect)" com.apple.TextEdit \
    "$helpers/select-text" com.apple.TextEdit meeting 2 -- \
    text=meeting lemma=meet context=complete captureSource=accessibilityTextRange \
    "sentence=The meeting ended after we stopped meeting at noon."
open -a Safari "$helpers/page.html"; sleep 3
select_then_read "Safari: a selection across a sentence end gets both sentences (markers)" com.apple.Safari \
    "$helpers/select-web" com.apple.Safari "here. Second" -- \
    "sentence=First one here. Second one follows." "lemma=here second" captureSource=accessibilityTextMarkers \
    context=complete "page=*page.html" precision=page document=nil
select_then_read "Safari: wrapping punctuation is not part of the term" com.apple.Safari \
    "$helpers/select-web" com.apple.Safari "“ephemeral,”" -- \
    text=ephemeral lemma=ephemeral
# `likely`, not `inferred`: *saw* → *see* is the everyday reading of the shape, not something the
# sentence established. This assertion said `inferred` and named itself "read from its grammar" until
# 2026-09-29 — both were true before the basis was split, and the stage had not run since.
select_then_read "Safari: a past form NLTagger leaves alone is lemmatised from a prior, and says so" \
    com.apple.Safari \
    "$helpers/select-web" com.apple.Safari saw -- \
    text=saw lemma=see lemmaBasis=likely
fi

if want shortcut; then
# 6. The reader's own path: a selection, the shortcut, the panel, the ledger, and Escape.
#    The shortcut is XiaolaiDict's default, Control-Option-D; a machine where it was changed fails here.
baseline=$(newest_row_id)
open -a TextEdit "$helpers/notes.txt"; sleep 1.5
if ! why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1); then
    flunk "shortcut: could not select ($why)"
else
    assert_default_shortcut || true
    "$helpers/keys" 2 control option
    # Waits for the lemma *and* the rendered page, rather than polling for the first and sleeping
    # a fixed second for the second. The page is laid out by WebKit after the panel shows, and on
    # a machine that has just been unlocked — apps relaunching, WebKit cold — that takes longer
    # than a second. A fixed wait turns load into a failure about rendering, which is what it did.
    # The assertion below is unchanged: a page that never arrives still fails, it just is not
    # declared missing while it is still on its way.
    # **One list of "this panel has not answered yet" markers, shared by the poll and the assertion
    # below.** Written twice, the two copies diverged in both possible ways at once. The poll asked
    # for a text element *equal* to the word while the assertion looked for it *within* a text — and
    # the long comment on the assertion explains exactly why the substring form is the correct one,
    # so the fix had been applied to one copy of two. On a primary that lemmatises, the poll could
    # therefore never succeed: it burned all 150 iterations and the assertion passed anyway, which is
    # a poll measuring nothing. And both copies still named `could not be asked`, wording the app
    # does not have — the same stale string already corrected in the grep at the deadline stage.
    card_failure_markers='Looking up|No entry for|could not all be asked|needs Accessibility'
    # **The `Lookup` window alone, for the poll and the assertion both** (audit-fix round 3, #11). An
    # open Library carries the same word and the same sentence on its cards, and with every window read
    # a Library card passed this stage with no lookup panel on screen at all.
    view=""
    for _ in $(seq 1 150); do
        view=$("$helpers/panel" com.xiaolaidict | lookup_windows) || view='{"frontmost": "", "windows": []}'
        printf '%s' "$view" | python3 -c '
import json, sys
failed = sys.argv[1].split("|")
panels = [w for w in json.load(sys.stdin)["windows"]
          if any("meeting" in t for t in w["texts"]) and not any(m in t for t in w["texts"] for m in failed)]
sys.exit(0 if panels else 1)
' "$card_failure_markers" && break
        sleep 0.1
    done
    view=$("$helpers/panel" com.xiaolaidict | lookup_windows) || view=unreadable
    if why=$(python3 - "$view" "$card_failure_markers" 2>&1 <<'PY'
import json, sys
view = json.loads(sys.argv[1])
# The answer card, headed by the word itself — an exact text element, so the waiting view's
# "Looking up “meeting” in your dictionaries…" cannot pass for it. The old panel was asserted by
# its lemma row and its WebKit page; the card that replaced it has neither, and both checks went
# on failing a panel that had answered.
# Not merely the heading: a card that says "No entry for “meeting”" carries the word too, and a
# check for the heading alone passed one. So an answer is the word's card with no failure on it.
#
# **The word is looked for *within* the card's text, not as an element equal to it.** The card heads
# itself with the dictionary's own headword — 牛津英汉汉英词典 answers a lookup of "meeting" with an
# entry headed "meet" — so an exact match asserted something the product never promised, and passed
# only while the primary dictionary happened to head the entry with the selected string. It failed
# the day the primary was one that lemmatises, with the card on screen and correct. The reader's own
# sentence carries the surface form either way, which is what this now matches.
failed = sys.argv[2].split("|")
panels = [w for w in view["windows"] if any("meeting" in t for t in w["texts"])
          and not any(m in t for t in w["texts"] for m in failed)]
problems = []
if view["frontmost"] != "com.apple.TextEdit": problems.append(f"focus moved to {view['frontmost']}")
if not panels: sys.exit(f"no answer card for the word: {view}")
# The evidence: the reader's own sentence, which is what makes a wrong answer visible rather than
# authoritative. A card without it is claiming more than it can show.
if not any("stopped meeting at noon" in t for t in panels[0]["texts"]):
    problems.append(f"the card does not carry the sentence it was read in: {panels[0]['texts'][:12]}")
sys.exit("; ".join(problems) if problems else 0)
PY
    ); then pass "shortcut: the card answers with the reader's sentence, and TextEdit keeps focus"; else flunk "shortcut: $why"; fi

    held=$("$helpers/claim-escape" || true)
    "$helpers/keys" 53
    sleep 1
    free=$("$helpers/claim-escape" || true)
    closed=$("$helpers/panel" com.xiaolaidict | lookup_windows) || closed=unreadable
    # **The lookup panel is gone, not every window.** Requiring an empty window list made a
    # legitimately open Settings or setup board fail a panel that had been dismissed correctly —
    # the assertion was about the app, and the claim is about one window.
    if [ "$held" = held ] && [ "$free" = free ] && [ "$closed" != unreadable ] \
       && ! printf '%s' "$closed" | python3 -c 'import json,sys; sys.exit(0 if any("meeting" in t for w in json.load(sys.stdin)["windows"] for t in w["texts"]) else 1)' 2>/dev/null; then
        pass "escape: held while the panel shows, closes it, and is released"
    else
        flunk "escape: while shown '$held', after '$free', panel after Escape: $closed"
    fi

    waited=$(row_after "$baseline" meeting com.apple.TextEdit)
    recorded=$(rows_of "$baseline" meeting com.apple.TextEdit)
    id=$(row_id_of "$baseline" meeting com.apple.TextEdit)
    row=$(sqlite3 -readonly -json "$ledger" "select surface, lemma, context, source_app, result, answered_by, capture_source, context_quality from lookups where id = $id" 2>&1)
    if [ "$recorded" -eq 1 ] && why=$(expect "$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[0]))')" \
            surface=meeting lemma=meet "context=The meeting ended after we stopped meeting at noon." \
            source_app=com.apple.TextEdit result=found answered_by=dictionaryService \
            capture_source=accessibilityTextRange context_quality=complete 2>&1); then
        pass "ledger: the lookup is recorded ${waited}s after the panel closed, with its capture quality"
    else
        flunk "ledger: $recorded row(s) for this lookup after id $baseline, ${waited}s later; row: ${why:-$row}"
    fi
fi
fi

if want deadline; then
# 7. The 1 s promise, against a service that is hung rather than dead. SIGSTOP is the only way to
#    get a genuinely unresponsive service from outside: a killed one fails fast, which is the easy
#    case and proves nothing. With the panel shown before the lookup is asked, it must appear at
#    once and say what it is waiting for; the entry arrives when the deadline gives up and the
#    public fallback answers. Before this was so, there was no panel at all until then.
stopped=""
# **A service this run suspended and could not resume is left hung for everything after it**, so
# the failure is said and the pids are kept — cleared unconditionally, a later cleanup pass had
# nothing to retry and nothing to report.
resume() {
    [ -n "$stopped" ] || return 0
    if kill -CONT $stopped 2>/dev/null; then
        stopped=""
        return 0
    fi
    echo "resume: the dictionary service (pids $stopped) could not be resumed and is still suspended" >&2
    return 1
}
at_exit resume
# Established, not inherited: this stage run on its own found no fixture and no service.
ensure_fixture_open || flunk "waiting panel: the TextEdit fixture would not open"
if ! is_running "$service"; then ensure_one_lookup || true; fi
if ! why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1); then
    flunk "waiting panel: could not select ($why)"
else
    find_pids "$service"
    if [ "${#PIDS[@]}" -eq 0 ]; then
        flunk "waiting panel: no dictionary service to suspend — the test did not happen"
    else
        stopped="${PIDS[*]}"
        kill -STOP "${PIDS[@]}"
        started=$(now_seconds)
        assert_default_shortcut || true
    "$helpers/keys" 2 control option
        shown="" ; waiting=""
        for _ in $(seq 1 200); do
            view=$("$helpers/panel" com.xiaolaidict)
            if printf '%s' "$view" | grep -q 'Looking up'; then
                shown=$(now_seconds); waiting=$view; break
            fi
            sleep 0.05
        done
        if [ -z "$shown" ]; then
            # `$waiting` is what was captured and never read: the last panel seen, which is the whole
            # evidence for why this failed — an empty window list reads very differently from a panel
            # that came up with the wrong words in it.
            # **Named where the app names it.** Every check in this file that drives a real
            # lookup fails the same way on a Mac that has not granted the app Accessibility, and
            # each used to report it as a defect in the surface being measured.
            refusal=$(missing_grant)
            if [ -n "$refusal" ]; then
                flunk "waiting panel: no lookup could be driven — the app says \"$refusal\". This machine has not granted it; nothing here can"
            else
                flunk "waiting panel: never appeared while the service was suspended (last view: $(printf '%s' "${waiting:-$view}" | head -c 240))"
            fi
        else
            took=$(python3 -c "import sys; print(f'{float(sys.argv[2]) - float(sys.argv[1]):.2f}')" "$started" "$shown")
            if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)" "$took"; then
                pass "waiting panel: shown in ${took}s with the service hung, saying what it waits for"
            else
                flunk "waiting panel: took ${took}s, over the 1 s budget"
            fi
        fi
        # **What the deadline giving up actually produces, asserted before the service comes back.**
        # `resume` used to be the line right after the waiting panel was confirmed, so the answer that
        # filled the panel came from the service that had just been let go — the deadline expiring and
        # the public `DCSCopyTextDefinition` fallback answering was never demonstrated at all, under a
        # comment that said it was.
        #
        # The two claims turn out to conflict, which is why one check could not carry both: a fallback
        # answer *carries the caveat* ("could not all be asked") that the fill-in check below excludes
        # as a not-yet-answered marker. So the fallback is asserted here, while the service is still
        # suspended, and the complete answer is asserted after it comes back.
        fell_back=""
        for _ in $(seq 1 200); do
            view=$("$helpers/panel" com.xiaolaidict)
            if printf '%s' "$view" | grep -q 'could not all be asked'; then fell_back=$view; break; fi
            sleep 0.1
        done
        if [ -n "$fell_back" ]; then
            pass "waiting panel: the deadline gave up and the public fallback answered, saying the answer may be incomplete"
        else
            flunk "waiting panel: the service stayed suspended and nothing fell back to the public API — the reader waits forever ($(printf '%s' "${view:-}" | head -c 200))"
        fi
        # **It filled the panel it already had, rather than opening a second one.** That is the claim
        # here, and the fallback answer above is what filled it — so this must *accept* the caveat as
        # an answer, not exclude it as a not-yet-answered marker.
        #
        # Measured 2026-09-26: splitting the fallback out and leaving this check as it was failed with
        # "never filled in: nothing", because the panel was already complete and no later answer was
        # coming. Resuming the service does not re-run a lookup that has finished — the original check
        # only saw a caveat-free card because it resumed *before* the deadline expired, which is
        # precisely why the fallback went untested. One lookup cannot show both answers, and this is
        # the one it actually produces.
        filled=""
        for _ in $(seq 1 100); do
            view=$("$helpers/panel" com.xiaolaidict | lookup_windows) || view=""
            # The word's card, still not a miss — "No entry for" carries the word too.
            # Not `"meeting"` as a whole JSON element: the card heads itself with the dictionary's
            # headword, so a primary that lemmatises answers "meeting" with a card headed "meet".
            # The reader's own sentence carries the surface form, and that is what is matched.
            if printf '%s' "$view" | grep -q 'meeting' && ! printf '%s' "$view" | grep -qE 'Looking up|No entry for'; then
                filled=$view; break
            fi
            sleep 0.1
        done
        resume
        if [ -n "$filled" ] && [ "$(printf '%s' "$filled" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["windows"]))')" = 1 ]; then
            pass "waiting panel: filled itself in, in the one panel it already had"
        else
            flunk "waiting panel: never filled in after the service resumed: ${filled:-nothing}"
        fi
        "$helpers/keys" 53; sleep 0.5
    fi
fi
fi

if want hover; then
# 8. Hover: the word under a *point*, through the three Accessibility dialects and, where no app
#    exposes its text, the recogniser. Ported from the screen-word spike, and only meaningful
#    inside the signed bundle: a bare binary inherits the terminal's grants and has none of its
#    own, which is how the recogniser times out when run from a shell.
check_hover() {  # check_hover <json> <expected source>: prints a summary, or exits with problems
    python3 - "$@" <<'HOVERPY'
import json, sys
try:
    r = json.loads(sys.argv[1])
except ValueError:
    sys.exit(f"not JSON: {sys.argv[1][:80]}")
want = sys.argv[2]
problems = []
if r.get("captureSource") != want:
    problems.append(f"read by {r.get('captureSource')}, wanted {want}")
if not r.get("text"):
    problems.append("no word")
if not (r.get("sentence") or ""):
    problems.append("no sentence")
elif r["text"] not in r["sentence"]:
    problems.append(f"word {r['text']!r} is not in its own sentence")
if not 0 < r.get("confidence", 0) <= 1:
    problems.append(f"confidence {r.get('confidence')}")
if problems:
    sys.exit('; '.join(problems))
print(f"{r['text']!r} via {r['captureSource']} in {r['milliseconds']:.0f} ms")
HOVERPY
}

# **A failure names what it was pointed at, and keeps the screen it was read from.** "no word under the pointer
# (at 458 117)" said where and nothing else. With these two, the first run of 2026-10-08 showed both causes at once:
# Safari pointed at its tab's title, and Chrome at its page's text while the reader's restored "What's New" covered it.
# `word-point` says on stderr which element it chose and where; a failed hover carries that, and a picture of the
# screen goes to `hover-evidence` beside the bundle (the preflight has proved this session may record).
hover_at() {  # hover_at <label> <bundle-id> <expected capture source> [word-point option...]
    local label=$1 app_id=$2 want=$3
    shift 3
    local point reading summary chose evidence="$e2e_home/hover-evidence"
    if ! point=$("$helpers/word-point" "$app_id" "$@" 2>"$reports/word-point.err"); then
        flunk "$label: could not find a word to point at ($(cat "$reports/word-point.err"))"; return
    fi
    chose=$(cat "$reports/word-point.err")
    if ! reading=$("$exe" --read-point $point 2>&1); then
        mkdir -p "$evidence" && screencapture -x "$evidence/$app_id.png" 2>/dev/null || true
        flunk "$label: $reading (at $point, on $chose; the screen is in $evidence/$app_id.png)"; return
    fi
    if summary=$(check_hover "$reading" "$want" 2>&1); then
        pass "$label: $summary"
    else
        mkdir -p "$evidence" && screencapture -x "$evidence/$app_id.png" 2>/dev/null || true
        flunk "$label: $summary (at $point, on $chose; the screen is in $evidence/$app_id.png)"
    fi
}

open -a TextEdit "$helpers/notes.txt"; sleep 2
hover_at "hover: TextEdit answers the text-range dialect" com.apple.TextEdit accessibilityTextRange
open -a Safari "$helpers/page.html"; sleep 3
# `--page`: the word comes from the page, never from the tab strip above it (`word-point`).
hover_at "hover: Safari answers the text-marker dialect" com.apple.Safari accessibilityTextMarkers --page
# **Chrome.** It builds no page tree for `AXManualAccessibility` — measured 2026-10-03, refused as
# unsupported — only once told an assistive client is reading (`AXEnhancedUserInterface`), which the
# reader asks after a hover that found nothing (`ChromiumEscalationTests` hold that). Told here first,
# the hover reads Chrome's own text **through the bounds scan** — measured: Chrome lists the text-marker
# attributes and answers them empty at the pointer, so the read falls through to the third dialect,
# which is the one this check exists to cover.
#
# **A Chrome of the stage's own, on a profile made for the run and removed after it** (2026-10-08). The reader's Chrome,
# started cold on the E2E Mac, restored their session and put "What's New" in front: `page.html` was not the page on
# screen, `word-point` found its text in a tab nobody could see, and every read there — on `main` as on the branch —
# was "no word under the pointer". A profile of its own has no session, no first-run page and no default-browser bar,
# runs beside a Chrome the reader has open without touching it, and is ended by its own process. Quitting the reader's
# Chrome took an Apple event, and this SSH session had never been allowed to send one (`notAsked`, measured there the
# same day) — an event that asks the person at that screen, who is not there.
# chrome_instance <profile>: the browser process of the Chrome started on this profile — its exact executable with the
# profile on its command line; a helper process's executable is another, and the reader's Chrome has another profile.
chrome_instance() {
    ps -axww -o pid=,command= | awk -v exe=" $chrome_app/Contents/MacOS/Google Chrome --" -v profile="--user-data-dir=$1" '
        !found && index($0, exe) && index($0, profile) { print $1; found = 1 }'
}
if [ -d "$chrome_app" ]; then
    chrome_profile=$(mktemp -d /tmp/xiaolaidict-e2e-chrome.XXXXXX)
    chrome_pid=""
    quit_chrome() {
        if [ -n "$chrome_pid" ] && ! end_process "$chrome_pid"; then
            echo "quit_chrome: the stage's own Chrome (pid $chrome_pid) would not end, so its profile is left at $chrome_profile" >&2
            return 1
        fi
        rm -rf "$chrome_profile"
    }
    at_exit quit_chrome
    open -na "$chrome_app" --args --user-data-dir="$chrome_profile" --no-first-run --no-default-browser-check \
        --use-mock-keychain --new-window "file://$helpers/page.html"
    for _ in $(seq 1 50); do
        chrome_pid=$(chrome_instance "$chrome_profile") || chrome_pid=""
        [ -n "$chrome_pid" ] && break
        sleep 0.2
    done
    if [ -z "$chrome_pid" ]; then
        flunk "hover: the stage's own Chrome did not start (profile $chrome_profile)"
    else
        sleep 4
        hover_at "hover: Chrome, told an assistive client is reading, answers the bounds-scan dialect" \
            com.google.Chrome accessibilityBoundsScan --assistive --pid "$chrome_pid"
    fi
else
    flunk "hover: Google Chrome is not installed on this machine, so the Chromium dialect is untested"
fi
fi

if want drawer; then
# 9. The history drawer: it appears, docked where the geometry said, and **without activating
#    XiaolaiDict**. The last part is the whole reason this runs here. The spike this drawer came from
#    activated the app and made its panel key; a unit test can prove the code does not call
#    `activate`, but only a running bundle can prove nothing else did it either. Safari is left
#    frontmost by the stage above, so there is a real app with focus to steal.
#
#    Launched through LaunchServices, not run directly: the report now captures the screen to see
#    whether the drawer lets what is behind it through, and TCC refuses screen capture to any
#    process started over SSH, whatever XiaolaiDict has been granted. `open --stdout` puts it in the GUI
#    session and still lets its answer be read — the same reason `read_point` exists.
# 150 s: the history report's worst case is three 30 s captures — the first after boot is measured
# at nearly 15 s — plus about 7 s of appearing, settling and closing, with launch on top.
history_report() { run_report --history-report 150; }
# **The drawer needs something to draw**, and this stage creates none. Run on its own against a
# clean install the report came back empty and every assertion failed on a machine where nothing
# was wrong. One real lookup is the cheapest honest fixture: it is what a reader's drawer holds.
if [ "$(newest_row_id)" -le 0 ]; then
    ensure_one_lookup || flunk "drawer: could not put a reading in the ledger for the drawer to show"
fi
# The stripes image, kept beside the report. Missing is a note, not
# an abort: an unguarded copy under `set -e` ended the whole run when a capture failed, before its
# report — which says why — was read. The report clears the old image first, so one that is here
# is this run's.
keep_stripes() {
    rm -f "/tmp/xiaolaidict-backdrop-stripes-$1.png"
    if [ -f /tmp/xiaolaidict-backdrop-stripes.png ]; then
        # Guarded: a copy that fails is a note, never the end of the run — the report it would have
        # accompanied has not been read yet.
        cp /tmp/xiaolaidict-backdrop-stripes.png "/tmp/xiaolaidict-backdrop-stripes-$1.png" \
            || echo "note: could not keep the $1 stripes image"
    else
        echo "note: no stripes image under $1 glass — see the report's stripesProblem and evidenceProblem"
    fi
}
# One glass: the drawer draws the system's regular glass and has no setting of its own. The
# Frosted/Clear choice — and the second run that compared the two — went on 2026-10-02; a
# `DrawerGlass` default left on a machine by an older build is never read.
drawer=$(history_report) || true
keep_stripes regular
if ! python3 -c 'import json,sys; json.loads(sys.argv[1])' "$drawer" 2>/dev/null; then
    flunk "drawer: --history-report did not report ($(head -c 160 $reports/history-report.err 2>/dev/null))"
else
    if why=$(expect "$drawer" insideBundle=True appeared=True activatedTheApp=False \
                    claimedEscapeWhileShown=True releasedEscapeAfterClosing=True 2>&1); then
        pass "drawer: shows and closes without taking focus"
    else
        flunk "drawer: $why"
    fi
    # Docking is geometry the report checks against its own display, so a mismatch here means the
    # window AppKit gave us is not the one DrawerGeometry asked for.
    if why=$(expect "$drawer" dockedWhereAsked=True 2>&1); then
        pass "drawer: docked exactly where the geometry asked"
    else
        flunk "drawer: $why"
    fi
    if why=$(expect "$drawer" reopenedDockedWhereAsked=True 2>&1); then
        pass "drawer: reopening corrects a retained window's stale position"
    else
        flunk "drawer: reopening stayed off the display edge: $why"
    fi
    # Earlier stages recorded lookups, so the drawer must have something to show. An empty drawer
    # here would mean the ledger read silently returned nothing.
    if why=$(expect "$drawer" problem=none 2>&1); then
        # **One decode, and the ordering checked in Python rather than in `[ ]`.** Four separate
        # `python3 -c` calls decoded the same JSON four times, and the comparisons that followed
        # were the real fault: `[ "$x" -lt "$y" ]` *errors* on a non-integer, and an error inside an
        # `if` is simply a false branch — so a report whose counts came back as `null` or a message
        # failed every test and fell through to the `else`, which passes. A check that reports
        # success when it could not read its input is worse than no check.
        counts=$(python3 - "$drawer" <<'COUNTS' 2>/dev/null || true
import json, sys
d = json.loads(sys.argv[1])
got = {k: d.get(k) for k in ("days", "cards", "readings", "words")}
# `bool` is an `int` in Python, so it is excluded by name: `True` would otherwise read as 1 and
# pass the type test, and only trip the ordering below by coincidence.
missing = [k for k, v in got.items() if not isinstance(v, int) or isinstance(v, bool)]
if missing:
    sys.exit("not whole numbers: " + ", ".join(f"{k}={got[k]!r}" for k in missing))
# A card stands for at least its own lookup and holds exactly one word, so the order is fixed.
# Anything else means the collapse invented a card — the one way the grouping can be wrong that
# a reader would never see, because the cards themselves would look right.
if not (1 <= got["words"] <= got["cards"] <= got["readings"]):
    sys.exit("counts cannot all be true: "
             + " ".join(f"{k}={got[k]}" for k in ("words", "cards", "readings")))
print(" ".join(str(got[k]) for k in ("days", "cards", "readings", "words")))
COUNTS
)
        if [ -z "$counts" ]; then
            flunk "drawer: the counts did not read as whole numbers in the right order ($(printf '%s' "$drawer" | head -c 160))"
        else
            read -r days cards readings words <<<"$counts"
            pass "drawer: shows $readings reading(s) on $cards card(s), $words word(s) — across $days day(s)"
        fi
    else
        flunk "drawer: $why"
    fi
    # The captures the reading rests on were written where they can be looked at. A measurement
    # whose evidence is missing can only be believed.
    if why=$(expect "$drawer" evidenceProblem=none 2>&1); then
        pass "drawer: the captures behind the reading were kept to be looked at"
    else
        flunk "drawer: $why"
    fi
    # **Glass is a property of what shows through, so that is what is measured.** The drawer is
    # `glassEffect`; the Xcode canvas draws glass flat grey by design, and a comment said to judge
    # it in the running app, which nothing did — every check above would pass for a flat grey
    # panel. The report puts black and then white directly behind the drawer and counts how much
    # of it changes. Measured passing: 133 grey over black, 240 over white. A drawer that *looks*
    # flat on a reader's screen is usually sitting over something uniformly dark — a terminal.
    fraction=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("backdropChangedFraction", -1))' "$drawer")
    if why=$(expect "$drawer" backdropShowsThrough=True 2>&1); then
        pass "drawer: lets what is behind it show through ($fraction of it changes with the backdrop)"
    else
        problem=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("backdropProblem", "?"))' "$drawer")
        flunk "drawer: does not let what is behind it through — $fraction of it changes with the backdrop (problem: $problem)"
    fi
fi
# **The drawer driven by real mouse events**, through `drawer-interactions`: written with the repeated-tray-click fix
# (`9695fcb`, 2026-10-02) and run by nothing until 2026-10-08 — a check no stage runs is a check that cannot fail. A
# press held on the menu-bar item, slow and rapid repeated clicks, a click inside, Escape, a click outside, and the
# right- and control-click menus, each read back from the compositor. Its PASS and FAIL lines are filed here, and its
# closing count must say every one of them ran and passed: a helper that stopped part-way prints neither.
interactions=$("$helpers/drawer-interactions" com.xiaolaidict all 2>&1) || true
while IFS= read -r line; do
    case $line in
        "PASS: "*) pass "drawer: ${line#PASS: }" ;;
        "FAIL: "*) flunk "drawer: ${line#FAIL: }" ;;
    esac
done <<<"$interactions"
printf '%s' "$interactions" | grep -q '^drawer-interactions: [0-9]* assertions, 0 failures' \
    || flunk "drawer: the real-event checks did not all run and pass — $(printf '%s' "$interactions" | tail -3)"
fi

if want recogniser; then
# 10. The recogniser — the one capture path nothing exercised until now.
#
#    Both hover stages above assert an Accessibility dialect and answer in tens of milliseconds;
#    the OCR fallback beneath them had no stage at all. A terminal is what forces this path: it
#    publishes no selectable text to the dialects, so reading pixels is the only way.
#
#    **Launched through LaunchServices, never as a plain command.** TCC refuses screen capture to
#    any process started over SSH, whatever the app has been granted — the binary run directly here
#    reports "XiaolaiDict needs Screen Recording" on a machine that has it, which is a fact about this
#    harness and not about XiaolaiDict. `open --stdout` is what puts the instrument in the GUI session and
#    still lets its answer be read.
read_point() {  # read_point <x> <y>: the instrument's JSON on success, nothing on failure
    local out="$reports/read-point.json" err="$reports/read-point.err"
    rm -f "$out" "$err"
    open -n --stdout "$out" --stderr "$err" "$app" --args --read-point "$1" "$2"
    # Polled, not slept: a cold capture pays a system-wide warm-up that a warm one does not.
    for _ in $(seq 1 60); do
        [ -s "$out" ] || [ -s "$err" ] || { sleep 0.5; continue; }
        break
    done
    # **Reaped before returning.** Output appearing is not the process ending, and the caller's next
    # move is another `--read-point` — a second screen capture, which deadlocks against a live one.
    end_instrument --read-point || true
    # **`|| true`, for the reason `run_report` carries at length.** `rm -f` then a launch that
    # writes only to stderr leaves no `$out` at all, so `cat` returns 1 — and under `set -e` a bare
    # `got=$(read_point …)` takes that status and ends the run before the `flunk` written for the
    # case can be reached. `run_report` was fixed for this and this helper was missed; the
    # pre-flight now names both.
    cat "$out" 2>/dev/null || true
}

# **Raised before every probe, not once at the top.** Each `--read-point` launches an app and reaps
# it, and the front then goes to whichever app macOS activates next. Measured on the end-to-end machine
# 2026-09-30, nine probes in a row: Ghostty is frontmost for the first and `com.microsoft.Word` for
# all eight after it. That is harmless while the two windows are apart and decides the stage when
# they overlap — Word's 1280×1410 window contained Ghostty's 960×1050 that day, so every point in
# the grid belonged to Word.
front_is_ghostty() {
    [ "$("$helpers/on-screen" com.mitchellh.ghostty 2>/dev/null \
        | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p')" = com.mitchellh.ghostty ]
}
raise_ghostty() {
    open -a Ghostty
    for _ in $(seq 1 10); do
        front_is_ghostty && return 0
        sleep 0.5
    done
    return 1
}

# `flunk` returns 0, so the refusals below have to be told apart by the `if` rather than by their
# status: a stage that cannot raise the terminal must not go on to probe points in someone else's
# window and report what it found there.
if ! raise_ghostty; then
    flunk "recogniser: Ghostty would not come to the front, so no point in it can be read"
elif ! frame=$("$helpers/window-frame" com.mitchellh.ghostty 2>&1); then
    flunk "recogniser: no Ghostty window to read ($frame)"
else
    read -r wx wy _ _ <<<"$frame"
    # A grid, because where a terminal's text sits depends on its prompt, its font and its padding.
    reading=""
    read_x=0
    read_y=0
    saw=""  # which apps answered instead, so a failure names what it actually saw
    for dy in 98 113 83 128 68 143; do
        for dx in 50 160 280; do
            if ! raise_ghostty; then saw="$saw (Ghostty stopped coming to the front)"; break 2; fi
            got=$(read_point $((wx + dx)) $((wy + dy))) || true
            # **The search criterion is the assertion.** This accepted any OCR reading and then
            # asserted afterwards that it came from Ghostty — so a covered terminal was reported as
            # `bundleID: wanted com.mitchellh.ghostty, got com.microsoft.Word`, a message about the
            # wrong thing entirely. A reading of another app is not a reading of the terminal: the
            # grid moves on, and what answered instead goes into the failure rather than into it.
            if expect "$got" captureSource=opticalRecognition bundleID=com.mitchellh.ghostty >/dev/null 2>&1; then
                reading=$got
                read_x=$((wx + dx))
                read_y=$((wy + dy))
                break 2
            fi
            other=$(printf '%s' "$got" | sed -n 's/.*"bundleID"[^"]*"\([^"]*\)".*/\1/p') || true
            if [ -n "$other" ]; then saw="$saw $other"; fi
        done
    done
    if [ -z "$reading" ]; then
        flunk "recogniser: no point in the Ghostty window read as a terminal through OCR; answered by:${saw:- nothing}; last error: $(head -c 120 "$reports/read-point.err" 2>/dev/null)"
    else
        word=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["text"])' "$reading")
        pass "recogniser: read '$word' from a terminal through OCR"
        # **Timed on a second read of the same point**, which is what "warm" means. The first
        # capture after boot pays a system-wide ScreenCaptureKit warm-up — measured at 14.8 s once
        # and 24.8 s on 2026-09-23 — against ~0.5 s for every read after. This comment said
        # "asserted warm" while the code timed the very first read, so the stage was measuring how
        # long the machine had been up. A warm read that fails to come back is reported as that,
        # never silently replaced by the cold one.
        raise_ghostty || true
        warm=$(read_point "$read_x" "$read_y") || true
        cold=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["milliseconds"])' "$reading")
        if ! printf '%s' "$warm" | grep -q opticalRecognition; then
            # **Not substituted by the cold one.** Timing the first read under a "warm read cost…"
            # line would be a PASS that says the opposite of what was measured.
            flunk "recogniser: the same point would not read a second time, so the warm budget was not measured: $(head -c 120 "$reports/read-point.err" 2>/dev/null)"
            took=""
        else
            took=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["milliseconds"])' "$warm")
        fi
        if [ -n "$took" ] && [ "$took" -lt 5000 ]; then
            pass "recogniser: the warm read cost ${took} ms, inside the 5 s capture deadline (first read ${cold} ms)"
        elif [ -n "$took" ]; then
            flunk "recogniser: the warm read took ${took} ms, past the 5 s capture deadline (first read ${cold} ms)"
        fi
    fi
fi
fi

if want setup; then
# **The stage is a function so a launch that failed can end it at once** (`relaunch_or_end_stage`); what it must put
# back — the model store, and no board left on screen — follows the call, and runs however the stage ended.
setup_stage() {
# **Settle before driving the menu after a launch.** A click that lands while the app's state changes
# under an open menu is dropped: SwiftUI re-renders the menu and the click goes nowhere, while
# `menu-click` still reports it. Measured 2026-09-22 — after a cold start with the board open, the
# dictionary list arrives from the service a second or two later, and 2 clicks of 6 were lost; with
# the click held until it had arrived, 0 of 8. The board says when it has: its dictionary row stops
# asking. Bounded, so a service that never answers is reported by the check that needs it.
# Defined before anything below uses them: `settle_after_launch` calls `board_on_screen`, and
# a helper defined after its first caller is "command not found" — under `|| return 0`, silently.
# **A bounded wait that runs out is not the thing it was waiting for.** Both loops here fell through
# in silence, and the second one made the first one's silence dangerous: `! is_running || break`
# breaks when the app *is* running, so an app that never quit satisfied it on the first iteration.
# `open` then did nothing to an already-running process and the function returned success, having
# restarted nothing — while every assertion downstream believed it was reading a fresh launch. That
# is the case the setup stage depends on most: it restarts the app precisely to reach the
# fresh-reader branch of the model row.
#
# So the old process must be **gone**, and a **new** pid must be there afterwards. The new-pid check
# is not redundant with the death check: it is what says `open` actually started something, rather
# than the start loop having run out too.
# **Matched on "Setup", the settings window's own title while the board is its pane.**
# The board had a window called "Set Up XiaolaiDict" until 2026-10-01; it is a pane now, and
# Accessibility names the settings window after whichever pane is selected — which the scenes stage
# already records ("Accessibility calls the Settings window after its pane"). So this is a stronger
# check than the old one rather than a weaker substitute: it says the board is the pane on screen,
# where the old title only said the board's own window existed.
board_on_screen() {  # board_on_screen: 0 drawn, 1 absent, 2 exists but not drawn
    local seen
    seen=$("$helpers/on-screen" com.xiaolaidict "Setup")
    printf '%s' "$seen" | grep -q '"drawn":true' && return 0
    # Found by title but not drawn is neither "open" nor "absent", and must not read as either.
    printf '%s' "$seen" | grep -q '"matches":\[\]' || return 2
    return 1
}
settle_after_launch() {
    board_on_screen || return 0     # no board open by itself, so nothing was fetched early
    local _
    for _ in $(seq 1 50); do
        "$helpers/panel" com.xiaolaidict | grep -q "Looking for your dictionaries" || break
        sleep 0.2
    done
    sleep 0.5
}
# Frontmost app, and whether the board is main/focused, in one line — what a failed "came forward"
# or "was remembered" check needs to say, since the two can fail independently.
board_state() {
    local s; s=$("$helpers/on-screen" com.xiaolaidict "Setup")
    printf 'front=%s drawn=%s main=%s focused=%s' \
        "$(printf '%s' "$s" | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p')" \
        "$(printf '%s' "$s" | grep -q '"drawn":true' && echo yes || echo no)" \
        "$(printf '%s' "$s" | grep -q '"main":true' && echo yes || echo no)" \
        "$(printf '%s' "$s" | grep -q '"focused":true' && echo yes || echo no)"
}
# 12. The setup board: a fresh install's first window, and the same window on demand afterwards.
#
#    Driven with a real click, never `AXPress` — pressing a menu through Accessibility opens it
#    *without activating the app*, so a window opened from it never comes forward and a working
#    board would look broken.

# The flag was saved before the app was ever launched — see the setup section above. Saving it
# here would record whatever the first launch wrote, which is the value this stage is about.

# **The model row is measured as a fresh reader sees it.** Once this machine has run the model stage
# once, the store holds the weights for good and the row takes its "ready" branch — so the consent
# controls, the weaker-engine sentence and "nothing has begun downloading" stopped being measured at
# all, silently, on every machine that had ever run the suite. The store is set aside for that check
# and put back at the end of the stage: a rename inside one filesystem, so three gigabytes do not
# move. It is set aside **where this stage already restarts the app**, not before the menu-driven
# open above: a board asked for from the menu seconds after a launch did not come forward at all,
# and the row is better read from the board a first launch opens by itself anyway — that is the
# reader this branch is about.
models=$HOME/Library/Application\ Support/XiaolaiDict/Models
stashed=no
# **The restore has the same trap as the stash, and now the same guard.**
#
# `mv` onto an existing *directory* moves the source inside it. The removal above was unchecked
# and its callers suppress errexit, so a store that could not be removed — held open by an app
# this run did not manage to quit — was followed by a `mv` that buried the reader's weights at
# `Models/Models.e2e-stash`, and the function then reported success. `stash_models` was hardened
# against exactly this shape; the way back was not.
unstash_models() {
    [ "$stashed" = yes ] || return 0
    rm -rf "$models" || { echo "the model store could not be removed, so it was not put back" >&2; return 1; }
    # Checked, not assumed: `rm -rf` exits 0 for some things it did not remove.
    [ ! -e "$models" ] || { echo "the model store is still there after being removed; refusing to move the stash into it" >&2; return 1; }
    mv "$models.e2e-stash" "$models" || { echo "the model store could not be put back" >&2; return 1; }
    stashed=no
    # Put back behind the app's back, so the app is restarted: its controller read an empty store at
    # launch and would go on reporting one to every stage after this.
    restart_app || { echo "XiaolaiDict did not come back after the model store was put back" >&2; return 1; }
}
at_exit unstash_models

# **The store is stashed exactly once, and never onto an existing stash.**
#
# Two `mv "$models" "$models.e2e-stash"` lines stood in this stage, either side of a restart. `mv`
# onto an existing *directory* moves the source **inside** it, so the second one buried the real
# stash at `Models.e2e-stash/Models` whenever the app had recreated the root in between — which it
# does, because opening the store creates `.staging` for its lock. The restore then put back a
# directory with the weights one level too deep. An `Models.e2e-stash` left by an interrupted run
# does the same thing to the first call.
#
# Refusing an unexpected stash rather than working around it: a stash this run did not make holds
# somebody's weights, and guessing which of the two to keep is not a decision a test should take.
stash_models() {
    if [ "$stashed" = yes ]; then
        # Already aside. The root reappearing is the app's own doing — it creates `.staging` to hold
        # the install lock — so what is here is a lock directory and not weights. Removed, which is
        # what "no model installed" means at this point, and **only** when that is all it holds: a
        # store with a completion marker in it is a real model, and this must not delete one.
        [ -d "$models" ] || return 0
        # `-Fvx`: a fixed string, whole line, inverted — "everything that is not exactly `.staging`".
        # Deliberately not `-v '^\.staging$'`: `EndToEndTextTests` refuses a quoted grep pattern
        # containing `$`, because that is how `grep -q "$needle"` used to pass its inventory, and a
        # regex anchor is indistinguishable from an expansion to a scanner that does not parse shell.
        # An anchor-free fixed-string pattern is both stricter here and readable there. (`-F` is not
        # `-f`: the guard excludes only the lower-case flag, which is the one that reads patterns
        # from a file.)
        if [ -z "$(find "$models" -name '.complete' -print -quit 2>/dev/null)" ] \
           && [ -z "$(ls -A "$models" 2>/dev/null | grep -Fvx '.staging' || true)" ]; then
            rm -rf "$models"
            return 0
        fi
        flunk "setup: a model store reappeared with contents while the real one was stashed — not touching it"
        return 1
    fi
    [ -d "$models" ] || return 0
    if [ -e "$models.e2e-stash" ]; then
        flunk "setup: $models.e2e-stash already exists, so an earlier run left a stash — moving the store onto it would nest one inside the other. Put it back by hand before re-running."
        return 1
    fi
    mv "$models" "$models.e2e-stash" && stashed=yes
}
stash_models || true
# Opened from the menu, the way a reader reaches it after the first launch. The app was launched
# moments ago by the set-up above, so the menu is not driven until the launch has settled.
settle_after_launch
if ! "$helpers/menu-click" com.xiaolaidict "Settings…" >/dev/null 2>&1; then
    flunk "setup: could not reach Settings… in the menu"
else
    # Waited for rather than slept for: the first click on an inactive app only brings it forward.
    front=""
    front_waited=0
    front_seen=""   # every change of frontmost app, in order — what a failure has to explain
    front_prev=""
    for _ in $(seq 1 50); do
        front=$("$helpers/on-screen" com.xiaolaidict | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p')
        [ "$front" != "$front_prev" ] && front_seen="$front_seen → ${front#com.}@$((front_waited * 2))00ms"
        front_prev=$front
        [ "$front" = com.xiaolaidict ] && break
        sleep 0.2
        front_waited=$((front_waited + 1))
    done
    # **This window is meant to come forward.** "No panel may activate XiaolaiDict" governs the
    # surfaces a reader did not ask for, mid-sentence in another app; this is one they chose. How
    # long it took is printed, because the first run of this stage failed this at 6 s with Bambu
    # Studio in front and every hand-driven repeat passed — a bound nobody reads cannot say which.
    if [ "$front" = com.xiaolaidict ]; then
        pass "setup: choosing Settings… brings XiaolaiDict forward ($((front_waited / 5)).$(( (front_waited % 5) * 2 ))s)"
    else
        flunk "setup: the board never came forward in 10 s — $front is in front (frontmost:$front_seen; $(board_state))"
    fi

    # **Ask the compositor, not the controller and not Accessibility alone.** A window can report
    # `isVisible`, and can be listed by Accessibility, while never being drawn: the drawer once
    # reported `appeared: true` for a window a screenshot showed as empty desktop. `on-screen` has
    # Accessibility find the window by title and the compositor confirm it draws one at exactly that
    # frame — by bounds, because the compositor's titles need Screen Recording and a helper started
    # over SSH never has it.
    drawn=""
    for _ in $(seq 1 30); do
        drawn=$("$helpers/on-screen" com.xiaolaidict "Setup")
        printf '%s' "$drawn" | grep -q '"drawn":true' && break
        sleep 0.2
    done
    if printf '%s' "$drawn" | grep -q '"drawn":true'; then
        pass "setup: the compositor draws the board ($(printf '%s' "$drawn" | sed -n 's/.*"height":\([0-9]*\).*"width":\([0-9]*\).*/\2x\1/p' | head -1))"
    elif printf '%s' "$drawn" | grep -q '"matches":\[\]'; then
        flunk "setup: Accessibility finds no window titled Set Up ($(printf '%s' "$drawn" | head -c 200))"
    else
        # Found by title and not drawn at its frame: the UtilityWindow failure, exactly.
        flunk "setup: the board exists but the compositor does not draw it ($(printf '%s' "$drawn" | head -c 240))"
    fi

    # Every row, and the rows that report rather than demand. Read through Accessibility, which is
    # the right tool for *text* — it is only the wrong tool for "can the reader see it".
    shown=$("$helpers/panel" com.xiaolaidict)
    missing=""
    for row in "Accessibility" "Screen Recording" "Study Dictionary" "Lookup Shortcut" "Translation and Meanings"; do
        printf '%s' "$shown" | grep -q "$row" || missing="$missing $row"
    done
    if [ -z "$missing" ]; then
        pass "setup: the board shows every row"
    else
        flunk "setup: the board is missing a row —$missing"
    fi

    # **Waited for, not read once.** A cold XPC probe parses real entries — Longman's *hold* alone
    # is 625 KB — so a board asserted the instant it appears is being failed for the service still
    # working, not for a defect. Bounded, so a service that never answers is still a failure.
    dict_waited=0
    while printf '%s' "$shown" | grep -q "Looking for your dictionaries"; do
        [ "$dict_waited" -ge 100 ] && break
        sleep 0.2
        dict_waited=$((dict_waited + 1))
        shown=$("$helpers/panel" com.xiaolaidict)
    done
    # **Three outcomes, not two.** The row leaves "Asking…" both when the service answers and when
    # it fails, so a loop that only waited for that phrase to go away reported a broken service as
    # a successful one.
    if printf '%s' "$shown" | grep -q "Looking for your dictionaries"; then
        flunk "setup: the dictionary row was still asking the service after $((dict_waited / 5))s"
    elif printf '%s' "$shown" | grep -q "could not be read"; then
        flunk "setup: the dictionary service did not answer"
    else
        pass "setup: the dictionary row had the service's answer ($((dict_waited / 5))s)"
    fi
fi

# **Reopening shows the board, not a congratulation.** The flag decides whether the window opens by
# itself and never what it shows, so a second open is the same rows with ticks against them. This
# is the assertion that would fail if a `hasCompletedSetup` ever started gating content.
# `close-window` takes the window's **title**, not a bundle id. Passing the bundle id closes
# nothing and exits non-zero, which under `|| true` would leave the board open — and the reopen
# check below would then pass against a window that was never closed.
# **Closed by the title the window actually has.** The board had one of its own until 2026-10-01;
# it is a settings pane now, and Accessibility names that window after its selected pane.
if ! "$helpers/close-window" "Setup" >/dev/null 2>&1; then
    flunk "setup: could not close the board, so reopening cannot be tested"
else
    pass "setup: the board closes"
fi
sleep 1
# **And it is gone before the reopen is tried.** The comment above already knew this shape: a close
# that quietly does nothing leaves the board up, and the reopen below then passes against a window
# that was never closed. Measured 2026-10-01 — the close failed on a stale title, its own `flunk`
# fired, and "reopening gives the board again" passed anyway on the window still on screen. One
# failed assertion is a finding; a second one passing because of it is a check that cannot fail.
if board_on_screen; then
    flunk "setup: the board is still drawn after being closed, so reopening tests nothing ($(board_state))"
fi
defaults write com.xiaolaidict SetupWindowShown -bool true
if ! "$helpers/menu-click" com.xiaolaidict "Settings…" >/dev/null 2>&1; then
    flunk "setup: could not reopen the board after it had been shown once"
else
    sleep 1.5
    again=$("$helpers/panel" com.xiaolaidict)
    if printf '%s' "$again" | grep -q "Study Dictionary"; then
        pass "setup: reopening after it has been shown gives the board again"
    else
        flunk "setup: reopening gave something other than the board ($(printf '%s' "$again" | head -c 200))"
    fi
fi
# **The board opens by itself on a fresh install, and only then.**
#
# Without this the stage would pass with the automatic open removed entirely — every assertion
# above reaches the board through the menu. This is the half that can only be seen by restarting:
# the flag is what decides, so it is cleared, the app is restarted, and the board must appear with
# nobody having asked for it. Then the flag is set, the app is restarted again, and it must not.

# **The bundled model is hidden, not removed** (ADR-0053): its row is on the board only where `ShowLocalModelSetup` is
# set or a model is already on disk, and the row that opens a language-model source — *Translation and Meanings* — is
# optional, never Needed. A fresh reader is asserted first, with the flag and the reader's source both set aside; then
# the flag is set and the bundled model's own row is asserted as it always was. Read before any launch below, and put
# back however the run ends: the source decides that row's state word, and the flag decides whether the other is there.
if local_setup_original=$(defaults read com.xiaolaidict ShowLocalModelSetup 2>/dev/null); then
    local_setup_had=yes
else
    local_setup_had=no; local_setup_original=""
fi
if board_provider_original=$(defaults read com.xiaolaidict LanguageModelProvider 2>/dev/null); then
    board_provider_had=yes
else
    board_provider_had=no; board_provider_original=""
fi
restore_local_model_setup() {
    restore_default ShowLocalModelSetup "$local_setup_had" "$local_setup_original" -bool
    restore_default LanguageModelProvider "$board_provider_had" "$board_provider_original"
}
at_exit restore_local_model_setup

"$helpers/close-window" "Setup" >/dev/null 2>&1 || true
defaults delete com.xiaolaidict SetupWindowShown 2>/dev/null || true
# The store goes aside here, so this launch is a fresh reader's in both senses: no flag, and no
# model. Put back at the end of the stage, before anything that needs the weights. Idempotent: the
# first call above has usually already done it, and this one clears the root the restart recreated.
stash_models || true
# And no source chosen and no `ShowLocalModelSetup`, which is what a fresh reader has.
defaults delete com.xiaolaidict ShowLocalModelSetup 2>/dev/null || true
defaults delete com.xiaolaidict LanguageModelProvider 2>/dev/null || true
if ! relaunch_or_end_stage; then
    return 0
else
    opened=""
    for _ in $(seq 1 50); do board_on_screen && { opened=yes; break; }; sleep 0.2; done
    if [ "$opened" = yes ]; then
        pass "setup: a fresh install opens the board without being asked"
    else
        flunk "setup: nothing opened the board on a first launch"
    fi

    # That **nothing has begun downloading** is asked of the store rather than of a row, because a row that is simply
    # slow to redraw would otherwise read as proof — and with the bundled model hidden there is no row to ask at all.
    staging=~/Library/Application\ Support/XiaolaiDict/Models/.staging
    if [ -d "$staging" ] && [ -n "$(find "$staging" -name '*.partial' -mmin -5 2>/dev/null)" ]; then
        flunk "setup: something has been fetching model files in the last five minutes, unasked"
    else
        pass "setup: nothing had begun downloading a model"
    fi

    # **Read once the board has settled**: its summary says "Checking…" and its dictionary row is still asking for a
    # moment after it opens, and a count read then is a count of nothing yet.
    for _ in $(seq 1 50); do
        shown=$("$helpers/panel" com.xiaolaidict)
        printf '%s' "$shown" | grep -q "Looking for your dictionaries" || printf '%s' "$shown" | grep -q '"Checking…"' || break
        sleep 0.2
    done
    # Asked of the rows and controls, never of the text alone: the bundled model's row is gone, its buttons with it,
    # and the optional row's state word is "Optional". **And the summary does not count the optional row** — it counts
    # exactly the rows that say Needed — which is what "never Needed, never holds the board open" comes to on screen.
    board_verdicts=$(python3 - "$shown" 2>&1 <<'PYBOARD' || true
import json, re, sys
def say(ok, good, bad): print(("PASS\t" + good) if ok else ("FAIL\t" + bad))
try:
    shown = json.loads(sys.argv[1], strict=False)
except ValueError:
    shown = {"windows": []}
boards = [w for w in shown.get("windows", []) if "Study Dictionary" in w.get("texts", [])]
if not boards:
    say(False, "", "setup: no window held the board rows, so the language model rows were not read "
                   f"({[w.get('title') for w in shown.get('windows', [])]})")
else:
    texts, controls = boards[0].get("texts", []), boards[0].get("controls", [])
    bundled = [name for name in ("Not Now", "Download") if name in controls]
    say("Local Model" not in texts and not bundled,
        "setup: the bundled model row is hidden on a Mac with no model and no ShowLocalModelSetup (ADR-0053)",
        "setup: the bundled model row is on the board of a Mac with no model and no ShowLocalModelSetup "
        f"(its title: {'Local Model' in texts}, its controls: {bundled})")
    say("Translation and Meanings" in texts and "Optional" in texts and "Choose…" in controls,
        "setup: Translation and Meanings is on the board, Optional, with Choose… to open its settings",
        f"setup: the language model row is not an optional row (title: {'Translation and Meanings' in texts}, "
        f"Optional: {'Optional' in texts}, Choose…: {'Choose…' in controls})")
    summary = next((t for t in texts if "still needed" in t or "Nothing is waiting on you" in t or "is in place" in t),
                   None)
    needed = texts.count("Needed")
    if summary is None:
        say(False, "", f"setup: the board has no summary to count its rows against ({texts[:6]})")
    else:
        if "are still needed" in summary:
            counted = int(re.search(r"\d+", summary).group(0))
        elif "is still needed" in summary:
            counted = 1
        else:
            counted = 0
        say(counted == needed,
            f"setup: the summary counts {counted} thing(s) still needed, the rows that say Needed and not the optional one",
            f"setup: the summary counts {counted} while {needed} row(s) say Needed: {summary}")
print("DONE")
PYBOARD
)
    consume_verdicts setup "$board_verdicts"

    # **Opened is not seen.** Launched with another app in front, the board is drawn behind it —
    # macOS's cooperative activation refuses focus at launch — and it used to be recorded as shown
    # anyway, so a reader who never saw it never had it open by itself again. Asserted only when the
    # app really did stay behind: when it came forward on its own, being remembered is correct.
    launch_front=$("$helpers/on-screen" com.xiaolaidict | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p')
    if [ "$launch_front" != com.xiaolaidict ]; then
        if [ -z "$(defaults read com.xiaolaidict SetupWindowShown 2>/dev/null || true)" ]; then
            pass "setup: a board opened behind $launch_front is not counted as seen"
        else
            flunk "setup: a board that stayed behind $launch_front was recorded as seen"
        fi
    fi
    # Brought forward the way a reader would, which is the moment it counts. After a settle, for the
    # same reason as above — and `menu-click` failing is reported, never swallowed: under `|| true`
    # a click that never happened read as the app failing to remember one.
    settle_after_launch
    if ! reach=$("$helpers/menu-click" com.xiaolaidict "Settings…" 2>&1); then
        flunk "setup: could not reach Settings… after the restart ($reach)"
    fi
    seen=""
    for _ in $(seq 1 50); do
        [ "$(defaults read com.xiaolaidict SetupWindowShown 2>/dev/null || true)" = 1 ] && { seen=yes; break; }
        sleep 0.2
    done
    if [ "$seen" = yes ]; then
        pass "setup: seeing it once is remembered"
    else
        flunk "setup: the board was brought forward and not remembered, so it would open again every launch ($(board_state))"
    fi

    # **And the optional row is wired**: Choose… opens Language Model settings, the one place a source is chosen. A
    # button read through Accessibility is not a button that works, so it is clicked — the board is in front now — and
    # the pane it should bring up is asked of the compositor.
    chose=no
    why=""
    for _ in $(seq 1 50); do
        if why=$("$helpers/click-element" com.xiaolaidict "Choose…" 2>&1); then chose=yes; break; fi
        sleep 0.2
    done
    if [ "$chose" != yes ]; then
        flunk "setup: Choose… on the Translation and Meanings row could not be clicked — $why ($(board_state))"
    else
        pane_drawn=""
        for _ in $(seq 1 30); do
            pane_drawn=$("$helpers/on-screen" com.xiaolaidict "Language Model")
            printf '%s' "$pane_drawn" | grep -q '"drawn":true' && break
            sleep 0.2
        done
        if printf '%s' "$pane_drawn" | grep -q '"drawn":true'; then
            pass "setup: Choose… on the optional row opens Language Model settings"
        else
            flunk "setup: Choose… did not bring Language Model settings up ($(printf '%s' "$pane_drawn" | head -c 240))"
        fi
        "$helpers/close-window" "Language Model" >/dev/null 2>&1 || true
    fi
fi

# **And the flag shows the bundled model's row**, in every state it had before ADR-0053 hid it: the code, the row and
# its consent controls all stayed, and `ShowLocalModelSetup` is how a reader — or this stage — reaches them. A fresh
# reader again (no `SetupWindowShown`, no pane remembered, no model in the store) with the flag set.
"$helpers/close-window" "Setup" >/dev/null 2>&1 || true
"$helpers/close-window" "Language Model" >/dev/null 2>&1 || true
defaults delete com.xiaolaidict SetupWindowShown 2>/dev/null || true
defaults delete com.xiaolaidict SettingsPane 2>/dev/null || true
defaults delete com.xiaolaidict SettingsSetupUnfinished 2>/dev/null || true
stash_models || true
defaults write com.xiaolaidict ShowLocalModelSetup -bool true
if ! relaunch_or_end_stage; then
    return 0
else
    opened=""
    for _ in $(seq 1 50); do board_on_screen && { opened=yes; break; }; sleep 0.2; done
    if [ "$opened" = yes ]; then
        pass "setup: with ShowLocalModelSetup set, a fresh install opens the board without being asked"
    else
        flunk "setup: with ShowLocalModelSetup set, nothing opened the board on a first launch"
    fi
    for _ in $(seq 1 50); do
        shown=$("$helpers/panel" com.xiaolaidict)
        printf '%s' "$shown" | grep -q "Looking for your dictionaries" || printf '%s' "$shown" | grep -q '"Checking…"' || break
        sleep 0.2
    done
    # **The model row, read through Accessibility, and the store asked separately.** What this can
    # see is the row's text and which controls exist — not whether a button is wired to anything,
    # which only clicking it would show, and which the `setup` stage's own click checks do below.
    # What must be true on a Mac where the model is not downloaded: it is still needed, the weaker
    # engine is named, both choices are offered.
    if printf '%s' "$shown" | grep -q "Local Model"; then
        model_row=$(printf '%s' "$shown" | tr ',' '\n' | grep -A14 "Local Model" || true)
        # Every state the row can be in, named — and **a download under way is a failure here**, not
        # a pass. Nothing in this stage asks for one, so a 3 GB download that has begun by the time
        # the board is first opened is the regression the rule exists to catch: it used to be one of
        # the accepted branches, two lines under a comment promising "nothing has begun downloading".
        # **"Ready" is a failure here, because this run emptied the store on purpose.** The whole
        # point of the restart above is to reach the fresh-reader branch, so a row reporting a model
        # means one of two things went wrong: the stash did not take, or the app is still reporting
        # the state it read before it. Accepting it as a pass is what let this stage stop measuring
        # the consent controls on the machine it runs on most — the row's "ready" branch was taken on
        # every run after the first, silently, for as long as the stash was not in place.
        if printf '%s' "$shown" | grep -q "Qwen3.5.*translates your sentences and chooses the meaning you met, on this Mac. Nothing is sent anywhere."; then
            flunk "setup: the store was emptied for this check and the row still reports a model — the stash did not take, or the board is showing state from before the restart ($(printf '%s' "$model_row" | head -c 300))"
        elif printf '%s' "$shown" | grep -q "Downloading Qwen3.5"; then
            flunk "setup: a 3 GB download had begun without the reader asking for one — $(printf '%s' "$model_row" | head -c 300)"
        elif printf '%s' "$shown" | grep -q "The local model needs 16 GB of memory."; then
            # Nothing to offer and nothing coming later, so the fallback must not say "Until then".
            if printf '%s' "$shown" | grep -q "Without a local model"; then
                pass "setup: the model row says this Mac cannot hold the model, and what answers instead"
            else
                flunk "setup: too little memory, and the fallback still promises a model later — $(printf '%s' "$model_row" | head -c 300)"
            fi
        elif printf '%s' "$shown" | grep -q "download stopped"; then
            # **Resume, not Download.** The button says what it does: the size a stopped download was
            # of, finishing what is already on disk.
            # Resume, the weaker engine named, **and a way to decline** — the row offers Not now in
            # this state exactly as in the one below, unless the reader has already declined, and
            # asking for only the first two let a stopped download become the one state the reader
            # could not get out of.
            if printf '%s' "$shown" | grep -q "Resume" && printf '%s' "$shown" | grep -q "misreads some" \
                && { printf '%s' "$shown" | grep -q "Not Now" || printf '%s' "$shown" | grep -q "still one click away"; }; then
                pass "setup: the model row reports a stopped download, offers to resume it, names what answers meanwhile, and can still be declined"
            else
                flunk "setup: a stopped download with no way to resume or decline it, or with nothing named as answering meanwhile — $(printf '%s' "$model_row" | head -c 300)"
            fi
        elif printf '%s' "$shown" | grep -q "misreads some" && printf '%s' "$shown" | grep -q "Download"; then
            # Both choices, unless the reader already chose **Not now** — which the row remembers,
            # and which takes its button away while leaving the download one click from here.
            if printf '%s' "$shown" | grep -q "Not Now" || printf '%s' "$shown" | grep -q "Nothing is waiting on you"; then
                pass "setup: the model row offers the download and Not now, and names the weaker engine meanwhile"
            else
                flunk "setup: the model row offers a download with no way to decline it — $(printf '%s' "$model_row" | head -c 300)"
            fi
        else
            flunk "setup: the model row is in no state this check knows — $(printf '%s' "$model_row" | head -c 300)"
        fi
    else
        # **A missing row is a failure, not a reason to check nothing.** Without this the branch
        # chain above was skipped whole whenever the row could not be found, and a board that had
        # lost its model row entirely reported no failures at all.
        flunk "setup: with ShowLocalModelSetup set, the board has no Local Model row, so none of its states were checked ($(printf '%s' "$shown" | head -c 200))"
    fi

    # Brought forward the way a reader would, so the controls below can be clicked — `click-element` refuses a control
    # in an app that is not frontmost — and so seeing it is remembered, which the last check of this stage needs.
    settle_after_launch
    if ! reach=$("$helpers/menu-click" com.xiaolaidict "Settings…" 2>&1); then
        flunk "setup: could not reach Settings… with ShowLocalModelSetup set ($reach)"
    fi
    for _ in $(seq 1 50); do
        [ "$(defaults read com.xiaolaidict SetupWindowShown 2>/dev/null || true)" = 1 ] && break
        sleep 0.2
    done

    # **And Not now is pressed.** Everything the row check above does is read text, and a button
    # wired to nothing reads exactly like one that works. Pressed, the row must say the reader is no
    # longer being waited on and must keep the download one click away — which is also the only way
    # the `.declined` branch is ever reached on this machine. Download is never pressed: three
    # gigabytes must not be fetched by a test run.
    #
    # **Here, and not where the row was read.** A board that opened by itself is behind whatever the
    # reader was using — that is the point of the check above it — and `click-element` refuses a
    # control in an app that is not frontmost. This is the first moment the board is both on the
    # fresh-reader branch and in front.
    if printf '%s' "$shown" | grep -q "Not Now"; then
        if declined_original=$(defaults read com.xiaolaidict LocalModelDeclined 2>/dev/null); then
            declined_had=yes
        else
            declined_had=no; declined_original=""
        fi
        restore_declined() { restore_default LocalModelDeclined "$declined_had" "$declined_original" -bool; }
        at_exit restore_declined
        # **Clicked until it takes.** The check above waits for the *flag* that says the board was
        # seen, which flips before the window has finished coming to the front — so the first click
        # landed while Ghostty was still over the button and `click-element` refused it, correctly.
        # Bounded, and it keeps the helper's own words: thrown away, "could not be clicked" reads as
        # a button that is not there, whatever actually stopped the click.
        pressed=no
        why=""
        for _ in $(seq 1 50); do
            if why=$("$helpers/click-element" com.xiaolaidict "Not Now" 2>&1); then pressed=yes; break; fi
            sleep 0.2
        done
        if [ "$pressed" != yes ]; then
            flunk "setup: Not now could not be clicked — $why ($(board_state))"
        else
            # **The decline itself, read from where it is kept.** The most direct evidence there
            # is, and it needs no Accessibility at all: `LocalModelDeclined` is what the button
            # writes and what the board reads back on the next launch.
            declined_flag=""
            for _ in $(seq 1 25); do
                declined_flag=$(defaults read com.xiaolaidict LocalModelDeclined 2>/dev/null || echo "")
                [ "$declined_flag" = 1 ] && break
                sleep 0.2
            done
            # **And what the row does about it — asked of the controls, never of the text.** The
            # board drew "Not now" as a button while the reader had not answered and as the row's
            # *status word* once they had: the same string either way, so a text dump could not tell
            # a button that had gone from one that had not. Since 2026-10-02 the button is "Not Now"
            # and the state is "Not downloaded", and the controls are still what is asked. Two earlier versions of this check
            # both reported a defect that did not exist — the first asserted a summary sentence
            # the board only draws when nothing else is outstanding, the second asserted that the
            # words were gone when they are deliberately still there.
            declined_shown=""
            declined_controls=""
            for _ in $(seq 1 25); do
                declined_shown=$("$helpers/panel" com.xiaolaidict)
                declined_controls=$(printf '%s' "$declined_shown" \
                    | python3 -c 'import json,sys; print("\n".join(n for w in json.load(sys.stdin)["windows"] for n in w["controls"]))')
                printf '%s\n' "$declined_controls" | grep -qx "Not Now" || break
                sleep 0.2
            done
            if [ "$declined_flag" != 1 ]; then
                flunk "setup: Not now did not record the reader's answer (LocalModelDeclined=${declined_flag:-unset})"
            elif printf '%s\n' "$declined_controls" | grep -qx "Not Now"; then
                flunk "setup: Not now is still a button after it was pressed — controls: $(printf '%s' "$declined_controls" | tr '\n' ',' | head -c 200)"
            elif ! printf '%s\n' "$declined_controls" | grep -qx "Download"; then
                flunk "setup: Not now took the download away — it is supposed to stay one click away (controls: $(printf '%s' "$declined_controls" | tr '\n' ',' | head -c 200))"
            else
                pass "setup: Not now is wired — the answer is recorded, the button goes, the download stays one click away"
            fi
            # The status word replaces the button, which is the row saying the reader answered.
            if printf '%s' "$declined_shown" | grep -q "Not downloaded"; then
                pass "setup: the row now says Not downloaded as its state rather than offering Not Now"
            else
                flunk "setup: the row lost its state word, so nothing on it says the reader answered"
            fi
            # **The summary sentence, only where it can be reached.** It is drawn when *nothing
            # else* is outstanding, so a machine still missing a permission never shows it — and
            # asserting it there reported a wiring defect that did not exist. This stage ran on
            # such a machine and said "Not now changed nothing", which was false and cost an
            # afternoon.
            if printf '%s' "$declined_shown" | grep -q "Nothing is waiting on you"; then
                if printf '%s' "$declined_shown" | grep -q "still one click away"; then
                    pass "setup: with nothing else outstanding, the summary says the model is still one click away"
                else
                    flunk "setup: nothing is waiting on the reader, but the summary does not say the model is still available"
                fi
            else
                echo "NOTE  setup: the board still has other things outstanding, so the declined summary is not reachable here"
            fi
            restore_declined
        fi
    fi
fi
# The reader's flag and source back before the last launch, which is the reader's own.
restore_local_model_setup

"$helpers/close-window" "Setup" >/dev/null 2>&1 || true
if ! relaunch_or_end_stage; then
    return 0
else
    # **A negative, so it is given time to fail.** Asserting "not on screen" the instant the app
    # starts would pass against a board that appears a moment later.
    sleep 3
    # **Guarded, because the passing case is the non-zero one.** `set -e` ends the script at the
    # first unguarded failure, so a bare call here killed the stage precisely when the board was
    # correctly absent — and `on_exit` would have recorded a failure for the assertion that never
    # ran. The `||` is what keeps it alive.
    board_seen=0
    board_on_screen || board_seen=$?
    case $board_seen in
        0) flunk "setup: the board opened again although it had been shown once" ;;
        2) flunk "setup: a Set Up window exists but is not drawn, so 'it did not open' cannot be claimed" ;;
        *) pass "setup: it does not open by itself a second time" ;;
    esac
fi

}
setup_stage
# Left as the reader found it. A board still on screen would be in front of whatever stage runs
# next, and the scenes stage measures which app is frontmost. The flag itself is put back by
# `restore_setup_shown`, registered before anything was launched.
"$helpers/close-window" "Setup" >/dev/null 2>&1 || true
# And the model store is put back here rather than at exit, because the model stage runs after this
# one and would otherwise measure a Mac with no weights on it.
unstash_models || flunk "setup: the model store was not put back"
fi

if want learning; then
# Real native actions; the exact freshly created encounter is the durable witness.
#
# **The stage is a function so a launch that failed ends it at once** (`launch_or_end_stage`): on 2026-10-08 a restart
# LaunchServices refused went on to "restored encounter lost after relaunch", which reads as data loss. The reader's
# ledger and settings are put back after the call, however the stage ended.
learning_stage() {
learning_evidence="$e2e_home/learning-evidence"
mkdir -p "$learning_evidence"
chmod 700 "$learning_evidence"
rm -f "$learning_evidence"/*.png "$learning_evidence"/*.json "$learning_evidence"/*capture.err
if ! defaults export com.xiaolaidict "$learning_evidence/preferences.plist"; then
    flunk "learning: the preferences could not be exported, so they could not be put back"; exit 1
fi
learning_dark_before=$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode' 2> "$learning_evidence/theme.err" || true)
if ! stop_app; then flunk "learning: app could not stop for ledger isolation"; exit 1; fi
if ! reader_reminders "$learning_evidence"; then
    flunk "learning: the reader's own pending reminders could not be read, so nothing was set aside"; exit 1
fi
# **The reader's ledger is this stage's to give back, and nothing may be removed on trust.**
#
# The restore runs from `on_exit` as `"$cleanup" || …`, and a function called on the left of `||`
# runs with `set -e` suspended: a `cp` that failed went on to `open "$app"`, which succeeded, so a
# ledger already deleted was reported restored. Every step below is checked by hand, and the copy is
# compared against the original by content — integrity, `user_version` and a SHA3 of every table and
# the schema — before the files it replaces are touched, and again once it is in place.
#
# A name of this run's own, never `original.sqlite`: a backup that failed would have left the last
# run's copy under that name, and restoring it would put back a ledger from another day. It is kept
# when the restore fails — then it may be the only copy — and removed once the *whole* restore is
# proved: removed as soon as the ledger was back, a later step that failed left the retry from
# `on_exit` failing at `cp` on the file the first attempt had deleted (audit-fix round 2, #21).
learning_backup="$learning_evidence/original-$(date +%Y%m%d-%H%M%S)-$$.sqlite"
learning_had_ledger=no
if [ -e "$ledger" ]; then
    learning_had_ledger=yes
    if ! learning_digest=$(ledger_digest "$ledger"); then
        flunk "learning: the reader's ledger could not be fingerprinted, so it is left alone"; exit 1
    fi
    if ! ledger_backup "$ledger" "$learning_backup" \
        || [ "$(ledger_digest "$learning_backup")" != "$learning_digest" ]; then
        flunk "learning: the ledger backup does not match the ledger, so it is left alone ($learning_backup)"; exit 1
    fi
fi
learning_restored=no
restore_learning_fixture() {
    local staged="$ledger.e2e-restore"
    # Run at the end of the stage, and again from `on_exit` in case the stage died first; the second
    # call finds nothing to do.
    [ "$learning_restored" = yes ] && return 0
    stop_app || { echo "restore: XiaolaiDict would not quit, so the ledger was not touched" >&2; return 1; }
    if [ "$learning_had_ledger" = yes ]; then
        # Staged beside the ledger, on the same volume, so the swap below is a rename.
        rm -f "$staged" || return 1
        cp "$learning_backup" "$staged" || { echo "restore: could not stage $learning_backup" >&2; return 1; }
        [ "$(ledger_digest "$staged")" = "$learning_digest" ] \
            || { echo "restore: the staged copy differs from the original; $learning_backup is kept" >&2; return 1; }
        # Reading a WAL-mode file leaves an empty `-wal` and `-shm` beside it; a reader writes nothing
        # to them, and they must not travel with a name that is about to change.
        rm -f "$staged-wal" "$staged-shm" "$ledger" "$ledger-wal" "$ledger-shm" || return 1
        mv "$staged" "$ledger" || { echo "restore: the staged copy is at $staged, $learning_backup is kept" >&2; return 1; }
        [ "$(ledger_digest "$ledger")" = "$learning_digest" ] \
            || { echo "restore: the restored ledger differs from the original; $learning_backup is kept" >&2; return 1; }
    else
        # There was none: the run's own ledger is removed, so the machine is as it was found.
        rm -f "$ledger" "$ledger-wal" "$ledger-shm" || return 1
        [ ! -e "$ledger" ] || return 1
    fi
    # `defaults import` *merges* — measured: a key written after the export survives the import — so
    # the keys this stage added (`libraryLayout`, `TextSize`, the keep policy) outlived it. The domain
    # is emptied first, and only once the export is known to be a readable plist.
    plutil -lint -s "$learning_evidence/preferences.plist" \
        || { echo "restore: the exported preferences are unreadable, so the domain was not replaced" >&2; return 1; }
    domain_cleared || return 1
    defaults import com.xiaolaidict "$learning_evidence/preferences.plist" \
        || { echo "restore: the preferences could not be imported; they are in $learning_evidence" >&2; return 1; }
    case $learning_dark_before in
        true|false) osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $learning_dark_before" || return 1 ;;
    esac
    reader_reminders_back "$learning_evidence" || return 1
    launch_app || { echo "restore: the ledger is back but XiaolaiDict did not reopen" >&2; return 1; }
    # **Last, once nothing else can fail**, so a retry from `on_exit` still has the copy to restore from.
    if [ "$learning_had_ledger" = yes ]; then
        rm -f "$learning_backup" "$learning_backup-wal" "$learning_backup-shm" || return 1
    fi
    learning_restored=yes
}
at_exit restore_learning_fixture
if ! reminders_set_aside; then
    flunk "learning: the reader's reminder settings could not be set aside, so no fixture was launched"; exit 1
fi
rm -f "$ledger" "$ledger-wal" "$ledger-shm"
defaults write com.xiaolaidict lookupKeepPolicy automatic
defaults write com.xiaolaidict libraryPane history
launch_or_end_stage || return 0
sw_vers > "$learning_evidence/host.txt"
codesign -dv "$app" 2> "$learning_evidence/build.txt"
learning_before=$(newest_row_id)
if ! fixture_why=$(ensure_one_lookup answered 2>&1); then
    flunk "learning: native lookup fixture could not be created: ${fixture_why:-no reason given}"
else
    learning_id=$(row_id_of "$learning_before" meeting com.apple.TextEdit)
    targets=0
    for _ in $(seq 1 40); do
        targets=$(sqlite3 "$ledger" "SELECT COUNT(*) FROM study_note_lookups WHERE lookup_id=$learning_id;")
        [ "$targets" -gt 0 ] && break
        sleep 0.25
    done
    [ "$targets" -gt 0 ] && pass "learning: automatic collection attached a dictionary target" || flunk "learning: answered fixture did not create an automatic target"
    sqlite3 "$ledger" "SELECT l.id,l.result,l.keep_policy,l.primary_dictionary,n.target_kind,n.confirmed_at FROM lookups l LEFT JOIN study_note_lookups k ON k.lookup_id=l.id LEFT JOIN study_notes n ON n.id=k.note_id WHERE l.id=$learning_id;" > "$learning_evidence/lookup-state.txt"
    if ! why=$("$helpers/menu-click" com.xiaolaidict "Library" 2>&1); then
        flunk "learning: Library menu action failed: $why"
    else
        sleep 1
        for pane in History Saved Review Discarded History; do
            # By identifier: the pane's name is also its window's title and a word on its cards.
            if "$helpers/click-element" com.xiaolaidict --row "library-pane-$(printf '%s' "$pane" | tr '[:upper:]' '[:lower:]')" >/dev/null 2>&1; then
                sleep 0.5
                pane_report=$("$helpers/panel" com.xiaolaidict)
                printf '%s\n' "$pane_report" > "$learning_evidence/$pane.json"
                if ! screencapture -x "$learning_evidence/$pane.png" 2> "$learning_evidence/$pane-capture.err"; then flunk "learning: native $pane screenshot capture denied"; fi
                # The window is titled by its pane since 2026-10-02; "Library" names no window.
                screen_report=$("$helpers/on-screen" com.xiaolaidict "$pane")
                if python3 - "$pane_report" "$pane" "$screen_report" <<'PYLIBRARY'
import json,sys
r=json.loads(sys.argv[1]); pane=sys.argv[2]
windows=r.get('windows',[])
panes=('History','Saved','Review','Discarded')
titled=[w.get('title','') for w in windows if w.get('title','').startswith(panes)]
assert len(titled)==1, f'expected one Library window, found {titled}'
assert titled[0].startswith(pane), f'the window is titled {titled[0]!r} while showing {pane}'
text=str(windows)
assert any(w.get('drawn') for w in json.loads(sys.argv[3]).get('matches',[])), 'Library window is not composited'
expected={'History':'reading','Saved':'Filters','Review':'Review today','Discarded':'No Discarded Readings'}[pane]
assert expected in text, f'{pane} detail absent: {expected}'
PYLIBRARY
                then pass "learning: native Library pane $pane detail is visible"
                else flunk "learning: $pane click did not show its detail"; fi
            else
                flunk "learning: native Library pane $pane is unreachable"
            fi
        done
        # **Select the card, then the toolbar: the route a reader without a pointer takes.** The
        # card is one combined element to Accessibility, so its own Discard is an action of the card
        # and not an element a click can be aimed at.
        discard_selected() {
            "$helpers/click-element" com.xiaolaidict --row "library-history-row-$learning_id" >/dev/null 2>&1 \
                && sleep 0.6 && "$helpers/click-element" com.xiaolaidict library-selection-discard >/dev/null 2>&1
        }
        if discard_selected; then
            sleep 1
            disposition=$(sqlite3 "$ledger" "SELECT disposition FROM lookups WHERE id=$learning_id;")
            [ "$disposition" = discarded ] && pass "learning: Discard commits the exact encounter" || flunk "learning: Discard did not persist ($disposition)"
            if "$helpers/click-element" com.xiaolaidict library-undo >/dev/null 2>&1; then
                sleep 1
                disposition=$(sqlite3 "$ledger" "SELECT disposition FROM lookups WHERE id=$learning_id;")
                [ "$disposition" = kept ] && pass "learning: Undo restores the exact encounter" || flunk "learning: Undo did not persist ($disposition)"
            else
                flunk "learning: durable Undo control is unreachable"
            fi
        else
            flunk "learning: Discard control is unreachable or ambiguous"
        fi
        if discard_selected; then
            relaunch_or_end_stage || return 0
            reopened=""
            for _ in $(seq 1 40); do
                if "$helpers/menu-click" com.xiaolaidict "Library" >/dev/null 2>&1; then reopened=yes; break; fi
                sleep 0.25
            done
            if [ -n "$reopened" ] && "$helpers/click-element" com.xiaolaidict --row library-pane-discarded >/dev/null 2>&1; then
                sleep 1
                "$helpers/panel" com.xiaolaidict > "$learning_evidence/Discarded-populated.json"
                screencapture -x "$learning_evidence/Discarded-populated.png" || flunk "learning: populated Discarded capture failed"
                disposition=$(sqlite3 "$ledger" "SELECT disposition FROM lookups WHERE id=$learning_id;")
                [ "$disposition" = discarded ] && pass "learning: Discard persists across relaunch" || flunk "learning: Discard was lost at relaunch"
                if "$helpers/click-element" com.xiaolaidict --row "library-discarded-row-$learning_id" >/dev/null 2>&1 \
                   && sleep 0.6 && "$helpers/click-element" com.xiaolaidict library-selection-restore >/dev/null 2>&1; then
                    sleep 1
                    disposition=$(sqlite3 "$ledger" "SELECT disposition FROM lookups WHERE id=$learning_id;")
                    [ "$disposition" = kept ] && pass "learning: Discarded Restore commits exact encounter after relaunch" || flunk "learning: Restore did not persist"
                else flunk "learning: Discarded Restore control unreachable"; fi
                "$helpers/click-element" com.xiaolaidict --row library-pane-history >/dev/null 2>&1 || flunk "learning: History return failed"
            else flunk "learning: Discarded recovery pane unreachable after relaunch"; fi
        else flunk "learning: the encounter could not be discarded a second time, so its survival across a relaunch was not tested"; fi
        for appearance in Light Dark; do
            wanted_dark=false; [ "$appearance" != Dark ] || wanted_dark=true
            if ! osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $wanted_dark" 2> "$learning_evidence/$appearance-theme.err"; then
                flunk "learning: cannot set actual system $appearance appearance"
                continue
            fi
            defaults write com.xiaolaidict TextSize large
            relaunch_or_end_stage || return 0
            restarted=""
            for _ in $(seq 1 40); do
                if why=$("$helpers/menu-click" com.xiaolaidict "Library" 2>&1); then restarted=yes; break; fi
                sleep 0.25
            done
            if [ -n "$restarted" ]; then
                sleep 1
                "$helpers/panel" com.xiaolaidict > "$learning_evidence/large-$appearance.json"
                if screencapture -x "$learning_evidence/large-$appearance.png" 2> "$learning_evidence/large-$appearance-capture.err"; then
                    screen_report=$("$helpers/on-screen" com.xiaolaidict History)
                    if python3 - "$learning_evidence/large-$appearance-window.png" "$screen_report" "$appearance" <<'PYAPPEARANCE'
# The window frame is in points and a screenshot is in pixels: a Retina display draws two of one
# per point, so a point used as a pixel sampled a spot up and to the left of the one meant. The
# window is captured by its own frame instead -- screencapture -R takes points -- and sampled by
# fraction of the image, which no display scale can move.
from PIL import Image
import json,subprocess,sys
windows=json.loads(sys.argv[2])['matches']
w=next(w for w in windows if w.get('drawn'))
region=','.join(str(round(w[k])) for k in ('x','y','width','height'))
subprocess.run(['screencapture','-x','-R',region,sys.argv[1]],check=True,timeout=20)
im=Image.open(sys.argv[1]).convert('RGB')
scale=im.width/round(w['width'])
assert scale >= 1 and abs(im.height-round(w['height'])*scale) <= scale, f'capture {im.size} is not the window {region}'
x,y=int(im.width*.8),int(im.height*.8)
# The crop's raw RGB bytes, not getdata(): Pillow deprecates that and removes it in Pillow 14 (2027-10), and its
# warning, on stderr, landed in the middle of another stage's line in the run log (E2E Mac, 2026-10-09). Every channel
# of every pixel, averaged: the same number the per-pixel sum gave.
channels=im.crop((x-5,y-5,x+5,y+5)).tobytes()
brightness=sum(channels)/len(channels)
assert (brightness < 120) if sys.argv[3]=='Dark' else (brightness > 150), f'appearance witness brightness {brightness}'
print(f'{sys.argv[3]} rendered background brightness: {brightness:.1f}')
PYAPPEARANCE
                    then pass "learning: actual native large-text $appearance appearance is rendered"
                    else flunk "learning: rendered $appearance screenshot disagrees with requested appearance"; fi
                else flunk "learning: native large-text $appearance screenshot denied"; fi
            else flunk "learning: the Library would not open after the large-text $appearance relaunch: $why"; fi
        done
        restored=$(sqlite3 "$ledger" "SELECT disposition FROM lookups WHERE id=$learning_id;")
        [ "$restored" = kept ] && pass "learning: restored encounter remains kept after relaunch" || flunk "learning: restored encounter lost after relaunch"
        # The expanded fixture is installed only after the original live encounter assertions.
        # Its custom Saved note has no encounter; the long and absent answers have real note IDs.
        # The learning EXIT cleanup above owns the ledger, defaults and theme restoration.
        if ! stop_app; then
            flunk "learning: cannot stop app for expanded isolated fixture"
        elif python3 "$helpers/library-layout.py" seed "$ledger" "$learning_id" "$learning_evidence/layout-fixture.json"; then
            defaults delete com.xiaolaidict libraryLayout >/dev/null 2>&1 || true
            defaults write com.xiaolaidict TextSize standard
            defaults write com.xiaolaidict libraryPane history
            launch_or_end_stage || return 0
            # Clicked until it takes, like the two relaunches above: one attempt straight after a
            # launch failed on the E2E Mac with the item present, and the reason went to /dev/null.
            expanded_open=""
            for _ in $(seq 1 40); do
                if why=$("$helpers/menu-click" com.xiaolaidict "Library" 2>&1); then expanded_open=yes; break; fi
                sleep 0.25
            done
            if [ -n "$expanded_open" ]; then
                layout_verdicts=$(python3 "$helpers/library-layout.py" run "$helpers" "$ledger" "$learning_evidence" 2>&1 || true)
                printf '%s\n' "$layout_verdicts" > "$learning_evidence/layout-run.txt"
                consume_verdicts learning-layout "$layout_verdicts"
            else flunk "learning: expanded Library fixture did not open ($why)"; fi
        else flunk "learning: expanded isolated fixture failed its positive controls"; fi
    fi
fi
}
learning_stage
# **Put back before the next stage, not when the script ends.** Registered with `at_exit` alone, the
# restore waited for the whole run, so every stage after this one ran on this stage's fixture ledger
# and settings: `model` asserted against rows the restore then threw away, and read as a product fault.
if restore_learning_fixture; then
    pass "learning: the reader's ledger and settings are back before the next stage"
else
    flunk "learning: the reader's ledger could not be put back; the run stops so no stage writes over it"
    exit 1
fi
fi

if want review; then
# 15. **Review, driven the way a reader drives it** — ADR-0032's surface in a signed bundle, which no
#     unit test reaches: keys posted as the keyboard posts them, the accessibility tree read as VoiceOver
#     reads it, Dictionary opening, and the ledger row each key writes. Owed since ADR-0032; WI-0 of the
#     review module plan. The claims, in the order a reader meets them, are `Tools/e2e/review.py`'s.
#
#     **On a ledger of its own, by the learning stage's mechanism.** The reader's preferences are
#     exported and their ledger backed up and proved equal by content before anything is removed; at
#     the end both are put back and the ledger proved equal again, before the next stage. Every step is
#     checked by hand: the restore also runs from `on_exit`, on the left of `||`, where `set -e` does
#     nothing. Into the empty ledger the app creates go eight cards the reader wrote, overdue, whose
#     answers are secrets no surface could produce by itself — so "no answer in the tree" is a search
#     for a string that cannot be there by accident.
#
#     **A function, so a launch that failed ends the stage at once** (`launch_or_end_stage`); Dictionary, the ledger and
#     the settings are put back after the call, however the stage ended.
review_stage() {
review_evidence="$e2e_home/review-evidence"
mkdir -p "$review_evidence"
chmod 700 "$review_evidence"
rm -f "$review_evidence"/*.json "$review_evidence"/*.png "$review_evidence"/*.txt
if ! defaults export com.xiaolaidict "$review_evidence/preferences.plist"; then
    flunk "review: the preferences could not be exported, so they could not be put back"; exit 1
fi
if ! stop_app; then flunk "review: XiaolaiDict would not stop, so the ledger was not set aside"; exit 1; fi
if ! reader_reminders "$review_evidence"; then
    flunk "review: the reader's own pending reminders could not be read, so nothing was set aside"; exit 1
fi
# A name of this run's own, kept if the restore fails — then it may be the only copy — and removed only
# once the whole restore has succeeded, so a retry from `on_exit` can still copy it back (#21).
review_backup="$review_evidence/original-$(date +%Y%m%d-%H%M%S)-$$.sqlite"
review_had_ledger=no
review_digest=""
if [ -e "$ledger" ]; then
    review_had_ledger=yes
    if ! review_digest=$(ledger_digest "$ledger"); then
        flunk "review: the reader's ledger could not be fingerprinted, so it is left alone"; exit 1
    fi
    if ! ledger_backup "$ledger" "$review_backup" \
        || [ "$(ledger_digest "$review_backup")" != "$review_digest" ]; then
        flunk "review: the ledger backup does not match the ledger, so it is left alone ($review_backup)"; exit 1
    fi
fi
review_restored=no
restore_review_fixture() {
    local staged="$ledger.e2e-restore"
    # Run at the end of the stage, and again from `on_exit` in case the stage died first; the second
    # call finds nothing to do.
    [ "$review_restored" = yes ] && return 0
    stop_app || { echo "restore: XiaolaiDict would not quit, so the ledger was not touched" >&2; return 1; }
    if [ "$review_had_ledger" = yes ]; then
        # Staged beside the ledger, on the same volume, so the swap below is a rename.
        rm -f "$staged" || return 1
        cp "$review_backup" "$staged" || { echo "restore: could not stage $review_backup" >&2; return 1; }
        [ "$(ledger_digest "$staged")" = "$review_digest" ] \
            || { echo "restore: the staged copy differs from the original; $review_backup is kept" >&2; return 1; }
        rm -f "$staged-wal" "$staged-shm" "$ledger" "$ledger-wal" "$ledger-shm" || return 1
        mv "$staged" "$ledger" || { echo "restore: the staged copy is at $staged, $review_backup is kept" >&2; return 1; }
        [ "$(ledger_digest "$ledger")" = "$review_digest" ] \
            || { echo "restore: the restored ledger differs from the original; $review_backup is kept" >&2; return 1; }
    else
        # There was none: the run's own ledger is removed, so the machine is as it was found.
        rm -f "$ledger" "$ledger-wal" "$ledger-shm" || return 1
        [ ! -e "$ledger" ] || return 1
    fi
    # `defaults import` merges, so the domain is emptied first — and only once the export is known to
    # be a readable plist.
    plutil -lint -s "$review_evidence/preferences.plist" \
        || { echo "restore: the exported preferences are unreadable, so the domain was not replaced" >&2; return 1; }
    domain_cleared || return 1
    defaults import com.xiaolaidict "$review_evidence/preferences.plist" \
        || { echo "restore: the preferences could not be imported; they are in $review_evidence" >&2; return 1; }
    reader_reminders_back "$review_evidence" || return 1
    launch_app || { echo "restore: the ledger is back but XiaolaiDict did not reopen" >&2; return 1; }
    # **Last, once nothing else can fail**, so a retry from `on_exit` still has the copy to restore from.
    if [ "$review_had_ledger" = yes ]; then
        rm -f "$review_backup" "$review_backup-wal" "$review_backup-shm" || return 1
    fi
    review_restored=yes
}
at_exit restore_review_fixture
# **Dictionary is left as it was found.** `E` opens it; a copy this stage started is quit again, by the
# executable it runs from rather than by name, and one that was already running is left alone.
review_dictionary=/System/Applications/Dictionary.app/Contents/MacOS/Dictionary
review_dictionary_was_running=no
if is_running "$review_dictionary"; then review_dictionary_was_running=yes; fi
quit_review_dictionary() {
    [ "$review_dictionary_was_running" = yes ] && return 0
    find_pids "$review_dictionary"
    [ "${#PIDS[@]}" -eq 0 ] && return 0
    kill -TERM "${PIDS[@]}" 2>/dev/null || true
    for _ in $(seq 1 40); do is_running "$review_dictionary" || return 0; sleep 0.25; done
    echo "quit_review_dictionary: Dictionary would not quit" >&2
    return 1
}
at_exit quit_review_dictionary

# The schema is the app's own: an empty ledger, created by the bundle under test and waited for by the
# tables the fixture writes, rather than restated here. The Library opens on Review, as it does for a
# reader who last used it. **With reminders off and no log**, so no launch here touches the reader's.
if ! reminders_set_aside; then
    flunk "review: the reader's reminder settings could not be set aside, so no fixture was launched"; exit 1
fi
rm -f "$ledger" "$ledger-wal" "$ledger-shm"
defaults write com.xiaolaidict libraryPane review
launch_or_end_stage || return 0
review_tables=""
for _ in $(seq 1 50); do
    review_tables=$(sqlite3 -readonly "$ledger" "select count(*) from sqlite_master where type = 'table' and name in ('study_cards', 'study_keep_metadata', 'review_events')" 2>/dev/null || true)
    [ "$review_tables" = 3 ] && break
    sleep 0.2
done
review_seeded=no
if [ "$review_tables" != 3 ]; then
    flunk "review: the app never created the study tables in its new ledger (found ${review_tables:-none} of 3)"
elif ! stop_app; then
    flunk "review: XiaolaiDict would not stop, so the fixture was not written"
else
    # Namespaced by the reader's study dictionary, which is what the sitting is scoped to; with none
    # chosen the sitting reads every namespace, and any name will do.
    review_primary=$(defaults read com.xiaolaidict PrimaryDictionary 2>/dev/null || true)
    if why=$(python3 "$helpers/review.py" seed "$ledger" "${review_primary:-e2e.review.fixture}" \
            "$review_evidence/fixture.json" 2>&1); then
        review_seeded=yes
    else
        flunk "review: the fixture could not be seeded: $(printf '%s' "$why" | tail -3)"
    fi
fi

if [ "$review_seeded" = yes ]; then
    # **The app's own word first, from inside the bundle.** Whether the queue asks the seeded cards at
    # all, and what the model's presentation holds on each side of the reveal — neither of which the
    # window, read from outside, can tell apart from a harness that seeded the wrong thing. Run with
    # the app stopped, so one process has the ledger; it writes nothing either way.
    review_report="$reports/review-report.json"
    run_bounded --review-report "$review_report" 60 review-report || true
    cp "$review_report" "$review_evidence/review-report.json" 2>/dev/null || true
    verdicts=$(python3 - "$review_report" "$review_evidence/fixture.json" 2>&1 <<'PYREVIEW' || true
import json, sys
def say(ok, good, bad): print(("PASS\t" + good) if ok else ("FAIL\t" + bad))
try:
    r = json.load(open(sys.argv[1]))
except (OSError, ValueError) as error:
    say(False, "", f"review: --review-report wrote no report ({error})")
    print("DONE")
    sys.exit(0)
answers = {card["word"]: card["answer"] for card in json.load(open(sys.argv[2]))["cards"]}
front, back = r.get("front") or {}, r.get("back") or {}
say(r.get("due") == len(answers) and r.get("heldBack") == 0,
    f"review: the queue of the app offers all {len(answers)} seeded cards, none held back",
    f"review: the queue of the app offers {r.get('due')} of {len(answers)} seeded cards, "
    f"{r.get('heldBack')} held back ({r.get('problem')})")
word = front.get("word")
say(front.get("stage") == "asking" and word in answers and front.get("answerShown") is False
    and "answer" not in front,
    f"review: the model asks {word} with no answer in its presentation",
    f"review: the first card is not an unanswered question: {front}")
say(back.get("word") == word and back.get("answerShown") is True and back.get("answer") == answers.get(word),
    f"review: after the reveal the presentation holds the answer of {word} and no other",
    f"review: after the reveal the presentation holds {back.get('answer')!r} for {back.get('word')}, "
    f"wanted {answers.get(word)!r}")
print("DONE")
PYREVIEW
)
    consume_verdicts review-report "$verdicts"

    # **Then the window, from outside, as a reader.** `review.py` prints a verdict per claim and DONE.
    launch_or_end_stage || return 0
    review_verdicts=$(python3 "$helpers/review.py" run "$helpers" "$ledger" "$review_evidence/fixture.json" \
        "$review_evidence" 2>&1 || true)
    printf '%s\n' "$review_verdicts" > "$review_evidence/run.txt"
    consume_verdicts review "$review_verdicts"
fi
}
review_stage
# **Put back before the next stage, not when the script ends**, as the learning stage learned to: a
# stage after this one would otherwise measure the fixture ledger and read as a product fault.
quit_review_dictionary || flunk "review: the Dictionary this stage opened would not quit"
if restore_review_fixture; then
    pass "review: the reader's ledger and settings are back before the next stage"
else
    flunk "review: the reader's ledger could not be put back; the run stops so no stage writes over it"
    exit 1
fi
fi

if want reminder; then
# 16. **The review reminder (WI-7), as far as a Mac with nobody at it can take it** — review module plan
#     §5.4. The app plans from a ledger of its own, `--reminder-report` reads the notification center
#     from inside the bundle (it answers per app, so nothing outside can), and three settings are
#     written in turn with the app stopped: off, on at an hour two or three hours ahead, and off again.
#
#     **Nothing here can raise the system prompt.** The app asks only from its Settings switch, which
#     this stage never touches, so what needs the grant runs only on a Mac where a person has given it
#     and is printed NOT RUN, with the reason, where they have not. Requests this stage made are taken
#     back by the app itself — turned off with this run's log in place — before anything is restored,
#     whenever the stage turned reminders on, whether or not it got as far as reporting.
#
#     **The reader's own pending requests are read first, never touched, and proved still there last.**
#     Every fixture launch here is off with no log (`reminders_set_aside`), which touches nothing. Turning
#     reminders on and off cannot be done beside them — the app's requests share one namespace, so the
#     `on` phase replaces the reader's and the `disabled` phase removes them — and nothing outside the app
#     can put one back: only its process adds a request, and it adds what it plans now, so a request the
#     reader had, planned in another zone, came back at another instant (audit-fix round 1, #28). So
#     with any of the reader's own pending, only the `off` phase runs, and the other two are NOT RUN with
#     the reason; the restore fails unless every one is pending again at its own instant.
#
#     The ledger and the preferences are set aside and put back by the review stage's mechanism, each
#     step checked by hand.
#
#     **A function, so a launch that failed ends the stage at once** (`launch_or_end_stage`); what only a person can do
#     is said, and the ledger, the settings and the reader's reminders are put back, after the call.
reminder_stage() {
reminder_evidence="$e2e_home/reminder-evidence"
mkdir -p "$reminder_evidence"
chmod 700 "$reminder_evidence"
rm -f "$reminder_evidence"/*.json "$reminder_evidence"/*.txt
if ! defaults export com.xiaolaidict "$reminder_evidence/preferences.plist"; then
    flunk "reminder: the preferences could not be exported, so they could not be put back"; exit 1
fi
if ! stop_app; then flunk "reminder: XiaolaiDict would not stop, so the ledger was not set aside"; exit 1; fi
reminder_backup="$reminder_evidence/original-$(date +%Y%m%d-%H%M%S)-$$.sqlite"
reminder_had_ledger=no
reminder_digest=""
if [ -e "$ledger" ]; then
    reminder_had_ledger=yes
    if ! reminder_digest=$(ledger_digest "$ledger"); then
        flunk "reminder: the reader's ledger could not be fingerprinted, so it is left alone"; exit 1
    fi
    if ! ledger_backup "$ledger" "$reminder_backup" \
        || [ "$(ledger_digest "$reminder_backup")" != "$reminder_digest" ]; then
        flunk "reminder: the ledger backup does not match the ledger, so it is left alone ($reminder_backup)"; exit 1
    fi
fi
# **What the reader has pending, before any launch here can remove it** — read with the reader's own
# ledger and settings, the app stopped. Unreadable, the stage does not run: it could not say it left
# alone what it could not see.
if ! reader_reminders "$reminder_evidence"; then
    flunk "reminder: the reader's own pending reminders could not be read, so nothing was set aside"; exit 1
fi
# reminder_phases <reader-report>: the phases this stage may run, in order. **`off` alone while the reader
# has any review request pending**: `on` would replace theirs with the stage's own and `disabled` would
# remove them, and neither can be undone from outside the app (#28).
reminder_phases() {
    if [ "$(reminder_pending "$1")" = 0 ]; then echo "off on disabled"; else echo off; fi
}
reminder_run=$(reminder_phases "$reminder_evidence/reader.json")
# The hour this run plans for, and the first reminder it expects — computed here, not by the app.
reminder_hour=$(python3 "$helpers/reminder.py" hour)
python3 "$helpers/reminder.py" expect "$reminder_hour" > "$reminder_evidence/expect.json"
reminder_first=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$reminder_evidence/expect.json")
reminder_settings() {  # reminder_settings <on|off>: the reader's reminder settings, written for this run
    defaults write com.xiaolaidict reviewReminderSettings -data \
        "$(python3 "$helpers/reminder.py" settings "$1" "$reminder_hour")"
}
# The Settings switch writes an empty log before it turns reminders on, so the app can read "on, and
# no log" as a log that was lost, which spends the day (WI-8). Turning them on here does the same.
reminder_log_empty() {
    defaults write com.xiaolaidict reviewReminderLog -data "$(python3 "$helpers/reminder.py" log)"
}
reminder_restored=no
# Set before the `on` phase writes its settings: from then on this stage may have requests pending,
# whatever it managed to report.
reminder_activated=no
restore_reminder_fixture() {
    local staged="$ledger.e2e-restore" left report
    [ "$reminder_restored" = yes ] && return 0
    stop_app || { echo "restore: XiaolaiDict would not quit, so the ledger was not touched" >&2; return 1; }
    # **What this run added is taken back by the app**, with this run's log still in place so it knows
    # what it made: turned off, it withdraws every open day and removes every request. Decided by what
    # is pending now, asked afresh, whenever the stage turned reminders on — never by the `on` phase's
    # report, which a stage interrupted after its launch and before its report never wrote. A report
    # that cannot be read is no evidence that nothing is pending, so it is withdrawn the same way.
    if [ "$reminder_activated" = yes ]; then
        report=$(run_report --reminder-report 60) || true
        printf '%s' "$report" > "$reminder_evidence/restore-before.json"
        if [ "$(reminder_pending "$reminder_evidence/restore-before.json")" != 0 ]; then
            reminder_settings off || return 1
            launch_app || return 1
            python3 "$helpers/reminder.py" wait "$reminder_first" withdrawn 30 >/dev/null || true
            stop_app || return 1
            report=$(run_report --reminder-report 60) || true
            printf '%s' "$report" > "$reminder_evidence/restore.json"
            left=$(reminder_pending "$reminder_evidence/restore.json")
            [ "$left" = 0 ] || { echo "restore: $left review request(s) are still pending on this Mac" >&2; return 1; }
        fi
    fi
    if [ "$reminder_had_ledger" = yes ]; then
        rm -f "$staged" || return 1
        cp "$reminder_backup" "$staged" || { echo "restore: could not stage $reminder_backup" >&2; return 1; }
        [ "$(ledger_digest "$staged")" = "$reminder_digest" ] \
            || { echo "restore: the staged copy differs from the original; $reminder_backup is kept" >&2; return 1; }
        rm -f "$staged-wal" "$staged-shm" "$ledger" "$ledger-wal" "$ledger-shm" || return 1
        mv "$staged" "$ledger" || { echo "restore: the staged copy is at $staged, $reminder_backup is kept" >&2; return 1; }
        [ "$(ledger_digest "$ledger")" = "$reminder_digest" ] \
            || { echo "restore: the restored ledger differs from the original; $reminder_backup is kept" >&2; return 1; }
    else
        rm -f "$ledger" "$ledger-wal" "$ledger-shm" || return 1
        [ ! -e "$ledger" ] || return 1
    fi
    # `defaults import` merges, so the domain is emptied first — and only once the export is known to
    # be a readable plist. This is what takes the reminder settings and log back to the reader's.
    plutil -lint -s "$reminder_evidence/preferences.plist" \
        || { echo "restore: the exported preferences are unreadable, so the domain was not replaced" >&2; return 1; }
    domain_cleared || return 1
    defaults import com.xiaolaidict "$reminder_evidence/preferences.plist" \
        || { echo "restore: the preferences could not be imported; they are in $reminder_evidence" >&2; return 1; }
    # **The reader's own pending requests, proved still there — never regenerated.** The stage left them
    # alone (its launches were off with no log, and with any of theirs pending it turned nothing on), so
    # each must be pending at the instant it had; one that is not fails the restore rather than being
    # planned again by the app at whatever instant it would choose now (#28).
    reader_reminders_back "$reminder_evidence" || return 1
    launch_app || { echo "restore: the ledger is back but XiaolaiDict did not reopen" >&2; return 1; }
    # **Last, once nothing else can fail**, so a retry from `on_exit` still has the copy to restore from.
    if [ "$reminder_had_ledger" = yes ]; then
        rm -f "$reminder_backup" "$reminder_backup-wal" "$reminder_backup-shm" || return 1
    fi
    reminder_restored=yes
}
at_exit restore_reminder_fixture

# An empty ledger the app creates, and the review stage's eight overdue cards in it: a sitting of eight
# at every fire time ahead. **Launched with reminders off and no log**, so it touches nothing of the
# reader's; each phase below writes its own settings.
if ! reminders_set_aside; then
    flunk "reminder: the reader's reminder settings could not be set aside, so no fixture was launched"; exit 1
fi
rm -f "$ledger" "$ledger-wal" "$ledger-shm"
launch_or_end_stage || return 0
reminder_tables=""
for _ in $(seq 1 50); do
    reminder_tables=$(sqlite3 -readonly "$ledger" "select count(*) from sqlite_master where type = 'table' and name in ('study_cards', 'study_keep_metadata', 'review_events')" 2>/dev/null || true)
    [ "$reminder_tables" = 3 ] && break
    sleep 0.2
done
reminder_seeded=no
if [ "$reminder_tables" != 3 ]; then
    flunk "reminder: the app never created the study tables in its new ledger (found ${reminder_tables:-none} of 3)"
elif ! stop_app; then
    flunk "reminder: XiaolaiDict would not stop, so the fixture was not written"
else
    reminder_primary=$(defaults read com.xiaolaidict PrimaryDictionary 2>/dev/null || true)
    if why=$(python3 "$helpers/review.py" seed "$ledger" "${reminder_primary:-e2e.review.fixture}" \
            "$reminder_evidence/fixture.json" 2>&1); then
        reminder_seeded=yes
    else
        flunk "reminder: the fixture could not be seeded: $(printf '%s' "$why" | tail -3)"
    fi
fi

reminder_grant=""
if [ "$reminder_seeded" = yes ]; then
    reminder_cards=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["cards"]))' "$reminder_evidence/fixture.json")
    # Each phase: the settings written with the app stopped, the app run so its launch re-plans, then
    # stopped, and the report read — the notification center keeps its pending list with the app quit.
    for reminder_phase in $reminder_run; do
        case $reminder_phase in
            on) reminder_activated=yes; reminder_log_empty && reminder_settings on ;;
            *) reminder_settings off ;;
        esac
        # Off at the start is off with no log at all, as a reader who never turned reminders on has.
        [ "$reminder_phase" = off ] && { defaults delete com.xiaolaidict reviewReminderLog >/dev/null 2>&1 || true; }
        if [ "$reminder_phase" != off ]; then
            launch_or_end_stage || return 0
            if [ "$reminder_grant" = granted ]; then
                # The log is written before the system is asked, so its state is the handshake.
                case $reminder_phase in on) reminder_state=added ;; *) reminder_state=withdrawn ;; esac
                python3 "$helpers/reminder.py" wait "$reminder_first" "$reminder_state" 30 \
                    > "$reminder_evidence/$reminder_phase-wait.txt" 2>&1 || true
            else
                # Nothing to wait for without the grant: the launch's pass adds nothing. Time for it
                # to add what it must not.
                sleep 5
            fi
            stop_app || flunk "reminder: XiaolaiDict would not stop after the $reminder_phase phase"
        fi
        reminder_json=$(run_report --reminder-report 60) || true
        printf '%s' "$reminder_json" > "$reminder_evidence/$reminder_phase.json"
        [ "$reminder_phase" = off ] && reminder_grant=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("grant", ""))' "$reminder_evidence/off.json" 2>/dev/null || true)
        verdicts=$(python3 - "$reminder_phase" "$reminder_evidence/$reminder_phase.json" "$reminder_evidence/expect.json" "$reminder_cards" "$reminder_evidence/reader.json" 2>&1 <<'PYREMINDER' || true
import json, sys, time
def say(ok, good, bad): print(("PASS\t" + good) if ok else ("FAIL\t" + bad))
def notrun(what, why): print("NOTRUN\t" + what + " — " + why)
phase, path, expect_path, seeded, reader_path = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
try:
    r = json.load(open(path))
except (OSError, ValueError) as error:
    say(False, "", f"reminder: --reminder-report wrote no report in the {phase} phase ({error})")
    print("DONE")
    sys.exit(0)
expect = json.load(open(expect_path))
grant = r.get("grant")
granted = grant == "granted"
planned = r.get("planned") or []
pending = [p for p in (r.get("pending") or []) if str(p.get("id", "")).startswith("review.")]
log = {entry.get("id"): entry for entry in (r.get("log") or [])}
first = log.get(expect["id"]) or {}
if phase == "off":
    say(grant in ("granted", "notAsked", "declined"),
        f"reminder: the bundle reads its notification grant ({grant})",
        f"reminder: the bundle could not read its notification grant ({grant}; {r.get('problem')})")
    say(r.get("enabled") is False and planned == [],
        "reminder: off, the settings plan nothing",
        f"reminder: off, the settings plan {planned}")
    # **Nothing but the reader's own**, which the stage left alone: none on a Mac nobody gave the grant.
    # One of theirs whose time passed since it was read may have fired; every one still ahead is there.
    own = {str(p.get("id")): p.get("fireAt") for p in (json.load(open(reader_path)).get("pending") or [])
           if str(p.get("id", "")).startswith("review.")}
    held = {str(p.get("id")): p.get("fireAt") for p in pending}
    say(all(own.get(i) == at for i, at in held.items())
        and all(held.get(i) == at for i, at in own.items() if at is not None and at > time.time()),
        "reminder: off, nothing of this app's is pending" + (f" but the reader's own {len(own)}" if own else ""),
        f"reminder: off, requests were pending before anything was planned: {pending} (the reader's own: {own})")
elif phase == "on":
    say(r.get("logRead") == "log",
        "reminder: on, the log the switch writes first is kept and reads",
        f"reminder: on, the log read as {r.get('logRead')}, so today is planned as spent")
    head = planned[0] if planned else {}
    say(r.get("enabled") is True and head.get("id") == expect["id"] and head.get("fireAt") == expect["fireAt"],
        f"reminder: on, the first reminder is {expect['id']} at the hour chosen, in this Mac's zone ({r.get('zone')})",
        f"reminder: on, the first reminder planned is {head}, wanted {expect}")
    # **The whole plan against `reminder.py`'s own**: each of the horizon's study days whose fire time is
    # still ahead. A count of one a day held only while today's had not passed, and failed a right plan
    # of six at 01:08, when the hour chosen was 04:00 (E2E Mac, 2026-10-05).
    days = [(d["id"], d["fireAt"]) for d in expect["days"]]
    say(r.get("horizon") == expect["horizon"] and [(p.get("id"), p.get("fireAt")) for p in planned] == days
        and all(p.get("count") == seeded for p in planned),
        f"reminder: one reminder for each of the {r.get('horizon')} study days whose time is ahead ({len(days)}), "
        f"each counting the {seeded} seeded cards",
        f"reminder: planned {[(p.get('id'), p.get('fireAt'), p.get('count')) for p in planned]} over a horizon of "
        f"{r.get('horizon')}, wanted {days} over {expect['horizon']}, each counting {seeded}")
    if granted:
        held = {p.get("id"): p.get("fireAt") for p in pending}
        say(held == {p.get("id"): p.get("fireAt") for p in planned},
            "reminder: what is pending in the notification center is the plan, identifier and fire date",
            f"reminder: pending {held} is not the plan {[(p.get('id'), p.get('fireAt')) for p in planned]}")
        say(first.get("state") == "added",
            f"reminder: the log records {expect['id']} as added",
            f"reminder: the log holds {first} for {expect['id']}")
    else:
        notrun("reminder: the pending request and its fire date",
               f"notifications are not allowed for XiaolaiDict on this Mac (grant: {grant}); a person turns "
               "the reminder on once in Settings › General and clicks Allow")
        say(pending == [],
            "reminder: without the grant nothing is pending",
            f"reminder: requests are pending without the grant: {pending}")
        say(not [e for e in log.values() if e.get("state") in ("intent", "added")],
            "reminder: without the grant the log records no add",
            f"reminder: the log records adds without the grant: {list(log.values())}")
else:
    say(r.get("enabled") is False and planned == [],
        "reminder: turned off, the settings plan nothing",
        f"reminder: turned off, the settings still plan {planned}")
    say(pending == [],
        "reminder: turned off, nothing of this app's is pending",
        f"reminder: turned off, requests are still pending: {pending}")
    if granted:
        say(first.get("state") == "withdrawn" and first.get("reason") == "disabled",
            f"reminder: the log records {expect['id']} withdrawn, because reminders were turned off",
            f"reminder: the log holds {first} for {expect['id']} after turning off")
    else:
        notrun("reminder: turning off removes the pending request",
               f"nothing could be pending without the grant ({grant}), so there was nothing to remove")
print("DONE")
PYREMINDER
)
        consume_verdicts reminder "$verdicts"
    done
fi
}
reminder_stage
# **What only a person at this Mac can do**, said rather than skipped in silence (review module plan
# §10: "Only the second Mac can verify").
echo "NOT RUN  reminder: the first Allow prompt — only a person can answer a system prompt, and nothing in this stage raises one"
echo "NOT RUN  reminder: a banner click bringing the Library forward on Review as a regular app — needs a delivered banner and a real click"
echo "NOT RUN  reminder: Later with the app quit — needs a delivered banner, a person choosing Later, and the app not running"
echo "NOT RUN  reminder: how macOS shows a .passive banner — needs a delivered banner and a person watching (reminders are sent .active)"
echo "NOT RUN  reminder: a fire time crossed while asleep — needs this Mac asleep across a fire time"
# **Said, not skipped**: with the reader's own reminders pending, the phases that would replace and remove
# them did not run (#28). Not a product failure — this Mac cannot run them without costing the reader.
if [ "$reminder_run" = off ]; then
    reminder_reader_count=$(reminder_pending "$reminder_evidence/reader.json")
    reminder_why="the reader's own $reminder_reader_count reminder(s) are pending on this Mac; turning reminders on and off here would replace them, and no request can be put back at its own instant from outside the app"
    echo "NOT RUN  reminder: the on phase (the plan, what is pending, the log) — $reminder_why"
    echo "NOT RUN  reminder: the disabled phase (turning off withdraws and removes) — $reminder_why"
fi
if restore_reminder_fixture; then
    pass "reminder: the reader's ledger and settings are back, and nothing this stage added is pending"
else
    flunk "reminder: the reader's ledger or settings could not be put back; the run stops so no stage writes over it"
    exit 1
fi
fi

if want scenes; then
# 11. The windows that are now SwiftUI scenes, driven the way a reader drives them.
#
#    With a real click, not `AXPress`: pressing a menu through Accessibility opens it *without
#    activating the app*, so a window opened from it never becomes key and never sees a key press.
#    A working control looks broken that way, and a broken one would look working.

# **The settings window is the size of the pane it is showing, and moves between the sizes.**
#
# Measured from inside the bundle, because a resize only happens in a running app and a window that
# snaps ends at exactly the same height as one that animates. What separates them is whether the
# window was ever seen part-way, which is what `stepsInBiggestChange` counts.
# 90 s: opening, the dictionary probe, and seven pane changes of at most about 4 s each.
settings_report() { run_report --settings-report 90; }
report=$(settings_report) || true
if [ -z "$report" ]; then
    flunk "settings: --settings-report printed nothing ($(head -c 160 $reports/settings-report.err 2>/dev/null))"
else
    # **One pass over the report**, where each assertion used to start Python again to read one
    # field. Emits a PASS or FAIL line per claim and DONE last: a validator that died part-way
    # must not read as having found nothing wrong, so no DONE is itself a failure.
    verdicts=$(python3 - "$report" 2>&1 <<'PYCHECK' || true
import json, sys
# Every pane the reader has, by name: SettingsPaneNamesTests holds every set spelled this way to SettingsPane.allCases.
names = {"Setup", "General", "Reading", "Lookup", "Dictionary", "Language Model", "About"}
r = json.loads(sys.argv[1])
def say(ok, good, bad): print(("PASS\t" + good) if ok else ("FAIL\t" + bad))
if not r.get("appeared"):
    say(False, "", f"settings: the window never came up ({r.get('problem', '?')})")
else:
    panes = r["panes"]
    # **Every pane walked, the Language Model pane among them** (ADR-0053): each measurement below is over the panes
    # the report visited, and a pane it skipped would be a pane none of them is about.
    walked = {p["pane"] for p in panes}
    say(walked == names,
        f"settings: every pane was walked, Language Model among them ({len(walked)})",
        f"settings: the panes walked are not the panes the reader has — missing {sorted(names - walked)}, "
        f"unknown {sorted(walked - names)}")
    say(r["oneWidth"] and r["width"] == r["expectedWidth"],
        f"settings: every pane is drawn at the panes' width ({r['width']:g} pt)",
        f"settings: the window is {r['width']:g} pt wide against the panes' {r['expectedWidth']:g} (one width: {r['oneWidth']})")
    # Each pane's window is that pane plus the same title bar and tabs. A window fitted to the
    # wrong thing still has five different heights, which is why that check alone is not this.
    c = r["chromes"]
    say(bool(c) and max(c) - min(c) <= 1,
        f"settings: every pane's window is exactly its content, plus {int(c[0]) if c else '?'} pt of title bar and tabs",
        f"settings: the windows are not their panes plus one chrome: {c} across {[p['pane'] for p in panes]}")
    # **And nothing is left over under the pane.** One constant chrome is also what a window 88 pt
    # too tall for every pane reports: the title bar and tabs were counted into what each pane
    # wanted, every short pane ended in a band of empty window, and the check above passed at 176.
    # `slacks` is the room AppKit gives the content less the pane, so 0 is a fit, more is the
    # band, and less is a pane that scrolls — which is right only where the screen stopped it.
    slacks = r.get("slacks")
    held = r.get("heldByScreen") or []
    say(bool(slacks) and max(slacks) <= 1
        and all(s >= -1 or (i < len(held) and held[i]) for i, s in enumerate(slacks)),
        "settings: the gap under each pane is the same as the margin above it (no empty window)",
        f"settings: a pane does not fill its window, or overflows it — slack {slacks} across {[p['pane'] for p in panes]} (held by the screen: {held})")
    # The window is the size of its pane: two panes at one height would mean a fixed frame is
    # still deciding — the state this stage was written for, 420 x 320 for all five.
    say(r["distinctHeights"] >= 3,
        f"settings: the window fits each pane ({r['shortest']:g}–{r['tallest']:g} pt over {r['distinctHeights']} heights)",
        f"settings: only {r['distinctHeights']} distinct heights across {len(panes)} panes — the window is not sizing to its content")
    # And moves between them. Zero steps is a jump, however large the change.
    say(r["stepsInBiggestChange"] >= 3,
        f"settings: the {r['biggestChange']:g} pt change to {r['biggestChangePane']} took {r['stepsInBiggestChange']} steps",
        f"settings: the {r['biggestChange']:g} pt change to {r['biggestChangePane']} was a jump ({r['stepsInBiggestChange']} steps)")
    # **And one way.** Steps count positions and cannot see a window that went down, back up and
    # down again — the shudder a reader saw while every check above passed.
    say(r["reversals"] == 0 and r["worstOvershoot"] < 1,
        "settings: every pane change moves the bottom edge one way, without overshoot",
        f"settings: the window shuddered — {r['reversals']} reversal(s), {r['worstOvershoot']:g} pt past its target "
        f"({[(p['pane'], p['path']) for p in panes if p['reversals'] or p['overshoot']]})")
    # The Dictionary pane was the reader's, not its loading placeholder: the service answered
    # before anything was measured.
    say(r["dictionariesKnown"], "settings: the dictionary service answered before the panes were measured",
        "settings: the Dictionary pane was measured while it still said it was looking for the dictionaries")
    # **A recording does not outlive the pane it is on.** Checked in the running app because two
    # fixes for it passed their unit tests and did nothing here: a hidden pane's views are kept
    # alive and not re-evaluated, so the field never learned it had been left.
    say(r["recordingListensOnItsOwnPane"] and r["recordingEndsWithItsPane"],
        "settings: a shortcut recording ends when the reader leaves its pane",
        f"settings: a shortcut recording outlives its pane (listening on it: {r['recordingListensOnItsOwnPane']}, "
        f"ended with it: {r['recordingEndsWithItsPane']})")
    # An endpoint read while the window was still moving is a height nothing settled at.
    say(r["openedAtRest"] and r["settledEveryPane"],
        "settings: the window came to rest after opening and after every pane change",
        f"settings: the window did not come to rest (opened: {r['openedAtRest']}, "
        f"panes: {[p['pane'] for p in panes if not p['settled']]})")
    # The pane decides the height, so the reader cannot drag it: an edge that could be pulled
    # would be a second answer to how tall the pane is.
    say(not r["resizable"], "settings: the window's height is the pane's, not a drag handle",
        "settings: the window can be resized by hand")
    # The top edge stays put: a settings window grows downward from its title bar. Two points of
    # tolerance, because a half-point frame lands on either side of a pixel.
    drift = round(r["topEdgeDrift"])
    say(drift <= 2, f"settings: the title bar stays where it is ({drift} pt)",
        f"settings: the window walked {drift} pt up or down the screen while resizing")
print("DONE")
PYCHECK
)
    consume_verdicts settings "$verdicts"
fi

# **The shortcut is a control in Settings, and it takes the keyboard.**
#
# It used to be a window of its own, which activated XiaolaiDict to open and left XiaolaiDict active with nothing
# on screen when it closed — which is how the settings window came to appear by itself. What has to
# hold now is that the control on the Lookup pane is reachable and live: a field that drew the
# right combination and never saw a key press would look exactly like a working one.
# The field is armed by clicking the combination it shows, which the menu-bar icon names too — read
# **before** Settings opens, and now read without opening anything. Dumping the menu in between
# opened and dismissed XiaolaiDict's menu, which handed focus back to the app behind it (Ghostty,
# in a full run), so the click meant to arm the field only brought an inactive window forward.
# `--describe` touches nothing: it reads the icon's tooltip through Accessibility, which is where
# the registered combination is named now that Look Up Selection has left the menu. Empty is the
# answer for no shortcut registered, which the two reads below are both allowed to be.
current=$({ "$helpers/menu-click" com.xiaolaidict --describe 2>/dev/null || true; } \
    | sed -n 's/.*press \(.*\) to look up.*/\1/p')
sleep 0.5
if ! "$helpers/menu-click" com.xiaolaidict "Settings…" >/dev/null 2>&1; then
    flunk "shortcut: could not reach Settings… in the menu"
else
    # **Waited for, not slept for.** A click lands on whatever is in front, and the first click on
    # an inactive window only activates it — so a settings window that is still coming forward
    # swallows the click that should have armed the field. Measured: after the report instance
    # quit, Ghostty was frontmost two seconds after Settings was chosen, and the field never armed.
    front=""
    for _ in $(seq 1 30); do
        front=$("$helpers/panel" com.xiaolaidict | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p')
        [ "$front" = com.xiaolaidict ] && break
        sleep 0.2
    done
    # **And the tab is clicked until it takes, not once.** `click-element` refuses a control whose
    # window is still moving — the settings window resizes itself to each pane — and it refuses one
    # that something is covering. Measured 2026-09-23: a notification banner from
    # `UserNotificationCenter` sat over the Lookup tab and the refusal read as "the pane is not
    # there". A banner goes by itself in about five seconds, so the wait is twenty; an alert that
    # stays is a machine that needs a person, and the failure now says which it was.
    clicked=no
    why=""
    for _ in $(seq 1 100); do
        [ "$front" = com.xiaolaidict ] || break
        if why=$("$helpers/click-element" com.xiaolaidict Lookup 2>&1); then clicked=yes; break; fi
        sleep 0.2
    done
    if [ "$front" != com.xiaolaidict ]; then
        flunk "shortcut: Settings never came forward — $front is in front"
    elif [ "$clicked" != yes ]; then
        # **What the helper said, not just that it said no.** Thrown away, this read as "the pane is
        # not there" for a click that was refused for some other reason entirely.
        flunk "shortcut: could not click the Lookup pane — $why"
    else
        # By identifier: the field is labelled "Lookup shortcut" for VoiceOver, so the
        # combination it draws is its value and no longer a title a click can be aimed at.
        if [ -z "$current" ] || ! "$helpers/click-element" com.xiaolaidict lookup-shortcut-field >/dev/null 2>&1; then
            flunk "shortcut: nothing on the Lookup pane showing '$current' to arm"
        else
            # Two separate claims, read separately, so a failure says which half broke: the click
            # armed the field, and the armed field hears the keyboard.
            sleep 1
            armed=$("$helpers/panel" com.xiaolaidict)
            # "Recording" is the armed field's accessibility value; its drawn title is not exposed.
            if ! printf '%s' "$armed" | grep -q "Recording"; then
                flunk "shortcut: clicking '$current' did not arm the field (saw: $(printf '%s' "$armed" | head -c 200))"
            else
                pass "shortcut: clicking the combination arms the field"
                # A bare key is refused with a hint rather than accepted — a shortcut with no
                # modifier would fire while the reader was typing. The hint appearing is the proof
                # the field has the keyboard at all.
                # **Waited for, not slept for**, and the wait printed. A fixed second and one read failed this once
                # in three full runs on the E2E Mac (2026-10-08) and passed alone twice: the line is set by the
                # field's key monitor, drawn by SwiftUI and only then in the Accessibility tree, and how long that
                # takes is load. Bounded, so a key that never arrives still fails — saying what the field showed.
                "$helpers/keys" 40
                refused=""
                coached=""
                for tenth in $(seq 1 50); do
                    coached=$("$helpers/panel" com.xiaolaidict || true)
                    if printf '%s' "$coached" | grep -q "needs"; then refused=$tenth; break; fi
                    sleep 0.1
                done
                if [ -n "$refused" ]; then
                    pass "shortcut: the armed field takes the keyboard, and refuses a key with no modifier ($((refused / 10)).$((refused % 10))s)"
                else
                    flunk "shortcut: the field was armed and showed no refusal of a bare key within 5 s (front: $(printf '%s' "$coached" | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p'); still recording: $(printf '%s' "$coached" | grep -q "Recording" && echo yes || echo no))"
                fi
                # **Escape disarms it — read passively, before anything else moves focus.** Opening
                # the menu to check the shortcut would itself end the recording (the window resigns
                # key), so a broken Escape would be covered for by the check that followed it.
                "$helpers/keys" 53
                sleep 0.5
                if "$helpers/panel" com.xiaolaidict | grep -q "Recording"; then
                    flunk "shortcut: Escape did not disarm the field"
                else
                    pass "shortcut: Escape disarms the field"
                fi
            fi
            # **Leaving the pane ends the recording — checked in the bundle, not by clicking.**
            # The rule matters: a recording's key monitor listens to the whole app, so one that
            # outlives its pane takes a combination pressed on another pane as the reader's new
            # shortcut. Driving it from here meant clicking a tab while the field was armed, and
            # that click was measured not to land often enough to trust — the pane stayed where it
            # was, and the check then failed the app for its own miss. `--settings-report` arms the
            # recorder and changes the pane inside the running app instead, which is where two
            # earlier fixes for this passed their unit tests and did nothing.
        fi
    fi
    # Closed by the title it has — the settings window is titled by its pane, not "XiaolaiDict Settings",
    # which is what an earlier line here asked for and, being `|| true`, silently never closed.
    pane=$("$helpers/panel" com.xiaolaidict | python3 -c '
import json, sys
# Every pane name, and it must stay that way: SettingsPaneNamesTests compares this literal
# against SettingsPane.allCases, because a set that quietly falls behind finds no window and the
# close below then closes whatever Lookup happens to be. It was already stale once: Setup was
# added and this was not. Keep every apostrophe out of this block: it is passed to python3 as a
# single-quoted argument, and one apostrophe ends that argument. bash -n accepted the broken
# version anyway, by luck of what re-balanced after it; the remote script is where it was caught.
names = {"Setup", "General", "Reading", "Lookup", "Dictionary", "Language Model", "About"}
print(next((t for w in json.load(sys.stdin)["windows"] for t in w["texts"][:1] if t in names), ""))')
    if ! why=$("$helpers/close-window" "${pane:-Lookup}" 2>&1); then
        flunk "shortcut: could not close the settings window afterwards ($why)"
    fi
    sleep 1
    # **However that went, the reader's shortcut must be registered again, and be theirs.** The
    # icon is the witness: its tooltip names the combination XiaolaiDict answers to, and says that
    # none is registered when the registrar holds no hot key — which is what arming the field makes
    # true on purpose.
    # Arming the field stands the hot key down on purpose, and a path that forgets to put it back
    # leaves the reader's shortcut quietly dead until XiaolaiDict is relaunched.
    after=$({ "$helpers/menu-click" com.xiaolaidict --describe 2>/dev/null || true; } \
        | sed -n 's/.*press \(.*\) to look up.*/\1/p')
    if [ -z "$after" ]; then
        flunk "shortcut: after the field was used, no shortcut is registered"
    elif [ "$after" != "$current" ]; then
        flunk "shortcut: the reader's shortcut was not put back — $after where it was $current"
    else
        pass "shortcut: registered, and back to $current, after the field was used"
    fi
fi

# The drawer and the settings window, each opened the way a reader opens it, and read through
# Accessibility — which is what a screen reader uses, and what a SwiftUI `UtilityWindow` is
# invisible to.
#
# **And whether each comes forward**, which is the half that was never asked. Reading a window
# through Accessibility says it exists, not that the reader can see it: measured, choosing Settings
# from the menu left the window on screen at 900×450 with the terminal still frontmost, so nothing
# appeared to happen — and it surfaced later when the shortcut recorder activated XiaolaiDict, which read
# as Settings opening by itself. The two surfaces want opposite answers, so they are asked
# separately: Settings is a window the reader chose and must come forward; the drawer must never
# take the reader out of what they were reading.
for surface in "Reading History" "Settings…"; do
    # **A known app in front first**, so "did not take focus" is checked against something: the
    # drawer passed merely for XiaolaiDict not being frontmost afterwards, whatever had been before —
    # which a Settings window left open earlier could turn into a pass or a failure on its own.
    # By LaunchServices, which brings a running app forward without an Apple event — see `ensure_fixture_open`.
    open -a Finder >/dev/null 2>&1 || true
    sleep 1
    before_front=$("$helpers/panel" com.xiaolaidict | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p')
    # **What the compositor already drew for this app**, so the window this menu item opens can
    # be told from one that was open before it was touched.
    before_drawn=$("$helpers/on-screen" com.xiaolaidict | python3 -c \
        'import json,sys; print(json.dumps(sorted(map(str, json.load(sys.stdin)["windows"]))))')
    # **Each surface is opened the way a reader opens it**, which is no longer one gesture for
    # both: the reading history is a left click on the icon, and the menu a right click, which is
    # the whole point of the split. Driving the history through the menu is what this loop used to
    # do, and it failed the app for an item that was deliberately removed — the click that opens
    # the menu already opens the history.
    if [ "$surface" = "Reading History" ]; then
        opened_by="--left-click"
        how="a left click on the icon"
    else
        opened_by="$surface"
        how="the menu"
    fi
    if ! "$helpers/menu-click" com.xiaolaidict "$opened_by" >/dev/null 2>&1; then
        flunk "scenes: could not reach $surface through $how"
        continue
    fi
    sleep 2
    # **A window that was not there before, and that the compositor draws** — not "the app has
    # some window", and deliberately not a title match either. Accessibility calls the Settings
    # window after its pane, so matching "Settings" found nothing while the window was on screen
    # in front of the reader: a title is what a surface is called today, and an assertion that
    # rests on one stops matching the day it is renamed while going on looking like a defect.
    seen=$("$helpers/on-screen" com.xiaolaidict)
    if [ -z "$(printf '%s' "$seen" | python3 -c \
            'import json,sys; s=set(json.loads(sys.argv[1])); print("\n".join(w for w in sorted(map(str, json.load(sys.stdin)["windows"])) if w not in s))' \
            "$before_drawn")" ]; then
        flunk "scenes: $surface opened no window the compositor draws (before $before_drawn, after $(printf '%s' "$seen" | head -c 300))"
    else
        pass "scenes: $surface is open and drawn by the compositor"
    fi
    front=$(printf '%s' "$seen" | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p')
    case "$surface" in
        "Settings…")
            if [ "$front" = com.xiaolaidict ]; then
                pass "scenes: Settings comes forward when the reader asks for it"
            else
                flunk "scenes: Settings opened behind $front — the reader sees nothing happen"
            fi ;;
        *)
            if [ "$before_front" != com.apple.finder ]; then
                flunk "scenes: could not put Finder in front to test $surface against ($before_front was)"
            elif [ "$front" != "$before_front" ]; then
                flunk "scenes: $surface took the reader out of $before_front ($front is in front now)"
            else
                pass "scenes: $surface leaves $before_front in front"
            fi ;;
    esac
    "$helpers/keys" 53 2>/dev/null || true
    sleep 1
done
fi

if want panel; then
# 13. **What the lookup panel's window is, and what clicking it costs the reader.**
#
#     The panel is the one surface the reader clicks into while they are mid-sentence somewhere else,
#     and nothing measured what that click does. The drawer's report asserts `activatedTheApp` for the
#     *drawer* — a surface nobody clicks into — and the panel had no equivalent, so three claims rested
#     on the gap: that `becomesKeyOnlyIfNeeded` is applied at all (it is guarded by
#     `window as? NSPanel`, and a SwiftUI `Window` scene may not be one), that text on the card could
#     ever be selected (selection needs a key window), and that a footer menu is usable (the
#     click-away monitor closes the panel on any mouse-down outside its frame, and a menu is another
#     window).
#
#     **Part gate, part probe, and the two are kept apart.** What is already an invariant is asserted;
#     what nobody has decided yet is printed as a NOTE and decides a design question instead of this
#     stage's colour. A probe that failed on a discovery would be a stage that fails for telling us
#     something.
# 90 s: a cold process pays for the XPC service starting before the first lookup answers.
report=$(run_report --panel-report 90) || true
if [ -z "$report" ]; then
    flunk "panel: --panel-report printed nothing ($(head -c 160 $reports/panel-report.err 2>/dev/null))"
else
    verdicts=$(python3 - "$report" 2>&1 <<'PYCHECK' || true
import json, sys
r = json.loads(sys.argv[1])
def say(ok, good, bad): print(("PASS\t" + good) if ok else ("FAIL\t" + bad))
def note(text): print("NOTE\t" + text)

if not r.get("appeared"):
    say(False, "", f"panel: the panel was never drawn ({r.get('problem', '?')})")
else:
    w, before, after, menu = r["window"], r["beforeClick"], r["afterClick"], r["menu"]

    # --- the invariants, asserted ------------------------------------------------------------
    # "No panel may activate XiaolaiDict": showing it must leave the reader where they were.
    say(not before["showingTookTheFront"],
        f"panel: showing it left {before['frontmostBefore']} in front",
        f"panel: showing it took the front from {before['frontmostBefore']} to {before['frontmostNow']}")
    # The measurement's own positive control. A click that was never posted measures nothing about
    # clicking, and must not read as a click that changed nothing.
    say(after["clickPosted"],
        "panel: a click was posted inside the panel",
        "panel: no click could be posted — is Accessibility granted to this bundle?")
    # The click-away monitor hit-tests the panel's own frame, so a click inside it belongs to the
    # card. This is the half of that rule a test can reach.
    say(after["survivedTheClick"],
        "panel: a click inside the panel did not dismiss it",
        "panel: a click inside the panel dismissed it — the click-away hit test is not holding")
    # Without this the menu reading is vacuous: a click that missed the item and a click the
    # monitors swallowed look identical, and they are opposite findings.
    if menu.get("measured") and menu.get("clickPosted") and menu.get("menuTracked"):
        say(menu["itemWasChosen"],
            "panel: the menu click reached the menu item",
            "panel: the menu click never reached the item, so the survival reading below means nothing")
    else:
        say(False, "", "panel: the menu could not be tracked "
            f"({menu.get('problem', 'measured=' + str(menu.get('measured'))
                 + ', menuTracked=' + str(menu.get('menuTracked'))
                 + ', clickPosted=' + str(menu.get('clickPosted'))
                 + ', clickedAt=' + str(menu.get('clickedAt'))
                 + ', menuFrame=' + str(menu.get('menuFrame')))})")

    # **The window is the height of the card.** It was the opening default for every card — 240,
    # with the whole footer below a fold the panel gives no sign of having. Three assertions,
    # because each alone passes on a defect: settled (a height read while it is still growing is
    # not the height the reader gets), within the ceiling (growing must stop where scrolling
    # starts), and taller than the opening default for a card that wants more (which is the fit
    # actually having happened rather than the default happening to be right).
    say(w["windowSettled"],
        f"panel: the window came to rest at {w['windowHeight']:g} pt",
        f"panel: the window was still resizing after {w['windowHeight']:g} pt — the height below "
        f"means nothing ({w.get('windowMovement', 'no movement recorded')})")
    say(w["windowHeight"] <= w["heightCeiling"],
        f"panel: the window is within the cap ({w['windowHeight']:g} of {w['heightCeiling']:g} pt)",
        f"panel: the window is {w['windowHeight']:g} pt against a ceiling of {w['heightCeiling']:g} — it grew past what its content is clipped to")
    say(w["windowHeight"] != w["openingHeight"],
        f"panel: the window is the card's height, not the opening default ({w['openingHeight']:g} pt)",
        f"panel: the window is exactly the opening default ({w['openingHeight']:g} pt) — it is not being fitted to the card")

    # --- the discoveries, reported ----------------------------------------------------------
    note(f"panel: the window is a {w['class']}; isPanel={w['isPanel']}, "
         f"becomesKeyOnlyIfNeeded={w['becomesKeyOnlyIfNeeded']}, "
         f"nonactivatingPanel={w['isNonactivatingPanel']}, styleMask={w['styleMask']}, level={w['level']}")
    # WI-6 turns on this one number: a window that cannot become key cannot hold a text selection,
    # and no modifier changes that.
    # What the height was computed from. A window of the wrong height and a window asked for the
    # wrong height look identical from outside, and they have different causes — the card's surface
    # is drawn on its scroll view's frame, so a window asked for more than the content wants shows
    # the difference as empty card under the last control.
    note(f"panel: the fit saw wanted={w['fitWanted']:g} given={w['fitGiven']:g} "
         f"→ dead space {max(0.0, w['fitWanted'] - w['fitGiven']):g} pt")
    note(f"panel: resizableByHand={w['resizableByHand']} — the window has no edge to drag, which is "
         "why no size a reader chose is remembered")
    note(f"panel: canBecomeKey={w['canBecomeKey']} — text selection on the card is "
         + ("possible" if w["canBecomeKey"] else "IMPOSSIBLE on this surface"))
    # The cost of every control on the card, stated plainly whichever way it went.
    note(f"panel: after a click — appIsActive={after['appIsActive']}, isKeyWindow={after['isKeyWindow']}, "
         f"frontmost={after['frontmost']}, tookTheFront={after['tookTheFront']}")
    # **Whether this run could have seen a change.** With the app already active before the
    # click, the reading below is not evidence either way, and a note that does not say so
    # reads as a measurement.
    if not after.get("couldObserveActivation", True):
        note("panel: XiaolaiDict was already active before the click, so this run cannot say "
             "whether clicking activates it")
    if after["tookTheFront"]:
        note("panel: clicking a control takes the front, so typing goes to XiaolaiDict afterwards — "
             "every footer action costs the reader their focus")
    else:
        note("panel: clicking a control left the front where it was, so typing still goes to the reader's app")
    # WI-2 turns on this one. A menu is another window, and the monitors may or may not see it.
    if menu.get("measured"):
        note(f"panel: tracked an {menu['menuKind']} outside the panel's frame — "
             f"panelSurvivedTheMenuClick={menu['panelSurvivedTheMenuClick']}")
        if not menu["panelSurvivedTheMenuClick"]:
            note("panel: a menu click dismissed the panel — a footer menu needs the click-away "
                 "predicate to know its own popup before WI-2 can use one")
print("DONE")
PYCHECK
)
    consume_verdicts panel "$verdicts"
fi
fi

if want provider; then
# 14. **The language model is a service the reader already has** (ADR-0053): an OpenAI-compatible endpoint, or the
#     reader's own `claude` or `codex`. What a source may be sent is decided by where it runs, failing closed
#     (`RemoteDisclosure`): on this Mac, the sentence and the dictionary's sense text; remote — a CLI wherever it is
#     installed, an endpoint off this Mac — **the reader's sentence only**. And an endpoint off this Mac must be HTTPS,
#     or plain HTTP to the local network, which the app allows and warns of; plain HTTP to a public host, or an address
#     carrying a name or a password, is sent nothing (`EndpointAddress`).
#
#     So one stub on this Mac's loopback (`Tools/e2e/provider-stub.py`) is reached three ways, and logs what each was
#     asked by the model name each arm asks for: as an endpoint on `127.0.0.1` (**on this Mac**); as an endpoint under a
#     URL the app must refuse (see `provider_refused_url`), which must reach it with nothing; and as the reader's own
#     `claude`, the stub installed in its place (**remote**) — the remote tier's one transport that needs neither TLS,
#     for which this stub has no certificate the app would trust, nor a LAN address. A real lookup through the shortcut
#     and the panel's own Explain button are what send it; the stub's log is what is judged. **Not a second stub on a
#     LAN address**, which the plan offered: a connection from the app to one raises macOS's Local Network prompt on a
#     screen nobody is at, and the preflight would name that alert in every run after it.
#
#     And each subscription CLI, through the app's own preflight (`--provider-status`), never reading a credential:
#     asked where it is installed and signed in, and **SKIPPED by name** otherwise — never a pass. The stub arms are
#     what this stage passes on; a skipped CLI cannot make it green.
#
# **Every setting this stage writes is read first and put back however the run ends**, and put back at its end too, so
# the model stage after it measures the reader's own source, not this stage's.
if provider_choice_original=$(defaults read com.xiaolaidict LanguageModelProvider 2>/dev/null); then
    provider_choice_had=yes
else
    provider_choice_had=no; provider_choice_original=""
fi
if provider_url_original=$(defaults read com.xiaolaidict ProviderEndpointURL 2>/dev/null); then
    provider_url_had=yes
else
    provider_url_had=no; provider_url_original=""
fi
if provider_model_original=$(defaults read com.xiaolaidict ProviderEndpointModel 2>/dev/null); then
    provider_model_had=yes
else
    provider_model_had=no; provider_model_original=""
fi
if provider_switch_original=$(defaults read com.xiaolaidict SubscriptionCLIsEnabled 2>/dev/null); then
    provider_switch_had=yes
else
    provider_switch_had=no; provider_switch_original=""
fi
if provider_claude_path_original=$(defaults read com.xiaolaidict ClaudeCLIPath 2>/dev/null); then
    provider_claude_path_had=yes
else
    provider_claude_path_had=no; provider_claude_path_original=""
fi
if provider_claude_model_original=$(defaults read com.xiaolaidict ClaudeCLIModel 2>/dev/null); then
    provider_claude_model_had=yes
else
    provider_claude_model_had=no; provider_claude_model_original=""
fi
# The stand-in `claude`'s two settings, put back on their own as well: the reader's real `claude` is checked after
# them, and must be found where the reader's own settings say.
restore_provider_claude() {
    restore_default ClaudeCLIPath "$provider_claude_path_had" "$provider_claude_path_original"
    restore_default ClaudeCLIModel "$provider_claude_model_had" "$provider_claude_model_original"
}
restore_provider_settings() {
    restore_default LanguageModelProvider "$provider_choice_had" "$provider_choice_original"
    restore_default ProviderEndpointURL "$provider_url_had" "$provider_url_original"
    restore_default ProviderEndpointModel "$provider_model_had" "$provider_model_original"
    restore_default SubscriptionCLIsEnabled "$provider_switch_had" "$provider_switch_original" -bool
    restore_provider_claude
}
at_exit restore_provider_settings

# The stub, ended however the run ends. Its log is kept beside the bundle for a person to read after a failure: it
# holds the fixture sentence and the sense list the on-this-Mac arm was sent — this Mac's own dictionary's words, which
# never leave it — and whether a key came, never a key.
provider_evidence="$e2e_home/provider-evidence"
provider_stub_log="$provider_evidence/stub.jsonl"
provider_stub_pid=""
stop_provider_stub() {
    [ -n "$provider_stub_pid" ] || return 0
    end_process "$provider_stub_pid" || { echo "the provider stub (pid $provider_stub_pid) would not end" >&2; return 1; }
    provider_stub_pid=""
}
at_exit stop_provider_stub

# The model name each arm asks for: how the stub's log tells the arms apart, since all reach one stub.
provider_on_model="xiaolaidict-e2e-onthismac"
provider_remote_model="xiaolaidict-e2e-remote"
provider_refused_model="xiaolaidict-e2e-refused"
# The fixture's sentence, as the lookup sends it: what each arm must have been sent.
provider_sentence="The meeting ended after we stopped meeting at noon."

# provider_cli_check <claudeCLI|codexCLI>: the reader's CLI, chosen behind the switch it sits behind, asked through the
# app's own preflight. **Never** a credential file, a CLI's own Keychain item or a token: the preflight starts the
# reader's unmodified CLI, which signs itself in or says nobody did (ADR-0053).
provider_cli_check() {
    local choice=$1 report verdicts
    if ! defaults write com.xiaolaidict LanguageModelProvider -string "$choice" \
       || ! defaults write com.xiaolaidict SubscriptionCLIsEnabled -bool YES; then
        flunk "provider: the $choice settings could not be written, so its preflight was not asked"
        return 0
    fi
    # 150 s: a cold Codex first turn is ~9 s and a cold claude ~5 s (plan §1); the bound is for a CLI that hangs.
    report=$(run_report --provider-status 150) || true
    if [ -z "$report" ]; then
        flunk "provider: --provider-status printed nothing for $choice ($(head -c 160 "$reports/provider-status.err" 2>/dev/null))"
        return 0
    fi
    verdicts=$(provider_status_verdicts provider "$choice" remote cli "$report")
    consume_verdicts provider "$verdicts"
}

# provider_endpoint <tier> <url> <model>: the endpoint chosen as a reader chooses it — the three settings the pane
# writes — and the app's preflight asked about it.
provider_endpoint() {
    local tier=$1 url=$2 model=$3 report
    if ! defaults write com.xiaolaidict LanguageModelProvider -string openAICompatible \
       || ! defaults write com.xiaolaidict ProviderEndpointURL -string "$url" \
       || ! defaults write com.xiaolaidict ProviderEndpointModel -string "$model"; then
        flunk "provider: the $tier endpoint settings could not be written"
        return 0
    fi
    report=$(run_report --provider-status 60) || true
    if [ -z "$report" ]; then
        flunk "provider: --provider-status printed nothing for the $tier endpoint ($(head -c 160 "$reports/provider-status.err" 2>/dev/null))"
        return 0
    fi
    consume_verdicts provider "$(provider_status_verdicts provider endpoint "$tier" "${4:-ready}" "$report")"
}

# provider_claude_arm: the stub installed as the reader's `claude` — a launcher in the evidence directory, chosen
# through the settings the pane writes, behind the switch it sits behind — and the app's preflight asked about it. The
# app starts it exactly as it starts the reader's; its turns land in the stub's log under `provider_remote_model`.
provider_claude_arm() {
    local launcher="$provider_evidence/claude" python report
    python=$(command -v python3) || { flunk "provider: no python3 to run the stand-in claude"; return 0; }
    # Arguments as data, quoted for the shell that runs the launcher: never a path spliced in as code.
    if ! printf '#!/bin/sh\nexec %q %q claude %q "$@"\n' "$python" "$helpers/provider-stub.py" "$provider_stub_log" \
            > "$launcher" || ! chmod 700 "$launcher"; then
        flunk "provider: the stand-in claude could not be written"
        return 0
    fi
    if ! defaults write com.xiaolaidict LanguageModelProvider -string claudeCLI \
       || ! defaults write com.xiaolaidict SubscriptionCLIsEnabled -bool YES \
       || ! defaults write com.xiaolaidict ClaudeCLIPath -string "$launcher" \
       || ! defaults write com.xiaolaidict ClaudeCLIModel -string "$provider_remote_model"; then
        flunk "provider: the stand-in claude's settings could not be written"
        return 0
    fi
    report=$(run_report --provider-status 60) || true
    if [ -z "$report" ]; then
        flunk "provider: --provider-status printed nothing for the stand-in claude ($(head -c 160 "$reports/provider-status.err" 2>/dev/null))"
        return 0
    fi
    consume_verdicts provider "$(provider_status_verdicts provider claudeCLI remote ready "$report")"
}

# provider_reading <tier>: one lookup of the fixture word through the shortcut, with the panel's Explain This Sentence
# pressed while it shows, and the explanation it draws read off the panel — labelled for where <tier> runs.
provider_reading() {
    local tier=$1 baseline why waited lookup_id grant shown explained=""
    if ! ensure_fixture_open; then
        flunk "provider: the TextEdit fixture would not come to the front, so the $tier arm drove no lookup"
        return 0
    fi
    baseline=$(newest_row_id)
    assert_default_shortcut || true
    if ! why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1); then
        flunk "provider: could not select the fixture word for the $tier arm ($why)"
        return 0
    fi
    "$helpers/keys" 2 control option
    waited=$(row_after "$baseline" meeting com.apple.TextEdit)
    lookup_id=$(row_id_of "$baseline" meeting com.apple.TextEdit)
    if [ "${lookup_id:-0}" -eq 0 ]; then
        grant=$(missing_grant)
        flunk "provider: the $tier arm lookup wrote no ledger row in ${waited}s${grant:+ — the app says \"$grant\"}"
        "$helpers/keys" 53 2>/dev/null || true
        return 0
    fi
    # **The sense is written on a later await than the row**, and on this Mac it is the endpoint's own answer.
    sense_after "$lookup_id"
    if [ -n "$sense_chosen$sense_abstained" ]; then
        pass "provider: the $tier arm lookup reached the ledger with its sense (chosen_by=${sense_chosen:-none}, abstention=${sense_abstained:-none}, ${sense_waited}s after its row)"
    else
        flunk "provider: the $tier arm lookup recorded neither a sense nor an abstention in ${sense_waited}s"
    fi
    # Pressed through Accessibility: the panel never activates the app, so the frontmost rule a real click needs can
    # never be met for it (`click-element --press`).
    if ! why=$("$helpers/click-element" com.xiaolaidict --press "Explain This Sentence" 2>&1); then
        flunk "provider: Explain This Sentence could not be pressed on the $tier arm panel ($why)"
        "$helpers/keys" 53 2>/dev/null || true
        return 0
    fi
    for _ in $(seq 1 60); do
        shown=$("$helpers/panel" com.xiaolaidict 2>/dev/null | lookup_windows 2>/dev/null || true)
        printf '%s' "$shown" | grep -q xiaolaidict-e2e-stub-explanation && { explained=yes; break; }
        sleep 0.5
    done
    if [ "$explained" != yes ]; then
        flunk "provider: the $tier arm panel never drew the endpoint explanation in 30 s ($(printf '%s' "$shown" | head -c 300))"
    else
        consume_verdicts provider "$(python3 - "$tier" "$shown" 2>&1 <<'PYPANE' || true
import json, sys
tier = sys.argv[1]
def say(ok, good, bad): print(("PASS\t" + good) if ok else ("FAIL\t" + bad))
texts = [t for w in json.loads(sys.argv[2], strict=False).get("windows", []) for t in w.get("texts", [])]
labels = [t for t in texts if "Explained by" in t]
# The label is read from where the question was sent (ModelProvenance): a remote answer labelled as made on this Mac
# would tell a reader their sentence stayed here while it was being sent away.
if tier == "remote":
    say(any("Explained by a remote model" in t for t in texts),
        "provider: the remote arm explanation is drawn and labelled as made by a remote model",
        f"provider: the remote arm explanation is not labelled remote: {labels}")
else:
    say(any("Explained by a model on this Mac" in t for t in texts),
        "provider: the on-this-Mac arm explanation is drawn and labelled as made on this Mac",
        f"provider: the on-this-Mac arm explanation is not labelled as made on this Mac: {labels}")
print("DONE")
PYPANE
)"
    fi
    "$helpers/keys" 53 2>/dev/null || true
    sleep 1
}

# **The URL the app must refuse**: `http://e2e@localhost:<port>/v1` — the stub's own loopback, with a userinfo. An
# address carrying a name or a password is not one the app sends to (`EndpointAddress`): it would keep a credential in
# the defaults, and `http://localhost@evil.com` connects to `evil.com`, so the text alone cannot be trusted. If the app
# sent it anything it would arrive here, on loopback: nothing leaves this Mac, and no Local Network prompt is raised.
provider_refused_url() { printf 'http://e2e@localhost:%s/v1' "$1"; }

provider_stage() {
    local port="" verdicts
    mkdir -p "$provider_evidence" && chmod 700 "$provider_evidence"
    rm -f "$provider_evidence/stub.port"
    python3 "$helpers/provider-stub.py" serve "$provider_stub_log" "$provider_evidence/stub.port" \
        2>"$provider_evidence/stub.err" &
    provider_stub_pid=$!
    for _ in $(seq 1 50); do
        port=$(cat "$provider_evidence/stub.port" 2>/dev/null || true)
        [ -n "$port" ] && break
        sleep 0.2
    done
    if [ -z "$port" ]; then
        flunk "provider: the stub endpoint never started listening ($(head -c 200 "$provider_evidence/stub.err" 2>/dev/null)), so no arm ran"
        return 0
    fi
    echo "NOTE  provider: the stub endpoint listens on 127.0.0.1:$port; its log is $provider_stub_log"

    # On this Mac: the endpoint may see the sentence and the dictionary's sense text, and is asked the sense on every
    # lookup, as the bundled model always was.
    provider_endpoint onThisMac "http://127.0.0.1:$port/v1" "$provider_on_model"
    relaunch_or_end_stage || return 0
    provider_reading onThisMac

    # Refused: an address the app must not send to is refused by its own preflight, and the stub hears nothing of it.
    provider_endpoint remote "$(provider_refused_url "$port")" "$provider_refused_model" endpointUnusable

    # Remote: the reader's sentence only, through the stand-in `claude`.
    provider_claude_arm
    relaunch_or_end_stage || return 0
    provider_reading remote

    # **What the stub was sent, judged against the arms**: on this Mac it was asked the sense and told it; the remote
    # arm was sent none of those senses, no sense question and no Dictionary sense line — while still the sentence; and
    # the refused address was sent nothing at all.
    verdicts=$(python3 "$helpers/provider-stub.py" judge "$provider_stub_log" onThisMac "$provider_on_model" "$provider_sentence" 2>&1 || true)
    consume_verdicts provider "$verdicts"
    verdicts=$(python3 "$helpers/provider-stub.py" judge "$provider_stub_log" remote "$provider_remote_model" "$provider_sentence" "$provider_on_model" 2>&1 || true)
    consume_verdicts provider "$verdicts"
    verdicts=$(python3 "$helpers/provider-stub.py" judge "$provider_stub_log" refused "$provider_refused_model" "$provider_sentence" 2>&1 || true)
    consume_verdicts provider "$verdicts"

    # The CLIs, with the app stopped: a running app that wrote any default of its own — a window frame — would
    # reconcile its source and warm the CLI chosen here, spending a question of the reader's subscription unasked.
    if ! stop_app; then
        flunk "provider: XiaolaiDict would not quit, so the CLI checks did not run"
        return 0
    fi
    # **The switch is the reader's consent to this app starting their CLI**, and without it a CLI chosen is no source.
    if defaults write com.xiaolaidict LanguageModelProvider -string claudeCLI \
       && { defaults delete com.xiaolaidict SubscriptionCLIsEnabled 2>/dev/null || true; }; then
        report=$(run_report --provider-status 60) || true
        if [ -z "$report" ]; then
            flunk "provider: --provider-status printed nothing with the CLI switch off ($(head -c 160 "$reports/provider-status.err" 2>/dev/null))"
        else
            consume_verdicts provider "$(provider_status_verdicts provider local onThisMac none "$report")"
        fi
    else
        flunk "provider: claudeCLI could not be chosen, so the CLI switch was not checked"
    fi
    # The reader's own `claude` is found where their settings say, not the stand-in.
    restore_provider_claude
    provider_cli_check claudeCLI
    provider_cli_check codexCLI

    restore_provider_settings
    stop_provider_stub || flunk "provider: the stub endpoint would not end"
    launch_or_end_stage || return 0
}
provider_stage
fi

if want model; then
# 15. The local model, end to end, in the signed bundle: downloaded from ModelScope by the app's own
#     downloader, a sense answer and a translation through the model service, the service's
#     footprint, and the service ending itself when idle — which is how the model unloads.
#
#     Run directly rather than through LaunchServices: nothing here captures the screen, so TCC's
#     refusal of processes launched over SSH does not apply, and a report that runs for minutes
#     while a download finishes is simpler to bound from here.
#
#     **Hidden, not removed** (ADR-0053): no reader is asked to download it now, and its code, service and tests all
#     still run — this stage among them. Its instruments (`--model-report`, `--sense-report`) reach the model service
#     directly and download through the app's own downloader whatever the setup board shows; the reader's own lookup
#     below reaches it through the router, which asks it only where it is the source. So the stage selects it, as a
#     reader who has it selects it, and asserts the selection took before anything is measured.
model_service="$app/Contents/XPCServices/XiaolaiDictModelService.xpc/Contents/MacOS/XiaolaiDictModelService"
# launchd starts the service with no arguments, so its idle interval comes from the app's defaults.
# Shortened for the run so the unload is seen inside it, and put back however the run ends.
if idle_original=$(defaults read com.xiaolaidict ModelIdleSeconds 2>/dev/null); then idle_had=yes; else idle_had=no; idle_original=""; fi
restore_idle() { restore_default ModelIdleSeconds "$idle_had" "$idle_original" -int; }
at_exit restore_idle
defaults write com.xiaolaidict ModelIdleSeconds -int 20
if model_source_original=$(defaults read com.xiaolaidict LanguageModelProvider 2>/dev/null); then
    model_source_had=yes
else
    model_source_had=no; model_source_original=""
fi
restore_model_source() {
    restore_default LanguageModelProvider "$model_source_had" "$model_source_original"
}
at_exit restore_model_source
defaults write com.xiaolaidict LanguageModelProvider -string localModel
# Read back through the app's own report, run directly: no window, no network, and for the local model no question.
source_report=$("$exe" --provider-status 2>/dev/null || true)
consume_verdicts model "$(provider_status_verdicts model local onThisMac none "$source_report")"
# A service already running read the old interval; this run's must start fresh. Asserted, not
# assumed: everything after this would otherwise be measuring the old process — its old interval,
# and a model it had already loaded.
find_pids "$model_service"
[ "${#PIDS[@]}" -eq 0 ] || kill -TERM "${PIDS[@]}" 2>/dev/null || true
for _ in $(seq 1 50); do is_running "$model_service" || break; sleep 0.1; done
if is_running "$model_service"; then
    flunk "model: a model service from before the stage would not quit; every check below would measure it"
else

status=$("$exe" --model-status 2>/dev/null || true)
if printf '%s' "$status" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("gpu") else 1)' 2>/dev/null; then
    pass "model: the signed service evaluates an MLX op on the GPU ($(printf '%s' "$status" | sed -n 's/.*"gpu":"\([^"]*\)".*/\1/p'))"
else
    flunk "model: the service cannot run MLX — $status"
fi

# **A service that dies takes nothing with it** — the reason MLX lives in a process of its own, and
# a claim nothing had ever exercised. Killed outright while the reader's app is running: the app
# must still be there afterwards, and the next question must be answered by a service launchd
# brought back. Killing it *after* a question, so there is a loaded model to lose.
# The service has to be *the app's*, and the app only has one once it has asked the model
# something — launchd ends a service when its client exits, so the short-lived `--model-status`
# process above took its own service with it. A lookup through the reader's own path is what gives
# the app a live service: the panel prewarms the model beside the dictionary lookup.
find_pids "$exe"; app_pid_before=${PIDS[0]:-}
ledger_before=$(newest_row_id)
open -a TextEdit "$helpers/notes.txt"; sleep 1.5
lookup_driven=no
# **Read while the panel is up.** The app's refusal is on the panel, and Escape below takes it
# away — asking afterwards, as the first version did, always found nothing and the stage went on
# reporting "the lookup wrote no ledger row" over a permission it could have named. Evidence is
# gathered when it exists, not when it is wanted.
grant_notice=""
if why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1); then
    assert_default_shortcut || true
    "$helpers/keys" 2 control option
    for _ in $(seq 1 100); do ! is_running "$model_service" || break; sleep 0.1; done
    grant_notice=$(missing_grant)
    "$helpers/keys" 53 2>/dev/null || true
    lookup_driven=yes
else
    # **A flunk, not a note.** `lookup_driven=no` skipped the block below, which holds the stage's
    # *only* assertion about the production path — everything else here asks an in-bundle instrument.
    # So a selection that could not be made turned the one check that exercises the panel, the sense
    # resolver and the ledger into no check at all, and the stage went on to pass on instrument
    # output alone. The failure is the selection; saying so is what stops the silence.
    flunk "model: could not drive a lookup, so the production path was not exercised at all ($why)"
fi

# **What the reader's own lookup left behind.** Everything else in this stage asks an in-bundle
# instrument — `--model-report`, `--sense-report` — and an instrument answering says nothing about
# the panel the reader actually uses: the whole production path could be disconnected and every
# check here would still pass. This is the one assertion in the stage that reads the ledger a real
# keypress wrote. The sense is written on a later await than the panel, so the row is waited for.
if [ "$lookup_driven" = yes ]; then
    waited=$(row_after "$ledger_before" meeting com.apple.TextEdit)
    lookup_id=$(row_id_of "$ledger_before" meeting com.apple.TextEdit)
    if [ "${lookup_id:-0}" -eq 0 ]; then
        if [ -n "$grant_notice" ]; then
            flunk "model: no lookup could be driven — the app says \"$grant_notice\". This machine has not granted it; nothing here can, and the production path was not exercised"
        else
            flunk "model: the lookup wrote no ledger row (waited ${waited}s)"
        fi
    else
        sense_after "$lookup_id"
        chosen=$sense_chosen; abstained=$sense_abstained
        # Any of `model`, `reader` or `onlySense` is the sense path having answered; which one it
        # was is reported rather than demanded, because an entry with a single sense is keyed
        # without asking a model at all and that is not a failure.
        if [ -n "$chosen" ]; then
            pass "model: the reader's own lookup reached the ledger with a sense (chosen_by=$chosen, row ${waited}s, sense ${sense_waited}s later)"
        elif [ -n "$abstained" ]; then
            # A sense nothing could key is a legitimate answer — but it has to be recorded as one.
            # What must never happen is a lookup that recorded neither.
            pass "model: the reader's own lookup recorded why no sense was marked ($abstained, ${sense_waited}s after its row)"
        else
            flunk "model: the lookup recorded neither a chosen sense nor an abstention in ${sense_waited}s — the selector's answer never reached the ledger"
        fi
    fi
fi
find_pids "$model_service"
if [ -z "$app_pid_before" ]; then
    flunk "model: the app is not running, so crash isolation cannot be observed"
elif [ "${#PIDS[@]}" -eq 0 ]; then
    if [ -n "$grant_notice" ]; then
        flunk "model: no model service to kill — the app prewarms the model on a lookup, and no lookup could be driven (\"$grant_notice\")"
    else
        flunk "model: no model service to kill, so crash isolation was not exercised"
    fi
else
    # **The kill has to have worked, and the service has to have gone.** Both were discarded:
    # a `kill` that failed and a wait that simply expired left the service running, and the
    # "app survived" check below then passed over a crash that never happened.
    if ! kill -9 "${PIDS[@]}" 2>/dev/null; then
        flunk "model: the model service could not be killed, so crash isolation was not exercised"
    fi
    killed=no
    for _ in $(seq 1 50); do
        if ! is_running "$model_service"; then killed=yes; break; fi
        sleep 0.1
    done
    [ "$killed" = yes ] || flunk "model: the model service was still running 5 s after being killed"
    sleep 1
    find_pids "$exe"; app_pid_after=${PIDS[0]:-}
    if [ "$app_pid_after" = "$app_pid_before" ]; then
        pass "model: the app survived its model service being killed (pid $app_pid_before)"
    else
        flunk "model: the app went with its model service — was $app_pid_before, now ${app_pid_after:-gone}"
    fi
    # **launchd restarting the service, which is not the same claim as the app recovering.** This asks
    # a *separate* `--model-status` process: its client is brand new, so it says a new connection can
    # be made and nothing at all about the surviving app's existing one. The check below is the one
    # about the app.
    again=$("$exe" --model-status 2>/dev/null || true)
    if printf '%s' "$again" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("reachable") and d.get("gpu") else 1)' 2>/dev/null; then
        pass "model: launchd gave a fresh process a working service after the kill"
    else
        flunk "model: nothing came back after the service was killed — $again"
    fi
    # **And the surviving app's own path still answers.** The two assertions above are about the app's
    # *pid* and about a *new* process; between them they left the thing a reader would notice — whether
    # the app that lived through the crash can still look a word up — untested. Driven the way a reader
    # drives it, and read out of the ledger the lookup wrote.
    ledger_after_kill=$(newest_row_id)
    if why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1); then
        assert_default_shortcut || true
    "$helpers/keys" 2 control option
        waited_after=$(row_after "$ledger_after_kill" meeting com.apple.TextEdit)
        "$helpers/keys" 53 2>/dev/null || true
        recovered_id=$(row_id_of "$ledger_after_kill" meeting com.apple.TextEdit)
        if [ "${recovered_id:-0}" -ne 0 ]; then
            pass "model: the app that survived the crash looked a word up again (${waited_after}s)"
            # **And the model rung answered, which the row alone does not say.** A dictionary
            # lookup reaches the ledger whether the model resolved the sense, abstained, or was
            # never asked — so "the client reconnected" was a claim about a path this row does
            # not touch. The sense the lookup recorded is what says which.
            sense_after "$recovered_id"
            after_chosen=$sense_chosen; after_abstained=$sense_abstained
            if [ -n "$after_chosen" ] || [ -n "$after_abstained" ]; then
                pass "model: and its sense path answered after the crash (chosen_by=${after_chosen:-none}, abstention=${after_abstained:-none}, ${sense_waited}s)"
            else
                flunk "model: the lookup landed but its sense path recorded neither a choice nor an abstention in ${sense_waited}s — the client did not come back"
            fi
        else
            flunk "model: the app survived but its own lookups no longer reach the ledger (waited ${waited_after}s)"
        fi
    else
        flunk "model: could not drive a lookup after the kill, so the app's own recovery was not exercised ($why)"
    fi
    # **And the service that lookup started is ended again, because `--model-report` below refuses to
    # measure a service it did not start.** Measured: without this, the report returned
    # `endedTheRunningService: false` and six assertions failed on an empty report. The stage used to
    # get this for free — the kill above was the last thing to touch the service — and adding a
    # recovery check quietly removed that, which is the ordering dependency worth naming rather than
    # rediscovering.
    find_pids "$model_service"
    [ "${#PIDS[@]}" -eq 0 ] || kill -9 "${PIDS[@]}" 2>/dev/null || true
    for _ in $(seq 1 50); do is_running "$model_service" || break; sleep 0.1; done
fi

# Bounded at 40 minutes: a first run downloads 3 GB, measured at ~10 MB/s from this network.
report_out=$reports/model-report.json
run_bounded --model-report "$report_out" 2400 model-report || true
report=$(cat "$report_out" 2>/dev/null || true)
echo "model report: $report"
if why=$(expect "$report" installed=True sense=2 loaded=True prewarmed=True relaunched=True 2>&1); then
    pass "model: downloaded or found whole, a sense answer (2 of 3, the cargo space) and a translation through the service"
else
    flunk "model: $why"
fi
# **Answered in the language asked for, not merely answered.** Any non-empty string passed, so
# untranslated English would have read as a translation into Chinese — which is exactly the failure
# `TranslationCheck` exists for, and the reason the pane would have shown a fallback for it.
if why=$(printf '%s' "$report" | python3 -c '
import json, sys, unicodedata
d = json.load(sys.stdin)
text = d.get("translation")
if not text: sys.exit("no translation came back")
han = sum(1 for ch in text if "CJK" in unicodedata.name(ch, ""))
if han < 4: sys.exit(f"the translation into zh-Hans holds {han} Chinese characters: {text[:60]}")
# **And the sense it was told is the sense it rendered.** Telling the model which sense the reader
# met is what sharpened 船舱 to 货舱 in every measured run; a translation that reads "hold" as the
# verb carries neither, and it is Chinese either way, so the language check above cannot see it.
told = d.get("translationToldSense")
if "舱" not in text:
    sys.exit(f"the translation does not render the cargo sense it was told ({told}): {text[:60]}")
' 2>&1); then
    pass "model: the sentence came back translated: $(printf '%s' "$report" | sed -n 's/.*"translation":"\([^"]*\)".*/\1/p')"
else
    flunk "model: $why"
fi
# The sentence pane asks this model too — and it is the only engine a reader without Apple
# Intelligence has for it, so "the model answers" has to include this one.
# Explained, not echoed: the sentence handed back is not an explanation of it, and it is long
# enough to be two or three sentences rather than a word.
if why=$(printf '%s' "$report" | python3 -c '
import json, sys
d = json.load(sys.stdin)
text = (d.get("explanation") or "").strip()
if not text: sys.exit("no explanation came back")
if len(text) < 40: sys.exit(f"the explanation is {len(text)} characters: {text}")
sentence = d.get("sentence")
if not sentence: sys.exit("the report carries no sentence, so the echo check cannot fail")
if text.lower() in sentence.lower(): sys.exit("the explanation is the sentence handed back")
if "hold" not in text.lower(): sys.exit(f"the explanation never names the word: {text[:60]}")
' 2>&1); then
    pass "model: the sentence came back explained ($(printf '%s' "$report" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["explanation"]))' 2>/dev/null) characters)"
else
    flunk "model: $why ($(printf '%s' "$report" | sed -n 's/.*"explanationFailure":"\([^"]*\)".*/\1/p'))"
fi
footprint=$(printf '%s' "$report" | sed -n 's/.*"footprintMB":\([0-9]*\).*/\1/p')
peak=$(printf '%s' "$report" | sed -n 's/.*"peakMB":\([0-9]*\).*/\1/p')
# **Both bounds, and the upper one is derived rather than typed.** A service holding a model and
# answering is gigabytes, so a few megabytes means nothing was loaded; a lower bound alone would pass
# a service that has leaked its way to twelve.
#
# The upper bound was a hard-coded 4,500 MB described as "the measured peak (3,585 MB for 4B) with
# room for the process itself" — two mistakes in one sentence. 3,585 MB **is** the measured *process*
# peak, so the extra 915 MB was slack counted twice: at 4B's admission minimum of 4,609 MB available
# it left 109 MB of the promised gigabyte. And the number only ever described 4B, while
# `--model-report` measures the largest eligible size installed — so a legitimate 9B run, peaking at
# 6,633 MB, would have been failed against a 4B budget.
#
# The peak now comes from the report, for the size the report actually measured, and the bound is the
# peak itself: this reading is taken *after* the answer, and a settled footprint is by definition at
# or below the highest the process reached. That makes it stricter than 4,500 for 4B and correct for
# 9B, with nothing to keep in sync.
if [ -z "$footprint" ]; then
    flunk "model: the service reported no footprint"
elif [ -z "$peak" ]; then
    flunk "model: the report named no peak for its size, so the footprint cannot be judged"
elif [ "$footprint" -le 1000 ]; then
    flunk "model: the service's footprint is ${footprint} MB — the model is not loaded"
elif [ "$footprint" -gt "$peak" ]; then
    flunk "model: the service holds ${footprint} MB, above the ${peak} MB peak this size is admitted on — admission is deciding from the wrong number"
else
    pass "model: the service holds the model — ${footprint} MB, within its ${peak} MB peak"
fi

# The labelled set, every rung, in this bundle — the measurement that decides the ladder's order.
# Bounded: its Apple rung calls the on-device model directly, and a stalled one would hang the whole
# run with no result and no cleanup.
sense_out="$reports/sense-report.json"
run_bounded --sense-report "$sense_out" 600 sense-report || true
senses=$(cat "$sense_out" 2>/dev/null || true)
echo "sense report: $senses"
# **The judgement is a file, not a heredoc.** It decides whether this build's ladder ships, and the
# report it reads takes ten minutes to produce — so it is exercised against reports built by hand
# (`Tools/tests/test_ladder_gate.py`, run by `make test-tools`) rather than only by the run it gates.
if verdict=$(python3 "$helpers/ladder-gate.py" "$sense_out" 2>&1); then
    pass "model: the local model ladder runs it first, and the labelled set backs it ($verdict)"
else
    flunk "model: the labelled set does not back the local model ladder — $verdict"
fi

# **Which model answered.** The report used to name none, so a 2B run and a 4B run produced
# indistinguishable output — and the order this project records was read off one of them. That
# order belongs to Qwen3.5-4B, the size the catalogue calls standard; a run scored with any other
# size measured a different ladder and must not be read as confirming it.
measured_size=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("modelSize") or "none")' "$sense_out" 2>/dev/null || echo none)
if [ "$measured_size" = standard ]; then
    pass "model: the labelled set was scored with Qwen3.5-4B, the size the recorded order belongs to"
else
    flunk "model: the recorded order belongs to Qwen3.5-4B (standard); this run scored the set with ${measured_size}"
fi

# Unloading is the service ending **while its client is still running** — watched by the report
# from inside, because when a client exits launchd ends its service with it, and a watch from out
# here once passed in 0 s on exactly that. Between the interval and 15 s past it: sooner is the
# timer misfiring or the client-exit case again, later is the timer not firing.
unloaded_after=$(printf '%s' "$report" | sed -n 's/.*"unloadedAfterSeconds":\([0-9.]*\).*/\1/p')
if [ -n "$unloaded_after" ] && python3 -c 'import sys; t = float(sys.argv[1]); sys.exit(0 if 19 <= t <= 35 else 1)' "$unloaded_after"; then
    pass "model: the service ended itself ${unloaded_after} s after the last request (idle interval 20 s), and the next question brought a fresh one"
else
    flunk "model: the idle unload — ${unloaded_after:-not seen} s against an interval of 20 s ($(printf '%s' "$report" | sed -n 's/.*"unload":"\([^"]*\)".*/\1/p'))"
fi
fi  # the old service had gone
fi
finished=true
echo
# **Assertions, not stages.** `failures` is incremented by `flunk`, which is per *check* — so a
# single stage failing three of its checks reported "3 stage(s) failed" while the board beside it
# listed one. Two numbers for the same run, disagreeing, with the wrong one first. The stage count
# comes from the records, which is where the board reads it too.
stages_failed=$(echo $failed_stages | wc -w | tr -d ' ')
[ "$failures" -eq 0 ] && echo "all stages passed" || {
    echo "$failures assertion(s) failed, in $stages_failed stage(s): $(echo $failed_stages)"
    exit 1
}
SH
set +e
ssh_e2e bash -s -- "$REMOTE_DIR" "$STAGES" <"$remote_scripts/run.sh" | tee "$RUN_LOG" | grep -v "^RESULT	"
pipeline=("${PIPESTATUS[@]}")
set -e
remote_status=${pipeline[0]}
# **A transport failure is not a set of results.** ssh dying part-way leaves a log holding every
# PASS the run had reached, and `record` below filed those as this build's verdict — a stage
# marked green whose final failure never arrived. Recorded only when the remote run said what it
# thought; see the `record` guard below.
# **`tee`'s status is the log's, and the log is the evidence.** Only ssh's was read, so a `tee` that
# could not write — a full disk, a read-only `.build` — left a truncated or empty `RUN_LOG` while the
# run exited 0, and `record` below then filed whatever stages happened to have reached the file. The
# evidence being incomplete is a failure of the run, not a detail of it.
#
# `grep`'s status is deliberately not checked: `grep -v` exits 1 when it selects no lines, which is
# what a run consisting only of `RESULT` lines would legitimately produce.
if [ "${pipeline[1]}" -ne 0 ]; then
    echo "the run log could not be written ($RUN_LOG, tee exited ${pipeline[1]}), so nothing is recorded:" >&2
    echo "the stage results for this run are lost, whatever the stages themselves did" >&2
    exit 1
fi

# Recorded against the build it ran on. Without that a pass says only "it worked once", which is
# not a claim anyone can act on — and a green mark that outlives what it tested is worse than none.
# Filed and printed by `Tools/e2e-status.sh`, which `make e2e-status` also reads: the file, its
# format and the staleness rule have one implementation, and a second copy of the table here had
# already lost the timestamp column.
# **Recorded against the build that was tested, passed in rather than re-read.** `record` used to
# read `CFBundleVersion` off the local bundle at record time, so a `make` in another terminal during
# a ten-minute run credited the new build with the old build's results — a green mark against a
# bundle that was never on the test Mac.
# **A transport failure is not a set of results.** ssh dying part-way leaves a log holding every
# PASS the run had reached and none of the failures it had not, and filing that marks a stage
# green on a run that never finished. 255 is ssh's own "the connection went"; the remote script
# exits 0 or 1 and nothing else, so the two cannot be confused.
if [ "$remote_status" -ge 2 ]; then
    echo "the connection to $host failed mid-run (ssh exited $remote_status); nothing is recorded" >&2
    echo "whatever the log holds is a partial run, not this build's verdict" >&2
    exit "$remote_status"
fi
Tools/e2e-status.sh record "$remote_version" <"$RUN_LOG"
echo
Tools/e2e-status.sh show
exit "$remote_status"
