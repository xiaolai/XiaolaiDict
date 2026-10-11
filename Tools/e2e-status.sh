#!/bin/bash
# The end-to-end stage record: one line per stage, against the build it ran on.
#
#   e2e-status.sh record <build> [<keys> <host> <os>]
#                          file the `RESULT<TAB>stage<TAB>pass|fail` lines arriving on stdin
#   e2e-status.sh show     print what each stage last did, marking anything stale
#   e2e-status.sh require-fresh <build>
#                          exit 1 unless every stage's last result is a fresh pass on <build>
#
# **A row is `stage, result, build, when, key, host, os`**, tab-separated. The last three — the stage's inputs key
# (`Tools/e2e-inputs.py keys`), the E2E Mac's hardware UUID and its macOS version and build — are what lets a later
# run carry a pass forward instead of running the stage again; `Tools/e2e-inputs.py` reads them (`read_status`), and
# a row without them, or with `-` for a key, is never carried. Only a stage that ran is filed: a carried stage keeps
# the row of the fresh pass it was carried from, so the build on that row says what was actually tested.
#
# **One implementation, because two had already drifted.** `make e2e-status` and the end of a run
# each printed this table from its own copy of the rules, and the run's copy had quietly lost the
# timestamp column while the two disagreed about what to call a bundle that is not there. The file,
# its format and both rules below live here and nowhere else.
set -euo pipefail
cd "$(dirname "$0")/.."
readonly STATUS=.build/e2e-status.tsv
readonly APP=.build/XiaolaiDict.app

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
    local ran now name result keys=${2:-} host=${3:--} os=${4:--} key
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
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$result" "$ran" "$now" "${key:--}" "$host" "$os" >> "$STATUS.new"
        mv "$STATUS.new" "$STATUS"
    done
}

show() {
    local ran name result on when
    ran=$(build)
    echo "end-to-end stages, against build $ran on disk"
    if [ ! -f "$STATUS" ]; then
        echo "  nothing recorded yet"
        return 0
    fi
    # **A pass is a fact about the build it ran on and expires with it.** One carried over from an
    # older build is shown as stale rather than as a pass: a green mark that outlives what it tested
    # is worse than no mark.
    sort "$STATUS" | while IFS=$'\t' read -r name result on when _; do
        if [ "$on" != "$ran" ]; then
            printf '  %-14s %-4s stale (ran on %s, %s)\n' "$name" "$result" "$on" "$when"
        else
            printf '  %-14s %-4s %s\n' "$name" "$result" "$when"
        fi
    done
    echo "  $STATUS"
}

# **A merge or a release needs a fresh pass of every stage on its own build.** A CARRIED result is a development-loop
# shortcut — its inputs were unchanged, which is a judgment about what each stage exercises, not a run — so a row that
# says `carried`, or a pass filed against another build, is refused. Decided in `Tools/e2e-inputs.py release-gate`.
require_fresh() {
    local python
    python=$(Tools/python.sh) || exit 1
    "$python" Tools/e2e-inputs.py release-gate "$STATUS" "${1:?usage: e2e-status.sh require-fresh <build>}"
}

case ${1:-} in
    record) shift; record "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    show) show ;;
    require-fresh) shift; require_fresh "${1:-}" ;;
    *) echo "usage: e2e-status.sh record|show|require-fresh" >&2; exit 64 ;;
esac
