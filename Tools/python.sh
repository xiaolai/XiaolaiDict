#!/bin/bash
# python.sh — prints the Python the tool suites run on: `python3` where it is 3.10 or later, otherwise the newest
# versioned `python3.N` on PATH that is. Nothing and a failure, with the reason, where there is none.
#
# **Chosen by version, never by PATH order alone** (2026-10-10): the suites need 3.10 (`zip(strict=)`, and the WAL
# behaviour of the `sqlite3` module the ledger tests drive). `make test-tools` ran whichever `python3` came first; a
# Homebrew upgrade left its new Python unlinked, macOS's 3.9.6 answered, and three tests failed on the interpreter rather
# than the code. `Tools/tests/test_python_choice.py` holds this to stand-ins.
supported() { "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; }

if path=$(command -v python3) && supported "$path"; then
    echo "$path"
    exit 0
fi
for ((minor = 30; minor >= 10; minor--)); do
    if path=$(command -v "python3.$minor") && supported "$path"; then
        echo "$path"
        exit 0
    fi
done
echo "python.sh: no Python 3.10 or later on PATH (python3 is $(python3 --version 2>&1 || echo absent))" >&2
exit 1
