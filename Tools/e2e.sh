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
readonly APP=.build/XiaolaiDict.app
readonly REMOTE_DIR=XiaolaiDictE2E
fail() { echo "e2e: FAIL: $*" >&2; exit 1; }
stage() { echo; echo "== $*"; }

[ -d "$APP" ] || fail "$APP does not exist; run make first"
ssh_e2e() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" "$@"; }

# **The scripts sent to the E2E machine are parsed here, before anything is shipped.** They are
# quoted heredocs, so `bash -n` on this file skips straight over them and nothing reads them until
# the far machine does — after the bundle has been built and copied. An apostrophe inside a `sed`
# bracket expression closed its quote and ended a run that way, at stage 11 of 11, with nothing
# measured. Parsing costs milliseconds; not parsing cost the run.
heredocs=$(mktemp -d)
# Removed however this section ends — `fail` exits, and would leave the directory behind.
trap 'rm -rf "$heredocs"' EXIT
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
trap 'rm -rf "$remote_scripts"' EXIT
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
rm -rf .build/e2e && mkdir -p .build/e2e
for helper in select-text select-web keys panel claim-escape word-point window-frame menu-click screen-state close-window click-element on-screen; do
    swiftc -O "Tools/e2e/$helper.swift" -o ".build/e2e/$helper" || fail "could not build $helper"
done
cp Tools/e2e/notes.txt Tools/e2e/page.html Tools/e2e/ladder-gate.py .build/e2e/
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
trap 'rm -f "$RUN_LOG"; rm -rf "$remote_scripts"' EXIT
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
KNOWN_STAGES=(launch lookup crash accessibility selection shortcut deadline hover drawer recogniser setup scenes panel model)
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

newest_row_id() { sqlite3 -readonly "$ledger" "select coalesce(max(id), 0) from lookups" 2>/dev/null || echo 0; }
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
        flunk "model: $flag did not finish within $((budget / 60)) minutes"
        return 1
    fi
    local status=0
    wait "$pid" || status=$?
    if [ "$status" -ne 0 ]; then
        flunk "model: $flag exited $status"
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
end_instrument() {  # end_instrument <flag>: wait for this bundle's instrument to end, then insist
    local pattern="$exe $1"
    for _ in $(seq 1 40); do pgrep -f "$pattern" >/dev/null || return 0; sleep 0.25; done
    pkill -f "$pattern" 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -f "$pattern" >/dev/null || return 0; sleep 0.25; done
    pkill -9 -f "$pattern" 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -f "$pattern" >/dev/null || return 0; sleep 0.25; done
    # Said out loud: an instrument that survives its own killing can still capture the screen, and
    # whatever runs next would be measuring against it.
    echo "note: $1 would not die; what runs after this is running beside it"
    return 1
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
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null; then
        return 1
    fi
    cat "$out" 2>/dev/null || true
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

# Nearly every stage needs the app running, so having it running is *setup*. Stage 1 is what
# asserts that it starts and stays up, which is a different claim and stays a stage of its own.
# Without this, selecting a later stage failed for want of something an earlier one happened to do.
if ! is_running "$exe"; then
    open "$app"
    for _ in $(seq 1 100); do ! is_running "$exe" || break; sleep 0.1; done
fi

# **A locked screen voids every stage that looks at it or types into it — so it is checked, not
# assumed.** The test Mac locks itself when idle, whatever its screen-lock setting reports, and a
# lock does not stop XiaolaiDict's windows being drawn: the window list still has them, so every "is it
# on screen" check passes. It covers them. Measured on 2026-09-21: a capture of the drawer came
# back as the lock screen's aerial image and read as "the glass does not work", and keystrokes for
# the shortcut recorder went to the password field with `loginwindow` in front. A run against a
# locked screen is refused here, in one line, rather than reported as a list of XiaolaiDict's defects.
if ! lock_state=$("$helpers/screen-state" 2>&1); then
    echo "FAIL  setup: the screen is ${lock_state:-locked} — unlock the test Mac and run again; nothing below would be testing XiaolaiDict"
    exit 1
fi

# **And a system alert nobody answered voids every click the same way.** `click-element` refuses a
# control something is covering, which is right — a click posted through an alert goes to the
# alert — but the refusal then reads as the control not existing. Measured 2026-09-23: an
# unanswered "Allow …to find devices on local networks?" had been sitting at (734, 222) since
# 2026-09-20, over the settings window's tab strip, and two stages failed as though the app were at
# fault. Refused here, in one line, with what the alert says, because answering it is a decision
# for whoever owns the machine.
alert_windows=$("$helpers/on-screen" com.apple.UserNotificationCenter 2>/dev/null || true)
if printf '%s' "$alert_windows" | grep -q '"windows":\[{'; then
    alert_text=$("$helpers/panel" com.apple.UserNotificationCenter 2>/dev/null | head -c 300 || true)
    echo "FAIL  setup: a system alert is on the test Mac's screen and would swallow the clicks below — answer it and run again: $alert_text"
    exit 1
fi

# **And wait for the menu, which is not the same as waiting for the process.** Install quits the
# running copy, so every run starts cold; immediately after the pid appears the menu-bar item is
# not in the Accessibility tree yet — measured deterministically, 3 restarts out of 3. Waiting on
# the pid and then driving the menu made whichever menu-driven assertion ran first fail, and which
# one that was moved between runs. That reads like a flaky app; it was the harness using a surface
# it had never established was there.
menu_ready=""
for _ in $(seq 1 200); do
    if "$helpers/menu-click" com.xiaolaidict --ready >/dev/null 2>&1; then menu_ready=yes; break; fi
    sleep 0.1
done
if [ -z "$menu_ready" ]; then
    # Through `flunk`, so it is *recorded* and not only printed. Counted into `failures` alone, the
    # run ended non-zero while the table `make e2e-status` reads still showed every stage's previous
    # pass, with nothing in it to say this had happened.
    flunk "setup: the menu-bar item never appeared — every menu-driven stage below is void"
fi

if want launch; then
# 1. LaunchServices starts it, and it stays up.
open "$app"
for _ in $(seq 1 100); do ! is_running "$exe" || break; sleep 0.1; done
sleep 1
if is_running "$exe"; then pass "launch: running, and still running after 1 s"; else flunk "launch: not running"; fi
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
select_then_read "Safari: a past form NLTagger leaves alone is read from its grammar" com.apple.Safari \
    "$helpers/select-web" com.apple.Safari saw -- \
    text=saw lemma=see lemmaBasis=inferred
fi

if want shortcut; then
# 6. The reader's own path: a selection, the shortcut, the panel, the ledger, and Escape.
#    The shortcut is XiaolaiDict's default, Control-Option-D; a machine where it was changed fails here.
baseline=$(newest_row_id)
open -a TextEdit "$helpers/notes.txt"; sleep 1.5
if ! why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1); then
    flunk "shortcut: could not select ($why)"
else
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
    view=""
    for _ in $(seq 1 150); do
        view=$("$helpers/panel" com.xiaolaidict)
        printf '%s' "$view" | python3 -c '
import json, sys
failed = sys.argv[1].split("|")
panels = [w for w in json.load(sys.stdin)["windows"]
          if any("meeting" in t for t in w["texts"]) and not any(m in t for t in w["texts"] for m in failed)]
sys.exit(0 if panels else 1)
' "$card_failure_markers" && break
        sleep 0.1
    done
    view=$("$helpers/panel" com.xiaolaidict)
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
    closed=$("$helpers/panel" com.xiaolaidict)
    if [ "$held" = held ] && [ "$free" = free ] && printf '%s' "$closed" | grep -q '"windows":\[\]'; then
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
resume() { [ -z "$stopped" ] || kill -CONT $stopped 2>/dev/null || true; stopped=""; }
at_exit resume
if ! why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1); then
    flunk "waiting panel: could not select ($why)"
else
    find_pids "$service"
    if [ "${#PIDS[@]}" -eq 0 ]; then
        flunk "waiting panel: no dictionary service to suspend — the test did not happen"
    else
        stopped="${PIDS[*]}"
        kill -STOP "${PIDS[@]}"
        started=$EPOCHREALTIME
        "$helpers/keys" 2 control option
        shown="" ; waiting=""
        for _ in $(seq 1 200); do
            view=$("$helpers/panel" com.xiaolaidict)
            if printf '%s' "$view" | grep -q 'Looking up'; then
                shown=$EPOCHREALTIME; waiting=$view; break
            fi
            sleep 0.05
        done
        if [ -z "$shown" ]; then
            # `$waiting` is what was captured and never read: the last panel seen, which is the whole
            # evidence for why this failed — an empty window list reads very differently from a panel
            # that came up with the wrong words in it.
            flunk "waiting panel: never appeared while the service was suspended (last view: $(printf '%s' "${waiting:-$view}" | head -c 240))"
        else
            took=$(python3 -c "import sys; print(f'{float(sys.argv[2]) - float(sys.argv[1]):.2f}')" "$started" "$shown")
            if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)" "$took"; then
                pass "waiting panel: shown in ${took}s with the service hung, saying what it waits for"
            else
                flunk "waiting panel: took ${took}s, over the 1 s budget"
            fi
        fi
        # It fills in on its own once the deadline gives up: same panel, no second window.
        resume
        filled=""
        for _ in $(seq 1 100); do
            view=$("$helpers/panel" com.xiaolaidict)
            # The word's card, and no failure on it — "No entry for" carries the word too.
            # Not `"meeting"` as a whole JSON element: the card heads itself with the dictionary's
            # headword, so a primary that lemmatises answers "meeting" with a card headed "meet".
            # The reader's own sentence carries the surface form, and that is what is matched.
            if printf '%s' "$view" | grep -q 'meeting' && ! printf '%s' "$view" | grep -qE 'Looking up|No entry for|could not all be asked'; then
                filled=$view; break
            fi
            sleep 0.1
        done
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

hover_at() {  # hover_at <label> <bundle-id> <expected capture source>
    local label=$1 app_id=$2 want=$3
    local point reading summary
    if ! point=$("$helpers/word-point" "$app_id" 2>&1); then
        flunk "$label: could not find a word to point at ($point)"; return
    fi
    if ! reading=$("$exe" --read-point $point 2>&1); then
        flunk "$label: $reading (at $point)"; return
    fi
    if summary=$(check_hover "$reading" "$want" 2>&1); then
        pass "$label: $summary"
    else
        flunk "$label: $summary"
    fi
}

open -a TextEdit "$helpers/notes.txt"; sleep 2
hover_at "hover: TextEdit answers the text-range dialect" com.apple.TextEdit accessibilityTextRange
open -a Safari "$helpers/page.html"; sleep 3
hover_at "hover: Safari answers the text-marker dialect" com.apple.Safari accessibilityTextMarkers
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
# **The machine's glass setting is put back exactly as it was** — the value, or its absence — and
# however the script ends. It used to be deleted afterwards, which lost a reader's own choice on
# this machine, and a failure in between left the forced value behind.
# Whether the key was there at all is kept apart from its value: a preference set to an empty
# string is not an absent one, and restoring by "is the value empty" would delete it.
if original_glass=$(defaults read com.xiaolaidict DrawerGlass 2>/dev/null); then
    had_glass=yes
else
    had_glass=no
    original_glass=""
fi
restore_glass() { restore_default DrawerGlass "$had_glass" "$original_glass"; }
at_exit restore_glass
# The stripes image, kept beside the report under the glass it was taken in. Missing is a note, not
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
# Frosted first, set explicitly: a machine left on Clear would otherwise flip the comparison below.
defaults write com.xiaolaidict DrawerGlass frosted
drawer=$(history_report)
keep_stripes frosted
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
    # Earlier stages recorded lookups, so the drawer must have something to show. An empty drawer
    # here would mean the ledger read silently returned nothing.
    if why=$(expect "$drawer" problem=none 2>&1); then
        days=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["days"])' "$drawer")
        entries=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["entries"])' "$drawer")
        if [ "$entries" -gt 0 ]; then
            pass "drawer: shows $entries lookup(s) across $days day(s) from the ledger"
        else
            flunk "drawer: the ledger has rows from earlier stages but the drawer showed none"
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
    # **The glass setting reaches the screen.** Settings offers Frosted and Clear, and a setting
    # the drawer never reads would pass every unit test of the setting — the way the pause switch
    # did. So the same drawer is measured with each. The deciding number is the glass over black,
    # because a dark window behind the drawer is where the two differ and the case that made
    # frosted look broken: measured 133 for frosted and 71 for clear. The bar is a 20-point gap —
    # a third of that, far above the zero an unwired setting would give. The stripes' colour is
    # reported alongside, and both stripes images are kept beside the report's own.
    defaults write com.xiaolaidict DrawerGlass clear
    clear_report=$(history_report)
    keep_stripes clear
    # The machine's own setting is not the test's to keep.
    restore_glass
    # stderr as well: `sys.exit(message)` writes the reason there, and a failure read from stdout
    # alone reported "drawer: " with nothing after it.
    if verdict=$(python3 - "$drawer" "$clear_report" 2>&1 <<'PYCHECK'
import json, sys
frosted, clear = json.loads(sys.argv[1]), json.loads(sys.argv[2])
fg, cg = frosted.get("drawerGlass"), clear.get("drawerGlass")
fb, cb = frosted.get("glassOverBlack", -1), clear.get("glassOverBlack", -1)
fc, cc = frosted.get("stripesColour", -1), clear.get("stripesColour", -1)
summary = f"over black frosted {fb}, clear {cb}; stripes' colour frosted {fc:.0f}, clear {cc:.0f}"
if (fg, cg) != ("frosted", "clear"):
    sys.exit(f"the report ran with {fg} then {cg}, not frosted then clear ({summary})")
if fb < 0 or cb < 0:
    sys.exit(f"the glass over black did not measure ({summary})")
if fb - cb < 20:
    sys.exit(f"Clear is not darker than Frosted over a dark window — {summary}")
print(summary)
PYCHECK
    ); then
        pass "drawer: the Clear setting reaches the screen ($verdict)"
    else
        flunk "drawer: $verdict"
    fi
fi
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
    cat "$out" 2>/dev/null
}

open -a Ghostty; sleep 3
if ! frame=$("$helpers/window-frame" com.mitchellh.ghostty 2>&1); then
    flunk "recogniser: no Ghostty window to read ($frame)"
else
    read -r wx wy _ _ <<<"$frame"
    # A grid, because where a terminal's text sits depends on its prompt, its font and its padding.
    reading=""
    read_x=0
    read_y=0
    for dy in 98 113 83 128 68 143; do
        for dx in 50 160 280; do
            got=$(read_point $((wx + dx)) $((wy + dy)))
            if printf '%s' "$got" | grep -q opticalRecognition; then
                reading=$got
                read_x=$((wx + dx))
                read_y=$((wy + dy))
                break 2
            fi
        done
    done
    if [ -z "$reading" ]; then
        flunk "recogniser: no point in the Ghostty window came back through OCR; last error: $(head -c 120 "$reports/read-point.err" 2>/dev/null)"
    else
        if why=$(expect "$reading" captureSource=opticalRecognition bundleID=com.mitchellh.ghostty 2>&1); then
            word=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["text"])' "$reading")
            pass "recogniser: read '$word' from a terminal through OCR"
        else
            flunk "recogniser: $why"
        fi
        # **Timed on a second read of the same point**, which is what "warm" means. The first
        # capture after boot pays a system-wide ScreenCaptureKit warm-up — measured at 14.8 s once
        # and 24.8 s on 2026-09-23 — against ~0.5 s for every read after. This comment said
        # "asserted warm" while the code timed the very first read, so the stage was measuring how
        # long the machine had been up. A warm read that fails to come back is reported as that,
        # never silently replaced by the cold one.
        warm=$(read_point "$read_x" "$read_y")
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
restart_app() {  # restart_app: quit XiaolaiDict, start it again, wait for its menu-bar item
    local before pid fresh=""
    find_pids "$exe"
    before=" ${PIDS[*]+${PIDS[*]}} "
    [ "${#PIDS[@]}" -eq 0 ] || kill -TERM "${PIDS[@]}"
    for _ in $(seq 1 100); do is_running "$exe" || break; sleep 0.1; done
    if is_running "$exe"; then
        echo "restart_app: XiaolaiDict would not quit (pids$before), so nothing was restarted" >&2
        return 1
    fi
    open "$app"
    for _ in $(seq 1 100); do ! is_running "$exe" || break; sleep 0.1; done
    find_pids "$exe"
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do
        case $before in *" $pid "*) ;; *) fresh=$pid ;; esac
    done
    if [ -z "$fresh" ]; then
        echo "restart_app: no new XiaolaiDict process appeared after open (before:$before)" >&2
        return 1
    fi
    for _ in $(seq 1 100); do
        "$helpers/menu-click" com.xiaolaidict --ready >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    echo "restart_app: pid $fresh started but its menu-bar item never appeared" >&2
    return 1
}
board_on_screen() {  # board_on_screen: 0 drawn, 1 absent, 2 exists but not drawn
    local seen
    seen=$("$helpers/on-screen" com.xiaolaidict "Set Up")
    printf '%s' "$seen" | grep -q '"drawn":true' && return 0
    # Found by title but not drawn is neither "open" nor "absent", and must not read as either.
    printf '%s' "$seen" | grep -q '"matches":\[\]' || return 2
    return 1
}
settle_after_launch() {
    board_on_screen || return 0     # no board open by itself, so nothing was fetched early
    local _
    for _ in $(seq 1 50); do
        "$helpers/panel" com.xiaolaidict | grep -q "Asking which dictionaries are enabled" || break
        sleep 0.2
    done
    sleep 0.5
}
# Frontmost app, and whether the board is main/focused, in one line — what a failed "came forward"
# or "was remembered" check needs to say, since the two can fail independently.
board_state() {
    local s; s=$("$helpers/on-screen" com.xiaolaidict "Set Up")
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
unstash_models() {
    [ "$stashed" = yes ] || return 0
    rm -rf "$models"
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
if ! "$helpers/menu-click" com.xiaolaidict "Set Up…" >/dev/null 2>&1; then
    flunk "setup: could not reach Set Up… in the menu"
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
        pass "setup: choosing Set Up… brings XiaolaiDict forward ($((front_waited / 5)).$(( (front_waited % 5) * 2 ))s)"
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
        drawn=$("$helpers/on-screen" com.xiaolaidict "Set Up")
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
    for row in "Accessibility" "Screen Recording" "Study dictionary" "Lookup shortcut" "Translation and sense picking"; do
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
    while printf '%s' "$shown" | grep -q "Asking which dictionaries are enabled"; do
        [ "$dict_waited" -ge 100 ] && break
        sleep 0.2
        dict_waited=$((dict_waited + 1))
        shown=$("$helpers/panel" com.xiaolaidict)
    done
    # **Three outcomes, not two.** The row leaves "Asking…" both when the service answers and when
    # it fails, so a loop that only waited for that phrase to go away reported a broken service as
    # a successful one.
    if printf '%s' "$shown" | grep -q "Asking which dictionaries are enabled"; then
        flunk "setup: the dictionary row was still asking the service after $((dict_waited / 5))s"
    elif printf '%s' "$shown" | grep -q "did not answer"; then
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
if ! "$helpers/close-window" "Set Up XiaolaiDict" >/dev/null 2>&1; then
    flunk "setup: could not close the board, so reopening cannot be tested"
else
    pass "setup: the board closes"
fi
sleep 1
defaults write com.xiaolaidict SetupWindowShown -bool true
if ! "$helpers/menu-click" com.xiaolaidict "Set Up…" >/dev/null 2>&1; then
    flunk "setup: could not reopen the board after it had been shown once"
else
    sleep 1.5
    again=$("$helpers/panel" com.xiaolaidict)
    if printf '%s' "$again" | grep -q "Study dictionary"; then
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

"$helpers/close-window" "Set Up XiaolaiDict" >/dev/null 2>&1 || true
defaults delete com.xiaolaidict SetupWindowShown 2>/dev/null || true
# The store goes aside here, so this launch is a fresh reader's in both senses: no flag, and no
# model. Put back at the end of the stage, before anything that needs the weights. Idempotent: the
# first call above has usually already done it, and this one clears the root the restart recreated.
stash_models || true
if ! restart_app; then
    flunk "setup: XiaolaiDict did not come back after a restart, so the first-run open cannot be tested"
else
    opened=""
    for _ in $(seq 1 50); do board_on_screen && { opened=yes; break; }; sleep 0.2; done
    if [ "$opened" = yes ]; then
        pass "setup: a fresh install opens the board without being asked"
    else
        flunk "setup: nothing opened the board on a first launch"
    fi

    # Read from the board that just opened by itself, with no model in the store.
    shown=$("$helpers/panel" com.xiaolaidict)
    # **The model row, read through Accessibility, and the store asked separately.** What this can
    # see is the row's text and which controls exist — not whether a button is wired to anything,
    # which only clicking it would show, and which the `setup` stage's own click checks do below.
    # What must be true on a Mac where the model is not downloaded: it is still needed, the weaker
    # engine is named, both choices are offered. That **nothing has begun downloading** is asked of
    # the store rather than of the row, because a row that is simply slow to redraw would otherwise
    # read as proof.
    staging=~/Library/Application\ Support/XiaolaiDict/Models/.staging
    if [ -d "$staging" ] && [ -n "$(find "$staging" -name '*.partial' -mmin -5 2>/dev/null)" ]; then
        flunk "setup: something has been fetching model files in the last five minutes, unasked"
    else
        pass "setup: nothing had begun downloading a model"
    fi
    if printf '%s' "$shown" | grep -q "Translation and sense picking"; then
        model_row=$(printf '%s' "$shown" | tr ',' '\n' | grep -A14 "Translation and sense picking" || true)
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
        if printf '%s' "$shown" | grep -q "Qwen3.5.*translates your sentences and picks the sense you met, on this Mac. Nothing is sent anywhere."; then
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
                && { printf '%s' "$shown" | grep -q "Not now" || printf '%s' "$shown" | grep -q "still one click away"; }; then
                pass "setup: the model row reports a stopped download, offers to resume it, names what answers meanwhile, and can still be declined"
            else
                flunk "setup: a stopped download with no way to resume or decline it, or with nothing named as answering meanwhile — $(printf '%s' "$model_row" | head -c 300)"
            fi
        elif printf '%s' "$shown" | grep -q "misreads some" && printf '%s' "$shown" | grep -q "Download"; then
            # Both choices, unless the reader already chose **Not now** — which the row remembers,
            # and which takes its button away while leaving the download one click from here.
            if printf '%s' "$shown" | grep -q "Not now" || printf '%s' "$shown" | grep -q "Nothing is waiting on you"; then
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
        flunk "setup: the board has no model row, so none of its states were checked ($(printf '%s' "$shown" | head -c 200))"
    fi

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
    if ! reach=$("$helpers/menu-click" com.xiaolaidict "Set Up…" 2>&1); then
        flunk "setup: could not reach Set Up… after the restart ($reach)"
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
    if printf '%s' "$shown" | grep -q "Not now"; then
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
            if why=$("$helpers/click-element" com.xiaolaidict "Not now" 2>&1); then pressed=yes; break; fi
            sleep 0.2
        done
        if [ "$pressed" != yes ]; then
            flunk "setup: Not now could not be clicked — $why ($(board_state))"
        else
            declined_shown=""
            for _ in $(seq 1 25); do
                declined_shown=$("$helpers/panel" com.xiaolaidict)
                printf '%s' "$declined_shown" | grep -q "still one click away" && break
                sleep 0.2
            done
            if printf '%s' "$declined_shown" | grep -q "still one click away" \
                && printf '%s' "$declined_shown" | grep -q "Download"; then
                pass "setup: Not now is wired — the row stops waiting on the reader and keeps the download one click away"
            else
                flunk "setup: Not now changed nothing the reader can see — $(printf '%s' "$declined_shown" | tr ',' '\n' | grep -A8 'Translation and sense picking' | head -c 300)"
            fi
            restore_declined
        fi
    fi
fi

"$helpers/close-window" "Set Up XiaolaiDict" >/dev/null 2>&1 || true
if ! restart_app; then
    flunk "setup: XiaolaiDict did not come back after the second restart"
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

# Left as the reader found it. A board still on screen would be in front of whatever stage runs
# next, and the scenes stage measures which app is frontmost. The flag itself is put back by
# `restore_setup_shown`, registered before anything was launched.
"$helpers/close-window" "Set Up XiaolaiDict" >/dev/null 2>&1 || true
# And the model store is put back here rather than at exit, because the model stage runs after this
# one and would otherwise measure a Mac with no weights on it.
unstash_models || flunk "setup: the model store was not put back"
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
# 90 s: opening, the dictionary probe, and six pane changes of at most about 4 s each.
settings_report() { run_report --settings-report 90; }
report=$(settings_report)
if [ -z "$report" ]; then
    flunk "settings: --settings-report printed nothing ($(head -c 160 $reports/settings-report.err 2>/dev/null))"
else
    # **One pass over the report**, where each assertion used to start Python again to read one
    # field. Emits a PASS or FAIL line per claim and DONE last: a validator that died part-way
    # must not read as having found nothing wrong, so no DONE is itself a failure.
    verdicts=$(python3 - "$report" 2>&1 <<'PYCHECK' || true
import json, sys
r = json.loads(sys.argv[1])
def say(ok, good, bad): print(("PASS\t" + good) if ok else ("FAIL\t" + bad))
if not r.get("appeared"):
    say(False, "", f"settings: the window never came up ({r.get('problem', '?')})")
else:
    panes = r["panes"]
    say(r["oneWidth"] and r["width"] == r["expectedWidth"],
        f"settings: every pane is drawn at the panes' width ({r['width']:g} pt)",
        f"settings: the window is {r['width']:g} pt wide against the panes' {r['expectedWidth']:g} (one width: {r['oneWidth']})")
    # Each pane's window is that pane plus the same title bar and tabs. A window fitted to the
    # wrong thing still has five different heights, which is why that check alone is not this.
    c = r["chromes"]
    say(bool(c) and max(c) - min(c) <= 1,
        f"settings: every pane's window is exactly its content, plus {int(c[0]) if c else '?'} pt of title bar and tabs",
        f"settings: the windows are not their panes plus one chrome: {c} across {[p['pane'] for p in panes]}")
    # The window is the size of its pane: two panes at one height would mean a fixed frame is
    # still deciding — the state this stage was written for, 420 x 320 for all five.
    say(r["distinctHeights"] >= 3,
        f"settings: the window fits each pane ({r['shortest']:g}–{r['tallest']:g} pt over {r['distinctHeights']} heights)",
        f"settings: only {r['distinctHeights']} distinct heights across five panes — the window is not sizing to its content")
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
        "settings: the Dictionary pane was measured while it still said 'Asking the dictionary service…'")
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
    while IFS=$'\t' read -r verdict message; do
        case "$verdict" in
            PASS) pass "$message" ;;
            FAIL) flunk "$message" ;;
        esac
    done <<<"$verdicts"
    printf '%s' "$verdicts" | grep -qx DONE \
        || flunk "settings: the report's validator stopped before it finished: $(printf '%s' "$verdicts" | tail -3)"
fi

# **The shortcut is a control in Settings, and it takes the keyboard.**
#
# It used to be a window of its own, which activated XiaolaiDict to open and left XiaolaiDict active with nothing
# on screen when it closed — which is how the settings window came to appear by itself. What has to
# hold now is that the control on the Lookup pane is reachable and live: a field that drew the
# right combination and never saw a key press would look exactly like a working one.
# The field is armed by clicking the combination it shows, which the menu names too — read
# **before** Settings opens. Dumping the menu in between opened and dismissed XiaolaiDict's menu, which
# handed focus back to the app behind it (Ghostty, in a full run), so the click meant to arm the
# field only brought an inactive window forward. `|| true` inside the pipe because asking for an
# item that is not there is how the menu is dumped — it exits 1 on purpose — and `q` in `sed`
# rather than `| head`, which can close the pipe under `sed` and fail the pipeline for succeeding.
current=$({ "$helpers/menu-click" com.xiaolaidict "ZZZ-dump-the-menu" 2>&1 || true; } \
    | sed -n 's/.*Look Up Selection  *\([^"]*\)".*/\1/p;/Look Up Selection  *[^"]/q')
"$helpers/keys" 53 2>/dev/null || true
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
        if [ -z "$current" ] || ! "$helpers/click-element" com.xiaolaidict "$current" >/dev/null 2>&1; then
            flunk "shortcut: nothing on the Lookup pane showing '$current' to arm"
        else
            # Two separate claims, read separately, so a failure says which half broke: the click
            # armed the field, and the armed field hears the keyboard.
            sleep 1
            armed=$("$helpers/panel" com.xiaolaidict)
            if ! printf '%s' "$armed" | grep -q "Press a shortcut"; then
                flunk "shortcut: clicking '$current' did not arm the field (saw: $(printf '%s' "$armed" | head -c 200))"
            else
                pass "shortcut: clicking the combination arms the field"
                # A bare key is refused with a hint rather than accepted — a shortcut with no
                # modifier would fire while the reader was typing. The hint appearing is the proof
                # the field has the keyboard at all.
                "$helpers/keys" 40
                sleep 1
                if "$helpers/panel" com.xiaolaidict | grep -q "needs"; then
                    pass "shortcut: the armed field takes the keyboard, and refuses a key with no modifier"
                else
                    flunk "shortcut: the field was armed and never saw the key press (front: $(printf '%s' "$armed" | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p'))"
                fi
                # **Escape disarms it — read passively, before anything else moves focus.** Opening
                # the menu to check the shortcut would itself end the recording (the window resigns
                # key), so a broken Escape would be covered for by the check that followed it.
                "$helpers/keys" 53
                sleep 0.5
                if "$helpers/panel" com.xiaolaidict | grep -q "Press a shortcut"; then
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
names = {"Reading", "Lookup", "Dictionary", "Permissions", "About"}
print(next((t for w in json.load(sys.stdin)["windows"] for t in w["texts"][:1] if t in names), ""))')
    if ! why=$("$helpers/close-window" "${pane:-Lookup}" 2>&1); then
        flunk "shortcut: could not close the settings window afterwards ($why)"
    fi
    sleep 1
    # **However that went, the reader's shortcut must be registered again, and be theirs.** The
    # menu is the witness: it names the combination it answers to, and nothing when there is none.
    # Arming the field stands the hot key down on purpose, and a path that forgets to put it back
    # leaves the reader's shortcut quietly dead until XiaolaiDict is relaunched.
    after=$({ "$helpers/menu-click" com.xiaolaidict "ZZZ-dump-the-menu" 2>&1 || true; } \
        | sed -n 's/.*Look Up Selection  *\([^"]*\)".*/\1/p;/Look Up Selection  *[^"]/q')
    "$helpers/keys" 53 2>/dev/null || true
    if [ -z "$after" ]; then
        flunk "shortcut: after the field was used, no shortcut is registered"
    elif [ "$after" != "$current" ]; then
        flunk "shortcut: the reader's shortcut was not put back — $after where it was $current"
    else
        pass "shortcut: registered, and back to $current, after the field was used"
    fi
fi

# The drawer and the settings window, opened the same way, and read through Accessibility — which
# is what a screen reader uses, and what a SwiftUI `UtilityWindow` is invisible to.
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
    osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
    sleep 1
    before_front=$("$helpers/panel" com.xiaolaidict | sed -n 's/.*"frontmost":"\([^"]*\)".*/\1/p')
    if ! "$helpers/menu-click" com.xiaolaidict "$surface" >/dev/null 2>&1; then
        flunk "scenes: could not reach $surface in the menu"
        continue
    fi
    sleep 2
    seen=$("$helpers/panel" com.xiaolaidict)
    if printf '%s' "$seen" | grep -q '"windows":\[\]'; then
        flunk "scenes: $surface opened no window Accessibility can see"
    else
        pass "scenes: $surface is open and readable through Accessibility"
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
report=$(run_report --panel-report 90)
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
            f"({menu.get('problem', 'tracked=' + str(menu.get('menuTracked')) + ', clickPosted=' + str(menu.get('clickPosted')))})")

    # **The window is the height of the card.** It was the opening default for every card — 240,
    # with the whole footer below a fold the panel gives no sign of having. Three assertions,
    # because each alone passes on a defect: settled (a height read while it is still growing is
    # not the height the reader gets), within the ceiling (growing must stop where scrolling
    # starts), and taller than the opening default for a card that wants more (which is the fit
    # actually having happened rather than the default happening to be right).
    say(w["windowSettled"],
        f"panel: the window came to rest at {w['windowHeight']:g} pt",
        f"panel: the window was still resizing after {w['windowHeight']:g} pt — the height below means nothing")
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
    # A here-string, never a pipe: `flunk` increments a counter, and a pipe would run it in a
    # subshell where the increment is thrown away — a stage that reported its failures and then
    # passed. The settings stage above reads its verdicts the same way, for the same reason.
    while IFS=$'\t' read -r verdict text; do
        case "$verdict" in
            PASS) pass "$text" ;;
            NOTE) echo "NOTE  $text" ;;
            FAIL) flunk "$text" ;;
        esac
    done <<<"$verdicts"
    printf '%s' "$verdicts" | grep -qx DONE \
        || flunk "panel: the report's validator stopped before it finished: $(printf '%s' "$verdicts" | tail -3)"
fi
fi

if want model; then
# 14. The local model, end to end, in the signed bundle: downloaded from ModelScope by the app's own
#     downloader, a sense answer and a translation through the model service, the service's
#     footprint, and the service ending itself when idle — which is how the model unloads.
#
#     Run directly rather than through LaunchServices: nothing here captures the screen, so TCC's
#     refusal of processes launched over SSH does not apply, and a report that runs for minutes
#     while a download finishes is simpler to bound from here.
model_service="$app/Contents/XPCServices/XiaolaiDictModelService.xpc/Contents/MacOS/XiaolaiDictModelService"
# launchd starts the service with no arguments, so its idle interval comes from the app's defaults.
# Shortened for the run so the unload is seen inside it, and put back however the run ends.
if idle_original=$(defaults read com.xiaolaidict ModelIdleSeconds 2>/dev/null); then idle_had=yes; else idle_had=no; idle_original=""; fi
restore_idle() { restore_default ModelIdleSeconds "$idle_had" "$idle_original" -int; }
at_exit restore_idle
defaults write com.xiaolaidict ModelIdleSeconds -int 20
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
if why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1); then
    "$helpers/keys" 2 control option
    for _ in $(seq 1 100); do ! is_running "$model_service" || break; sleep 0.1; done
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
        flunk "model: the lookup wrote no ledger row (waited ${waited}s)"
    else
        chosen=$(sqlite3 -readonly "$ledger" "select coalesce(chosen_by, '') from sense_encounters where lookup_id = $lookup_id" 2>/dev/null || echo "")
        abstained=$(sqlite3 -readonly "$ledger" "select coalesce(sense_abstention, '') from lookups where id = $lookup_id" 2>/dev/null || echo "")
        # Any of `model`, `reader` or `onlySense` is the sense path having answered; which one it
        # was is reported rather than demanded, because an entry with a single sense is keyed
        # without asking a model at all and that is not a failure.
        if [ -n "$chosen" ]; then
            pass "model: the reader's own lookup reached the ledger with a sense (chosen_by=$chosen, ${waited}s)"
        elif [ -n "$abstained" ]; then
            # A sense nothing could key is a legitimate answer — but it has to be recorded as one.
            # What must never happen is a lookup that recorded neither.
            pass "model: the reader's own lookup recorded why no sense was marked ($abstained)"
        else
            flunk "model: the lookup recorded neither a chosen sense nor an abstention — the selector's answer never reached the ledger"
        fi
    fi
fi
find_pids "$model_service"
if [ -z "$app_pid_before" ]; then
    flunk "model: the app is not running, so crash isolation cannot be observed"
elif [ "${#PIDS[@]}" -eq 0 ]; then
    flunk "model: no model service to kill, so crash isolation was not exercised"
else
    kill -9 "${PIDS[@]}" 2>/dev/null || true
    for _ in $(seq 1 50); do is_running "$model_service" || break; sleep 0.1; done
    sleep 1
    find_pids "$exe"; app_pid_after=${PIDS[0]:-}
    if [ "$app_pid_after" = "$app_pid_before" ]; then
        pass "model: the app survived its model service being killed (pid $app_pid_before)"
    else
        flunk "model: the app went with its model service — was $app_pid_before, now ${app_pid_after:-gone}"
    fi
    again=$("$exe" --model-status 2>/dev/null || true)
    if printf '%s' "$again" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("reachable") and d.get("gpu") else 1)' 2>/dev/null; then
        pass "model: a fresh service answered after the kill"
    else
        flunk "model: nothing came back after the service was killed — $again"
    fi
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
    pass "model: the shipped ladder runs the local model first, and the labelled set backs it ($verdict)"
else
    flunk "model: the labelled set does not back the shipped ladder — $verdict"
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
Tools/e2e-status.sh record "$remote_version" <"$RUN_LOG"
echo
Tools/e2e-status.sh show
exit "$remote_status"
