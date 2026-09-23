#!/bin/bash
# End-to-end tests, on the E2E machine — never on the machine that builds. They run the published
# bundle there, as a user would: launched by LaunchServices, answering through its XPC service,
# surviving that service's death. Which machine, and why it is set up as it is, is in the
# developer's private notes; this script only takes its SSH name.
#
#   e2e.sh <ssh-host> [stage...]   ship .build/XiaolaiDict.app to the host and run stages there
#
# With no stage names every stage runs. With them, only those — a full run costs minutes and most
# changes touch one or two. Names: launch lookup crash accessibility selection shortcut deadline
# hover drawer recogniser setup scenes model.
#
# Each result is recorded in .build/e2e-status.tsv against the build it ran on. A pass is only a
# fact about that build, so one carried over from an older build is shown as stale rather than as a
# pass: a green mark that outlives what it tested is worse than no mark.
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
readonly STATUS=.build/e2e-status.tsv
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
    ssh_e2e bash -s -- "$REMOTE_DIR" <<'SH'
set -euo pipefail
app="$HOME/$1/XiaolaiDict.app"
pids() {  # processes started from exactly this executable path
    local table; table=$(ps -axww -o pid=,comm=) || { echo "ps failed" >&2; exit 1; }
    while read -r pid exe; do [ "$exe" != "$1" ] || echo "$pid"; done <<<"$table"
}
for exe in "$app/Contents/MacOS/XiaolaiDict" "$app/Contents/XPCServices/XiaolaiDictService.xpc/Contents/MacOS/XiaolaiDictService" \
           "$app/Contents/XPCServices/XiaolaiDictModelService.xpc/Contents/MacOS/XiaolaiDictModelService"; do
    running=$(pids "$exe" | tr '\n' ' ')
    [ -z "$running" ] || kill -TERM $running
    for _ in $(seq 1 50); do [ -n "$(pids "$exe")" ] || continue 2; sleep 0.1; done
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
cp Tools/e2e/notes.txt Tools/e2e/page.html .build/e2e/
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
trap 'rm -f "$RUN_LOG"' EXIT
set +e
ssh_e2e bash -s -- "$REMOTE_DIR" "$STAGES" <<'SH' | tee "$RUN_LOG" | grep -v "^RESULT	"
set -euo pipefail
app="$HOME/$1/XiaolaiDict.app"; exe="$app/Contents/MacOS/XiaolaiDict"
service="$app/Contents/XPCServices/XiaolaiDictService.xpc/Contents/MacOS/XiaolaiDictService"
failures=0
# The stages asked for; none means all of them.
# `${@:2}`, not `$2`: ssh rejoins its arguments into one command line and the remote shell splits
# them again, so a quoted "a b c" arrives as three separate arguments. Reading only $2 ran the
# first stage named and silently skipped the rest.
WANTED=("${@:2}")
STAGE=""
want() {  # want <name>: is this stage wanted? Also names it, for the result lines.
    STAGE=$1
    [ ${#WANTED[@]} -eq 0 ] && return 0
    local w
    for w in "${WANTED[@]}"; do [ "$w" = "$1" ] && return 0; done
    return 1
}
# RESULT lines are for the caller to record; PASS/FAIL lines are for a person to read.
pass() { echo "PASS  $*"; printf 'RESULT\t%s\tpass\n' "$STAGE"; }
flunk() { echo "FAIL  $*"; failures=$((failures + 1)); printf 'RESULT\t%s\tfail\n' "$STAGE"; }

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
    local cleanup
    for cleanup in ${cleanups[@]+"${cleanups[@]}"}; do "$cleanup" || true; done
    if [ "$finished" != true ]; then
        echo "FAIL  ${STAGE:-setup}: the script stopped at line ${died_at:-?} before the stage finished"
        printf "RESULT\t%s\tfail\n" "${STAGE:-setup}"
    fi
}
trap on_exit EXIT

pids() {
    local table; table=$(ps -axww -o pid=,comm=) || { echo "ps failed" >&2; exit 1; }
    while read -r pid path; do [ "$path" != "$1" ] || echo "$pid"; done <<<"$table"
}
outcomes() { python3 -c 'import json,sys; print(" ".join(json.loads(l)["outcome"] for l in sys.stdin if l.strip()))'; }
# expect <json> key=value ...: every field as stated (a value ending in * matches as a prefix,
# one starting with * as a suffix); prints the mismatches.
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
    ok = have.startswith(want[:-1]) if want.endswith("*") else have.endswith(want[1:]) if want.startswith("*") else have == want
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
    "$exe" "$flag" >"$out" 2> >(tee "/tmp/xiaolaidict-${label}.err" >&2) &
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

run_report() {  # run_report <flag> <budget-seconds>: the report's JSON on stdout, or nothing
    local flag=$1 budget=$2 name=${1#--}
    local out="/tmp/xiaolaidict-$name.json" err="/tmp/xiaolaidict-$name.err"
    rm -f "$out" "$err"
    open -n --stdout "$out" --stderr "$err" "$app" --args "$flag"
    local waited=0
    while [ ! -s "$out" ] && [ "$waited" -lt $((budget * 2)) ]; do sleep 0.5; waited=$((waited + 1)); done
    # Past its budget it is stopped; within it, it exits by itself once it has written. Waited for
    # either way, so no report outlives its stage.
    [ -s "$out" ] || pkill -f "MacOS/XiaolaiDict $flag" 2>/dev/null || true
    for _ in $(seq 1 40); do pgrep -f "MacOS/XiaolaiDict $flag" >/dev/null || break; sleep 0.25; done
    # And if it ignored that, it is killed: a report still running can still capture the screen,
    # and two captures at once deadlock.
    if pgrep -f "MacOS/XiaolaiDict $flag" >/dev/null; then
        pkill -9 -f "MacOS/XiaolaiDict $flag" 2>/dev/null || true
        for _ in $(seq 1 20); do pgrep -f "MacOS/XiaolaiDict $flag" >/dev/null || break; sleep 0.25; done
        # Said out loud if it is still there: a report that survives its own killing can still
        # capture the screen, and the next stage would be measuring against it.
        pgrep -f "MacOS/XiaolaiDict $flag" >/dev/null \
            && echo "note: $flag would not die; the stage after this one is running beside it"
    fi
    true
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
    if [ "$setup_shown_had" = yes ]; then
        defaults write com.xiaolaidict SetupWindowShown -bool "$setup_shown_original"
    else
        defaults delete com.xiaolaidict SetupWindowShown 2>/dev/null || true
    fi
}
at_exit restore_setup_shown

# Nearly every stage needs the app running, so having it running is *setup*. Stage 1 is what
# asserts that it starts and stays up, which is a different claim and stays a stage of its own.
# Without this, selecting a later stage failed for want of something an earlier one happened to do.
if [ -z "$(pids "$exe")" ]; then
    open "$app"
    for _ in $(seq 1 100); do [ -z "$(pids "$exe")" ] || break; sleep 0.1; done
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
    echo "FAIL  setup: the menu-bar item never appeared — every menu-driven stage below is void"
    failures=$((failures + 1))
fi

if want launch; then
# 1. LaunchServices starts it, and it stays up.
open "$app"
for _ in $(seq 1 100); do [ -z "$(pids "$exe")" ] || break; sleep 0.1; done
sleep 1
if [ -n "$(pids "$exe")" ]; then pass "launch: running, and still running after 1 s"; else flunk "launch: not running"; fi
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
    victims=$(pids "$service" | tr '\n' ' ')
    if [ -n "$victims" ] && [ "$(wc -l <"$out")" -ge 1 ]; then kill -KILL $victims; killed=$victims; break; fi
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
reading=$("$exe" --read-selection com.apple.finder 2>&1 || true)
if printf '%s' "$reading" | grep -q "Accessibility access for XiaolaiDict is off"; then
    flunk "accessibility: not granted to this session — the selection tests cannot run"
    echo; echo "$((failures)) stage(s) failed"; exit 1
fi
pass "accessibility: readable"
fi

if want selection; then
# 5. Selections, read as the reader would see them. Fixtures open through LaunchServices, so no
#    Automation prompt can block the screen. They need an unlocked screen: while it is locked,
#    Accessibility reports each app's only window, and its focused element, as the app itself.
locked=$(ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw -o - - 2>/dev/null || echo false)
if [ "$locked" = true ]; then
    flunk "selection: the screen is locked, so Accessibility shows no windows — unlock it and run again"
    echo; echo "$failures stage(s) failed"; exit 1
fi
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
    view=""
    for _ in $(seq 1 150); do
        view=$("$helpers/panel" com.xiaolaidict)
        printf '%s' "$view" | python3 -c '
import json, sys
failed = ("Looking up", "No entry for", "could not be asked", "needs Accessibility")
panels = [w for w in json.load(sys.stdin)["windows"] if "meeting" in w["texts"] and not any(m in t for t in w["texts"] for m in failed)]
sys.exit(0 if panels else 1)
' && break
        sleep 0.1
    done
    view=$("$helpers/panel" com.xiaolaidict)
    if why=$(python3 - "$view" 2>&1 <<'PY'
import json, sys
view = json.loads(sys.argv[1])
# The answer card, headed by the word itself — an exact text element, so the waiting view's
# "Looking up “meeting” in your dictionaries…" cannot pass for it. The old panel was asserted by
# its lemma row and its WebKit page; the card that replaced it has neither, and both checks went
# on failing a panel that had answered.
# Not merely the heading: a card that says "No entry for “meeting”" carries the word too, and a
# check for the heading alone passed one. So an answer is the word's card with no failure on it.
failed = ("Looking up", "No entry for", "could not be asked", "needs Accessibility")
panels = [w for w in view["windows"] if "meeting" in w["texts"]
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
    stopped=$(pids "$service" | tr '\n' ' ')
    if [ -z "$stopped" ]; then
        flunk "waiting panel: no dictionary service to suspend — the test did not happen"
    else
        kill -STOP $stopped
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
            flunk "waiting panel: never appeared while the service was suspended"
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
            if printf '%s' "$view" | grep -q '"meeting"' && ! printf '%s' "$view" | grep -qE 'Looking up|No entry for|could not be asked'; then
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
restore_glass() {
    if [ "$had_glass" = yes ]; then defaults write com.xiaolaidict DrawerGlass "$original_glass"
    else defaults delete com.xiaolaidict DrawerGlass 2>/dev/null || true; fi
}
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
    flunk "drawer: --history-report did not report ($(head -c 160 /tmp/xiaolaidict-history-report.err 2>/dev/null))"
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
    local out=/tmp/xiaolaidict-read-point.json err=/tmp/xiaolaidict-read-point.err
    rm -f "$out" "$err"
    open -n --stdout "$out" --stderr "$err" "$app" --args --read-point "$1" "$2"
    # Polled, not slept: a cold capture pays a system-wide warm-up that a warm one does not.
    for _ in $(seq 1 60); do
        [ -s "$out" ] || [ -s "$err" ] || { sleep 0.5; continue; }
        break
    done
    cat "$out" 2>/dev/null
}

open -a Ghostty; sleep 3
if ! frame=$("$helpers/window-frame" com.mitchellh.ghostty 2>&1); then
    flunk "recogniser: no Ghostty window to read ($frame)"
else
    read -r wx wy _ _ <<<"$frame"
    # A grid, because where a terminal's text sits depends on its prompt, its font and its padding.
    reading=""
    for dy in 98 113 83 128 68 143; do
        for dx in 50 160 280; do
            got=$(read_point $((wx + dx)) $((wy + dy)))
            if printf '%s' "$got" | grep -q opticalRecognition; then reading=$got; break 2; fi
        done
    done
    if [ -z "$reading" ]; then
        flunk "recogniser: no point in the Ghostty window came back through OCR; last error: $(head -c 120 /tmp/xiaolaidict-read-point.err 2>/dev/null)"
    else
        if why=$(expect "$reading" captureSource=opticalRecognition bundleID=com.mitchellh.ghostty 2>&1); then
            word=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["text"])' "$reading")
            pass "recogniser: read '$word' from a terminal through OCR"
        else
            flunk "recogniser: $why"
        fi
        # Asserted warm. The first capture after boot pays a system-wide ScreenCaptureKit warm-up
        # — measured once at 14.8 s against ~0.5 s for every read after — which is a fact about the
        # machine, so a budget asserted on the first read would measure its state and not the code.
        took=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["milliseconds"])' "$reading")
        if [ "$took" -lt 5000 ]; then
            pass "recogniser: the read cost ${took} ms, inside the 5 s capture deadline"
        else
            flunk "recogniser: the read took ${took} ms, past the 5 s capture deadline"
        fi
    fi
fi
fi

if want setup; then
board_drawn_now() { "$helpers/on-screen" com.xiaolaidict "Set Up" | grep -q '"drawn":true' && echo yes || echo no; }
# **Settle before driving the menu after a launch.** A click that lands while the app's state changes
# under an open menu is dropped: SwiftUI re-renders the menu and the click goes nowhere, while
# `menu-click` still reports it. Measured 2026-09-22 — after a cold start with the board open, the
# dictionary list arrives from the service a second or two later, and 2 clicks of 6 were lost; with
# the click held until it had arrived, 0 of 8. The board says when it has: its dictionary row stops
# asking. Bounded, so a service that never answers is reported by the check that needs it.
# Defined before anything below uses them: `settle_after_launch` calls `board_on_screen`, and
# a helper defined after its first caller is "command not found" — under `|| return 0`, silently.
restart_app() {  # restart_app: quit XiaolaiDict, start it again, wait for its menu-bar item
    local running
    running=$(pids "$exe" | tr '\n' ' ')
    [ -z "$running" ] || kill -TERM $running
    for _ in $(seq 1 100); do [ -n "$(pids "$exe")" ] || break; sleep 0.1; done
    open "$app"
    for _ in $(seq 1 100); do [ -z "$(pids "$exe")" ] || break; sleep 0.1; done
    for _ in $(seq 1 100); do
        "$helpers/menu-click" com.xiaolaidict --ready >/dev/null 2>&1 && return 0
        sleep 0.2
    done
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

    # **The model row, exercised rather than read.** Its heading alone would pass with no buttons,
    # no fallback named, and a 3 GB download that started by itself. What must be true on a Mac
    # where the model is not downloaded: it is still needed, the weaker engine is named, both
    # choices are offered — and nothing has begun downloading.
    if printf '%s' "$shown" | grep -q "Translation and sense picking"; then
        model_row=$(printf '%s' "$shown" | tr ',' '\n' | grep -A14 "Translation and sense picking" || true)
        # Every state the row can be in, named — and **a download under way is a failure here**, not
        # a pass. Nothing in this stage asks for one, so a 3 GB download that has begun by the time
        # the board is first opened is the regression the rule exists to catch: it used to be one of
        # the accepted branches, two lines under a comment promising "nothing has begun downloading".
        if printf '%s' "$shown" | grep -q "Qwen3.5.*translates your sentences and picks the sense you met, on this Mac. Nothing is sent anywhere."; then
            pass "setup: the model row says the model is ready"
        elif printf '%s' "$shown" | grep -q "Downloading Qwen3.5"; then
            flunk "setup: a 3 GB download had begun without the reader asking for one — $(printf '%s' "$model_row" | head -c 300)"
        elif printf '%s' "$shown" | grep -q "This Mac has too little memory for the local model."; then
            # Nothing to offer and nothing coming later, so the fallback must not say "Until then".
            if printf '%s' "$shown" | grep -q "Without a local model"; then
                pass "setup: the model row says this Mac cannot hold the model, and what answers instead"
            else
                flunk "setup: too little memory, and the fallback still promises a model later — $(printf '%s' "$model_row" | head -c 300)"
            fi
        elif printf '%s' "$shown" | grep -q "download stopped"; then
            # **Resume, not Download.** The button says what it does: the size a stopped download was
            # of, finishing what is already on disk.
            if printf '%s' "$shown" | grep -q "Resume"; then
                pass "setup: the model row reports a stopped download and offers to resume it"
            else
                flunk "setup: a stopped download with no way to resume it — $(printf '%s' "$model_row" | head -c 300)"
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
    flunk "settings: --settings-report printed nothing ($(head -c 160 /tmp/xiaolaidict-settings-report.err 2>/dev/null))"
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
    if [ "$front" != com.xiaolaidict ]; then
        flunk "shortcut: Settings never came forward — $front is in front"
    elif ! "$helpers/click-element" com.xiaolaidict Lookup >/dev/null 2>&1; then
        flunk "shortcut: no Lookup pane in the settings window"
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

if want model; then
# 13. The local model, end to end, in the signed bundle: downloaded from ModelScope by the app's own
#     downloader, a sense answer and a translation through the model service, the service's
#     footprint, and the service ending itself when idle — which is how the model unloads.
#
#     Run directly rather than through LaunchServices: nothing here captures the screen, so TCC's
#     refusal of processes launched over SSH does not apply, and a report that runs for minutes
#     while a download finishes is simpler to bound from here.
model_service="$app/Contents/XPCServices/XiaolaiDictModelService.xpc/Contents/MacOS/XiaolaiDictModelService"
# launchd starts the service with no arguments, so its idle interval comes from the app's defaults.
# Shortened for the run so the unload is seen inside it, and put back however the run ends.
if idle_original=$(defaults read com.xiaolaidict ModelIdleSeconds 2>/dev/null); then idle_had=yes; else idle_had=no; fi
restore_idle() {
    if [ "$idle_had" = yes ]; then
        defaults write com.xiaolaidict ModelIdleSeconds -int "$idle_original"
    else
        defaults delete com.xiaolaidict ModelIdleSeconds 2>/dev/null || true
    fi
}
at_exit restore_idle
defaults write com.xiaolaidict ModelIdleSeconds -int 20
# A service already running read the old interval; this run's must start fresh. Asserted, not
# assumed: everything after this would otherwise be measuring the old process — its old interval,
# and a model it had already loaded.
for pid in $(pids "$model_service"); do kill -TERM "$pid" 2>/dev/null || true; done
for _ in $(seq 1 50); do [ -z "$(pids "$model_service")" ] && break; sleep 0.1; done
if [ -n "$(pids "$model_service")" ]; then
    flunk "model: a model service from before the stage would not quit; every check below would measure it"
else

status=$("$exe" --model-status 2>/dev/null || true)
if printf '%s' "$status" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("gpu") else 1)' 2>/dev/null; then
    pass "model: the signed service evaluates an MLX op on the GPU ($(printf '%s' "$status" | sed -n 's/.*"gpu":"\([^"]*\)".*/\1/p'))"
else
    flunk "model: the service cannot run MLX — $status"
fi

# Bounded at 40 minutes: a first run downloads 3 GB, measured at ~10 MB/s from this network.
report_out=/tmp/xiaolaidict-model-report.json
run_bounded --model-report "$report_out" 2400 model-report || true
report=$(cat "$report_out" 2>/dev/null || true)
echo "model report: $report"
if why=$(expect "$report" installed=True sense=2 loaded=True prewarmed=True relaunched=True 2>&1); then
    pass "model: downloaded or found whole, a sense answer (2 of 3, the cargo space) and a translation through the service"
else
    flunk "model: $why"
fi
if printf '%s' "$report" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("translation") else 1)' 2>/dev/null; then
    pass "model: the sentence came back translated: $(printf '%s' "$report" | sed -n 's/.*"translation":"\([^"]*\)".*/\1/p')"
else
    flunk "model: no translation came back"
fi
# The sentence pane asks this model too — and it is the only engine a reader without Apple
# Intelligence has for it, so "the model answers" has to include this one.
if printf '%s' "$report" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("explanation") else 1)' 2>/dev/null; then
    pass "model: the sentence came back explained ($(printf '%s' "$report" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["explanation"]))' 2>/dev/null) characters)"
else
    flunk "model: no explanation came back ($(printf '%s' "$report" | sed -n 's/.*"explanationFailure":"\([^"]*\)".*/\1/p'))"
fi
footprint=$(printf '%s' "$report" | sed -n 's/.*"footprintMB":\([0-9]*\).*/\1/p')
# A service holding a 4B model and answering is gigabytes; a few megabytes means nothing was loaded.
if [ -n "$footprint" ] && [ "$footprint" -gt 1000 ]; then
    pass "model: the service holds the model — ${footprint} MB"
else
    flunk "model: the service's footprint is ${footprint:-unknown} MB — the model is not loaded"
fi

# The labelled set, every rung, in this bundle — the measurement that decides the ladder's order.
# Bounded: its Apple rung calls the on-device model directly, and a stalled one would hang the whole
# run with no result and no cleanup.
sense_out=/tmp/xiaolaidict-sense-report.json
run_bounded --sense-report "$sense_out" 600 sense-report || true
senses=$(cat "$sense_out" 2>/dev/null || true)
echo "sense report: $senses"
if verdict=$(printf '%s' "$senses" | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = d["scores"]
def n(rung, bucket): return s.get(rung, {}).get(bucket, 0)
cases = d["cases"]
for rung in ("localModel", "onDevice", "embedding", "ladder"):
    total = sum(s.get(rung, {}).values())
    if total != cases: sys.exit(f"{rung} scored {total} of {cases} cases")
if not d["localModelInstalled"]: sys.exit("the local model is not installed, so its rung measured nothing")
# **The shipped ladder, in its own order.** Scoring the local model beside the ladder says nothing
# about where the ladder puts it: reordering it to embedding-first would still pass.
order = d.get("order")
if order[:1] != ["localModel"]: sys.exit(f"the shipped ladder does not run the local model first: {order}")
# And what the ladder answered is what the local model answered, on every case it decided at all --
# **including the ones it got wrong**. Checking only its right answers let a ladder that quietly
# dropped the top rung pass whenever that rung was mistaken, which is exactly when the difference
# between the rungs shows.
for row in d["answers"]:
    local = row["localModel"]
    if local in ("right", "wrong") and row["ladder"] != local:
        sys.exit("the ladder did not carry the local model answer on " + row["word"] + ": "
                 + local + " became " + row["ladder"])
# D6: a rung above another earns its place with at least 10 points more top-1 accuracy and a
# confidently-wrong count no higher.
def earns(upper, lower):
    gain = (n(upper, "right") - n(lower, "right")) / cases * 100
    return gain >= 10 and n(upper, "wrong") <= n(lower, "wrong")
RIGHT, WRONG = "right", "wrong"
print("; ".join(f"{r}: {n(r, RIGHT)} right, {n(r, WRONG)} wrong" for r in ("localModel", "onDevice", "embedding")))
# **Every step of the order is earned, not just the top one.** Apple sits above the embedding rung
# in the shipped ladder, and nothing here asked it to deserve that: a middle rung no better than the
# one below it, or one that refused every sentence, passed unexamined.
#
# Apple is skipped only where it is genuinely not on this Mac -- every case abstaining *because it
# is unavailable*. An Apple rung that abstained for any other reason is a rung that ran, and is
# measured like the rest.
apple = [row.get("onDevice", "") for row in d["answers"]]
absent = bool(apple) and all("(unavailable)" in verdict for verdict in apple)
if absent:
    ok = earns("localModel", "embedding")
else:
    ok = (earns("localModel", "onDevice") and earns("onDevice", "embedding")
          and earns("localModel", "embedding"))
sys.exit(0 if ok else 2)
' 2>&1); then
    pass "model: the shipped ladder runs the local model first, and the labelled set backs it ($verdict)"
else
    flunk "model: the labelled set does not put the local model first — $verdict"
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
[ "$failures" -eq 0 ] && echo "all stages passed" || { echo "$failures stage(s) failed"; exit 1; }
SH
remote_status=${PIPESTATUS[0]}
set -e

# Recorded against the build it ran on. Without that a pass says only "it worked once", which is
# not a claim anyone can act on — and a green mark that outlives what it tested is worse than none.
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)
mkdir -p "$(dirname "$STATUS")"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# A stage passes only if every assertion in it passed. Taking the last result per stage recorded
# a stage as green when one of its checks had failed — the same hollow mark this file exists to
# prevent. awk rather than an associative array: macOS ships bash 3.2, which has none.
while IFS=$'\t' read -r name result; do
    [ -n "${name:-}" ] || continue
    if [ -f "$STATUS" ]; then grep -v "^$name	" "$STATUS" > "$STATUS.new" || true; else : > "$STATUS.new"; fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$result" "$build" "$now" >> "$STATUS.new"
    mv "$STATUS.new" "$STATUS"
done < <(grep "^RESULT	" "$RUN_LOG" | awk -F'\t' '
    { if ($3 == "fail") seen[$2] = "fail"; else if (!($2 in seen)) seen[$2] = "pass" }
    END { for (n in seen) print n "\t" seen[n] }' || true)

echo
echo "== recorded against build $build"
[ -f "$STATUS" ] && sort "$STATUS" | while IFS=$'\t' read -r name result ran when; do
    if [ "$ran" != "$build" ]; then
        printf '  %-14s %-4s stale (ran on %s)\n' "$name" "$result" "$ran"
    else
        printf '  %-14s %-4s\n' "$name" "$result"
    fi
done
echo "  $STATUS"
exit "$remote_status"
