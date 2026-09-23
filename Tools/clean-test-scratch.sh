#!/bin/bash
# Removes the scratch directories test runs left behind, then checks they stay gone.
#
# Every directory a test makes now comes from `Tests/Support/TemporaryDirectory.swift`, which
# removes its own when the test that made it is done — so a current run leaves none. This is for
# the backlog: **16,363 of them** had accumulated by 2026-09-23, one per store or ledger fixture
# per test per run since the project began, because nothing owned them. It also catches the one
# case the owner cannot: a process killed mid-test never runs its `deinit`.
#
# Only this project's own names, only under the system's temporary directory, and only ones
# nothing has touched for an hour — a directory a *running* test is using is left alone.
set -euo pipefail
# The separator is written here, not assumed to be on the end of TMPDIR. macOS sets TMPDIR with a
# trailing slash and a bare `${TMPDIR:-/tmp}` reads correctly because of it — but with TMPDIR unset
# the glob became `/tmpxiaolaidict-*`, which matches nothing, so the sweep silently did nothing on
# exactly the machine that has no TMPDIR. `Tools/third-party-notices.sh` writes it this way too.
scratch=${TMPDIR:-/tmp}
shopt -s nullglob

removed=()
for directory in "$scratch"/xiaolaidict-*; do
    [ -d "$directory" ] || continue
    # `-mmin +60`: still in use is still recent. A run that takes an hour inside one directory
    # would be a run with much larger problems than this.
    [ -z "$(find "$directory" -maxdepth 0 -mmin -60)" ] || continue
    # A test about unreadable stores leaves 000 behind, which `rm -rf` cannot descend into.
    chmod -R u+rwX "$directory" 2>/dev/null || true
    rm -rf "$directory"
    removed+=("$directory")
done

# **The ones this run removed, by name.** Asking again for old directories could not answer the
# question in this script's own first line: a directory put back after its removal is a minute old,
# never an hour, so the second sweep's age filter excluded the one thing it exists to find — and a
# directory still in use by another run, correctly skipped above, would have been counted as one
# that came back. Named, both cases read right.
back=()
for directory in ${removed[@]+"${removed[@]}"}; do
    [ ! -e "$directory" ] || back+=("$directory")
done
if [ "${#back[@]}" -ne 0 ]; then
    echo "test scratch: removed ${#removed[@]}, but ${#back[@]} came back — something is still writing:" >&2
    printf '  %s\n' "${back[@]}" >&2
    exit 1
fi
count=${#removed[@]}
echo "test scratch: removed $count director$([ "$count" = 1 ] && echo y || echo ies) left by earlier runs"
