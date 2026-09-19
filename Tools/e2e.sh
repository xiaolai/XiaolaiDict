#!/bin/bash
# End-to-end tests, on the E2E machine — never on the machine that builds. They run the published
# bundle there, as a user would: launched by LaunchServices, answering through its XPC service,
# surviving that service's death. Which machine, and why it is set up as it is, is in the
# developer's private notes; this script only takes its SSH name.
#
#   e2e.sh <ssh-host>     ship .build/XiaolaiDict.app to the host and run every stage there
#
# Each stage asserts what it saw, including that the thing it tested happened at all: a test that
# silently did nothing must not look like one that passed.

set -euo pipefail
cd "$(dirname "$0")/.."

host=${1:?usage: e2e.sh <ssh-host>}
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
for helper in select-text select-web keys panel claim-escape word-point; do
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
stage "run"
ssh_e2e bash -s -- "$REMOTE_DIR" <<'SH'
set -euo pipefail
app="$HOME/$1/XiaolaiDict.app"; exe="$app/Contents/MacOS/XiaolaiDict"
service="$app/Contents/XPCServices/XiaolaiDictService.xpc/Contents/MacOS/XiaolaiDictService"
failures=0
pass() { echo "PASS  $*"; }
flunk() { echo "FAIL  $*"; failures=$((failures + 1)); }
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

# 1. LaunchServices starts it, and it stays up.
open "$app"
for _ in $(seq 1 100); do [ -z "$(pids "$exe")" ] || break; sleep 0.1; done
sleep 1
if [ -n "$(pids "$exe")" ]; then pass "launch: running, and still running after 1 s"; else flunk "launch: not running"; fi

# 2. A lookup through the real XPC path answers with entries.
if lookup=$("$exe" --lookup ephemeral 2>&1) && [ "$(printf '%s\n' "$lookup" | outcomes)" = entries ]; then
    pass "lookup: entries through the dictionary service"
else
    flunk "lookup: $lookup"
fi

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

# 4. Accessibility, which the selection tests need: said plainly either way.
reading=$("$exe" --read-selection com.apple.finder 2>&1 || true)
if printf '%s' "$reading" | grep -q "Accessibility access for XiaolaiDict is off"; then
    flunk "accessibility: not granted to this session — the selection tests cannot run"
    echo; echo "$((failures)) stage(s) failed"; exit 1
fi
pass "accessibility: readable"

# 5. Selections, read as the reader would see them. Fixtures open through LaunchServices, so no
#    Automation prompt can block the screen. They need an unlocked screen: while it is locked,
#    Accessibility reports each app's only window, and its focused element, as the app itself.
locked=$(ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw -o - - 2>/dev/null || echo false)
if [ "$locked" = true ]; then
    flunk "selection: the screen is locked, so Accessibility shows no windows — unlock it and run again"
    echo; echo "$failures stage(s) failed"; exit 1
fi
helpers="$HOME/$1/e2e"
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

# 6. The reader's own path: a selection, the shortcut, the panel, the ledger, and Escape.
#    The shortcut is XiaolaiDict's default, Control-Option-D; a machine where it was changed fails here.
ledger="$HOME/Library/Application Support/XiaolaiDict/ledger.sqlite"
rows() { sqlite3 -readonly "$ledger" "select count(*) from lookups" 2>/dev/null || echo 0; }
before=$(rows)
open -a TextEdit "$helpers/notes.txt"; sleep 1.5
if ! why=$("$helpers/select-text" com.apple.TextEdit meeting 2 2>&1); then
    flunk "shortcut: could not select ($why)"
else
    "$helpers/keys" 2 control option
    view=""
    for _ in $(seq 1 50); do
        view=$("$helpers/panel" com.xiaolaidict)
        printf '%s' "$view" | grep -q '→ meet' && break
        sleep 0.1
    done
    sleep 1  # the entry's page, loaded after the panel shows
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

echo
[ "$failures" -eq 0 ] && echo "all stages passed" || { echo "$failures stage(s) failed"; exit 1; }
SH
