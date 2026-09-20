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
# hover drawer recogniser scenes.
#
# Each result is recorded in .build/e2e-status.tsv against the build it ran on. A pass is only a
# fact about that build, so one carried over from an older build is shown as stale rather than as a
# pass: a green mark that outlives what it tested is worse than no mark.
#
# Each stage asserts what it saw, including that the thing it tested happened at all: a test that
# silently did nothing must not look like one that passed.

set -euo pipefail
cd "$(dirname "$0")/.."

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
for exe in "$app/Contents/MacOS/XiaolaiDict" "$app/Contents/XPCServices/XiaolaiDictService.xpc/Contents/MacOS/XiaolaiDictService"; do
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
for helper in select-text select-web keys panel claim-escape word-point window-frame menu-click; do
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
rows() { sqlite3 -readonly "$ledger" "select count(*) from lookups" 2>/dev/null || echo 0; }

# Nearly every stage needs the app running, so having it running is *setup*. Stage 1 is what
# asserts that it starts and stays up, which is a different claim and stays a stage of its own.
# Without this, selecting a later stage failed for want of something an earlier one happened to do.
if [ -z "$(pids "$exe")" ]; then
    open "$app"
    for _ in $(seq 1 100); do [ -z "$(pids "$exe")" ] || break; sleep 0.1; done
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
before=$(rows)
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
panels = [w for w in json.load(sys.stdin)["windows"] if "→ meet" in w["texts"]]
sys.exit(0 if panels and panels[0].get("webTexts") else 1)
' && break
        sleep 0.1
    done
    view=$("$helpers/panel" com.xiaolaidict)
    if why=$(python3 - "$view" 2>&1 <<'PY'
import json, sys
view = json.loads(sys.argv[1])
panels = [w for w in view["windows"] if "→ meet" in w["texts"]]
problems = []
if view["frontmost"] != "com.apple.TextEdit": problems.append(f"focus moved to {view['frontmost']}")
if not panels: sys.exit(f"no panel with the entry: {view}")
page = panels[0].get("webTexts")
if page is None: problems.append("no rendered entry in the panel")
elif len(page) < 3 or any("@namespace" in t or "@charset" in t for t in page):
    problems.append(f"the entry is not laid out as a page ({len(page)} text runs, first: {page[0][:60]!r})")
sys.exit("; ".join(problems) if problems else 0)
PY
    ); then pass "shortcut: the panel shows the rendered entry, and TextEdit keeps focus"; else flunk "shortcut: $why"; fi

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

    after=$(rows)
    row=$(sqlite3 -readonly -json "$ledger" "select surface, lemma, context, source_app, result, answered_by, capture_source, context_quality from lookups order by id desc limit 1" 2>&1)
    if [ "$after" -eq $((before + 1)) ] && why=$(expect "$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[0]))')" \
            surface=meeting lemma=meet "context=The meeting ended after we stopped meeting at noon." \
            source_app=com.apple.TextEdit result=found answered_by=dictionaryService \
            capture_source=accessibilityTextRange context_quality=complete 2>&1); then
        pass "ledger: the lookup is recorded, with its capture quality"
    else
        flunk "ledger: $before rows before, $after after; last row: ${why:-$row}"
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
trap resume EXIT
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
            if printf '%s' "$view" | grep -q '→ meet' && ! printf '%s' "$view" | grep -q 'Looking up'; then
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
drawer=$("$exe" --history-report 2>&1) && drawer_status=0 || drawer_status=$?
if [ "$drawer_status" -ne 0 ] && ! python3 -c 'import json,sys; json.loads(sys.argv[1])' "$drawer" 2>/dev/null; then
    flunk "drawer: --history-report did not report ($drawer)"
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

if want scenes; then
# 11. The windows that are now SwiftUI scenes, driven the way a reader drives them.
#
#    With a real click, not `AXPress`: pressing a menu through Accessibility opens it *without
#    activating the app*, so a window opened from it never becomes key and never sees a key press.
#    A working recorder looks broken that way, and a broken one would look working.
if ! "$helpers/menu-click" com.xiaolaidict "Change Shortcut…" >/dev/null 2>&1; then
    flunk "recorder: could not reach Change Shortcut… in the menu"
else
    # Polled, not slept: the window is opened by a scene and arrives when it arrives.
    for _ in $(seq 1 40); do
        before=$("$helpers/panel" com.xiaolaidict)
        printf '%s' "$before" | grep -q '"windows":\[\]' || break
        sleep 0.25
    done
    # A key with no modifier is refused with a hint rather than accepted — a shortcut without one
    # would fire while the reader was typing. The hint changing is the proof the window has the
    # keyboard at all.
    "$helpers/keys" 40
    sleep 1
    after=$("$helpers/panel" com.xiaolaidict)
    if printf '%s' "$after" | grep -q "needs"; then
        pass "recorder: takes the keyboard, and refuses a shortcut with no modifier"
    else
        flunk "recorder: the window never saw the key press (before: $(printf '%s' "$before" | head -c 80))"
    fi
    # Only meaningful if something was open: Escape "closing" a window that never appeared is a
    # pass that proves nothing, which is how this read before.
    if printf '%s' "$before" | grep -q '"windows":\[\]'; then
        flunk "recorder: nothing was open for Escape to close"
    else
        "$helpers/keys" 53
        sleep 1
        if "$helpers/panel" com.xiaolaidict | grep -q '"windows":\[\]'; then
            pass "recorder: Escape cancels and closes it"
        else
            flunk "recorder: Escape did not close it"
        fi
    fi
fi

# The drawer and the settings window, opened the same way, and read through Accessibility — which
# is what a screen reader uses, and what a SwiftUI `UtilityWindow` is invisible to.
for surface in "Reading History" "Settings…"; do
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
    "$helpers/keys" 53 2>/dev/null || true
    sleep 1
done
fi

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
