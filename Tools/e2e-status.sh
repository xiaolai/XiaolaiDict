#!/bin/bash
# The end-to-end stage record: one line per stage, against the build it ran on.
#
#   e2e-status.sh record <build> [<keys> <host> <os> <tree> <mode>]
#                          file the `RESULT<TAB>stage<TAB>pass|fail` lines arriving on stdin
#   e2e-status.sh show     print what each stage last did, marking anything stale
#   e2e-status.sh require-fresh
#                          exit 1 unless every stage's last result is a fresh pass of a development bundle built from
#                          this clean source tree — what `make release` asks before it builds and again before it
#                          uploads anything
#
# **A row is `stage, result, build, when, key, host, os, tree, mode`**, tab-separated. `key`, `host` and `os` — the
# stage's inputs key (`Tools/e2e-inputs.py keys`), the E2E Mac's hardware UUID and its macOS version and build — are
# what lets a later run carry a pass forward instead of running the stage again; `Tools/e2e-inputs.py` reads them
# (`read_status`), and a row without them, or with `-` for a key, is never carried. `tree` and `mode` are the release
# receipt: the git tree the bundle was built from, `-` where the tree was dirty or moved before the run ended, and
# `development` or `release`. Only a stage that ran is filed: a carried stage keeps the row of the fresh pass it was
# carried from, so the build on that row says what was actually tested.
#
# **One implementation, because two had already drifted.** `make e2e-status` and the end of a run
# each printed this table from its own copy of the rules, and the run's copy had quietly lost the
# timestamp column while the two disagreed about what to call a bundle that is not there. The file,
# its format and both rules below live here and nowhere else.
set -euo pipefail
cd "$(dirname "$0")/.."
readonly STATUS=.build/e2e-status.tsv
readonly APP=.build/XiaolaiDict.app
# The E2E Mac the last run reached — hardware UUID, macOS version and build, when — written by `Tools/e2e.sh`, so `show`
# can ask the planner whether a row would be carried there without reaching the Mac.
readonly SEEN=.build/e2e-host.tsv

# The build the bundle on disk is, or `none` where there is no bundle. Read the same way for both
# subcommands: a record filed against one build and read against another is what `show` calls stale,
# and two spellings of "there is no bundle" would make every row stale for the wrong reason.
#
# **PlistBuddy writes "File Doesn't Exist, Will Create: …" on stdout and then exits 1**, so the
# obvious `… || echo none` captures the message *and* the fallback, and files both as the build
# number. Measured 2026-09-23; both copies of this table did it, and with no bundle on disk
# `make e2e-status` printed that sentence where the build belongs. Its stdout counts only where it
# exited 0.
build() {
    local version
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null) || version=""
    printf '%s\n' "${version:-none}"
}

# record [build]: the build the results belong to. **Passed in by the caller that ran them**, because
# reading it here reads whatever bundle is on disk *now* — and a `make` during a ten-minute remote run
# would then file this run's results against a build that never left this machine. Falls back to the
# bundle on disk so a hand-run `record` still works, which is the only caller that legitimately has
# nothing to pass.
record() {
    local ran now name result keys=${2:-} host=${3:--} os=${4:--} tree=${5:--} mode=${6:--} key
    ran=${1:-$(build)}
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$(dirname "$STATUS")"
    # **A stage passes only if every assertion in it passed.** Taking the last result per stage
    # recorded a stage as green when one of its checks had failed — the same hollow mark the suite
    # exists to prevent. awk rather than an associative array: macOS ships bash 3.2, which has none.
    # A run that emitted no RESULT line at all leaves the record untouched rather than failing here;
    # the run's own exit status is what says it went wrong.
    { grep "^RESULT	" || true; } | awk -F'\t' '
        { if ($3 == "fail") seen[$2] = "fail"; else if (!($2 in seen)) seen[$2] = "pass" }
        END { for (n in seen) print n "\t" seen[n] }' \
    | while IFS=$'\t' read -r name result; do
        [ -n "${name:-}" ] || continue
        if [ -f "$STATUS" ]; then grep -v "^$name	" "$STATUS" > "$STATUS.new" || true; else : > "$STATUS.new"; fi
        # The key the stage ran under, or `-` — no keys given, a row that is not a stage, or a key that moved mid-run.
        key=-
        [ -z "$keys" ] || key=$(awk -F'\t' -v s="$name" '$1 == s { print $2 }' "$keys")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$result" "$ran" "$now" "${key:--}" "$host" "$os" \
            "$tree" "$mode" >> "$STATUS.new"
        mv "$STATUS.new" "$STATUS"
    done
}

# **What each row is worth now**, by the planner's own rule rather than a second copy of it: FRESH PASS on the bundle on
# disk, CARRIED where a plain `make e2e` would carry it to the E2E Mac the last run saw, STALE where it would run it,
# UNKNOWN where the keys cannot be made or no run has recorded an E2E Mac, and FAILED. A pass is a fact about the build
# it ran on: a carried row keeps that build, its time, its Mac and its macOS, and says it satisfies no merge or release.
show() {
    local ran python keys status=0
    ran=$(build)
    python=$(Tools/python.sh) || exit 1
    keys=$(mktemp)
    # Keys that cannot be made leave the file empty, which reads as UNKNOWN: never a carry on a guess.
    "$python" Tools/e2e-inputs.py keys >"$keys" 2>/dev/null || : >"$keys"
    "$python" Tools/e2e-inputs.py show "$STATUS" "$ran" --keys "$keys" --seen "$SEEN" || status=$?
    rm -f "$keys"
    return "$status"
}

# **A merge or a release needs a fresh pass of every stage of its own source.** Not of its own *build*: a release is
# renumbered and compiled without the instruments the stages observe through (ADR-0010), so the evidence is a fresh
# `make e2e-full` of a development bundle built from the same clean git tree, on one E2E Mac and macOS build. A CARRIED
# result is a development-loop shortcut — its inputs were unchanged, which is a judgment about what each stage
# exercises, not a run — and is refused, as is a pass of another tree, a dirty one, or a release bundle. Decided in
# `Tools/e2e-inputs.py release-gate`, which also prints what the release artifact itself was never driven through.
require_fresh() {
    local python
    python=$(Tools/python.sh) || exit 1
    "$python" Tools/e2e-inputs.py release-gate "$STATUS"
}

case ${1:-} in
    record) shift; record "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" ;;
    show) show ;;
    require-fresh) require_fresh ;;
    *) echo "usage: e2e-status.sh record|show|require-fresh" >&2; exit 64 ;;
esac
