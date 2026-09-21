#!/bin/bash
# Removes the defaults suites a finished test run left behind, then checks they stay gone.
#
# Every suite a test makes is named `xiaolaidict.test.<pid>.<uuid>` (Tests/Support/
# TemporaryDefaults.swift). A test process removes its own at exit, but only as far as it can:
# cfprefsd writes asynchronously, and in a full parallel run a handful of files land after the
# process has deleted them — measured at 4 per run, and 0 when the same tests run alone. Once
# the process is gone nothing writes for it any more, so deleting what it left is final. This
# runs after `swift test` returns, when every test process has exited.
#
# A suite whose process is still running belongs to another run and is left alone.
set -euo pipefail
prefs="$HOME/Library/Preferences"
shopt -s nullglob

abandoned() {
    local file name rest pid
    for file in "$prefs"/xiaolaidict.test.*.plist; do
        name=${file##*/}; rest=${name#xiaolaidict.test.}; pid=${rest%%.*}
        if [[ $pid =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then echo "$file"; fi
    done
}

sleep 1   # the last test process's own writes, still in flight
removed=0
while IFS= read -r file; do rm -f -- "$file"; removed=$((removed + 1)); done < <(abandoned)

# The deletion is only final if nothing puts the files back; that is the premise, so check it.
sleep 3
back=$(abandoned | wc -l | tr -d ' ')
if (( back > 0 )); then
    echo "error: $back defaults suite(s) came back after the test processes had exited:" >&2
    abandoned | head -5 | sed 's/^/  /' >&2
    exit 1
fi
echo "test defaults: removed $removed suite(s) the test processes left, none came back"
