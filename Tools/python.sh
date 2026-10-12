#!/bin/bash
# python.sh — the Python the tool code runs on: `python3` where it is 3.12 or later, otherwise the newest versioned
# `python3.N` on PATH that is. Run, it prints the path, or fails naming what it found; sourced, it defines
# `xiaolaidict_python`, which does the same — `e2e.sh` sources it here and sends it to the E2E Mac, where the remote
# scripts' `python3` is that choice too.
#
# **Chosen by version, never by PATH order alone** (2026-10-10). A Homebrew upgrade on both Macs that morning installed
# Python 3.14 and left no `python3` link, so macOS's 3.9.6 answered: three tool tests failed on the interpreter rather
# than the code (`zip(strict=)`, the `sqlite3` module's WAL behaviour), and the panel stage's validator — a multi-line
# f-string, legal from 3.12 (PEP 701) — no longer compiled. 3.12 is the newest syntax any of this code uses.
# `Tools/tests/test_python_choice.py` holds this to stand-ins.
xiaolaidict_python() {
    local path minor
    _xiaolaidict_supported() { "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; }
    if path=$(command -v python3) && _xiaolaidict_supported "$path"; then
        echo "$path"
        return 0
    fi
    for ((minor = 30; minor >= 12; minor--)); do
        if path=$(command -v "python3.$minor") && _xiaolaidict_supported "$path"; then
            echo "$path"
            return 0
        fi
    done
    echo "python.sh: no Python 3.12 or later on PATH (python3 is $(python3 --version 2>&1 || echo absent))" >&2
    return 1
}

# Run, not sourced: answer.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    xiaolaidict_python
fi
