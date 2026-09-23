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
scratch=${TMPDIR:-/tmp}
shopt -s nullglob

removed=0
for directory in "$scratch"xiaolaidict-*; do
    [ -d "$directory" ] || continue
    # `-mmin +60`: still in use is still recent. A run that takes an hour inside one directory
    # would be a run with much larger problems than this.
    [ -z "$(find "$directory" -maxdepth 0 -mmin -60)" ] || continue
    # A test about unreadable stores leaves 000 behind, which `rm -rf` cannot descend into.
    chmod -R u+rwX "$directory" 2>/dev/null || true
    rm -rf "$directory"
    removed=$((removed + 1))
done

left=0
for directory in "$scratch"xiaolaidict-*; do
    [ -d "$directory" ] || continue
    [ -z "$(find "$directory" -maxdepth 0 -mmin -60)" ] || continue
    left=$((left + 1))
done
if [ "$left" -ne 0 ]; then
    echo "test scratch: removed $removed, but $left came back — something is still writing" >&2
    exit 1
fi
echo "test scratch: removed $removed director$([ "$removed" = 1 ] && echo y || echo ies) left by earlier runs"
