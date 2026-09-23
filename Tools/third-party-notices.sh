#!/bin/bash
# The licences of the open-source packages this build links, gathered into the one file the app
# carries — because an MIT licence asks that its notice go with every copy of the software, and
# Apache-2.0 asks the same of its NOTICE. Statically linked, those packages are inside the two XPC
# services' binaries with nothing to say they are there; this file is what says it.
#
# Generated, never hand-written: the list follows `Package.resolved` through SwiftPM's own record of
# where each package was checked out, so a dependency added, removed or moved cannot leave the
# notices behind. A package whose checkout carries no licence file stops the build by name rather
# than being skipped — a missing notice is exactly the thing that must not pass quietly.
#
#   third-party-notices.sh <output-file>
set -euo pipefail

out=${1:-}
[ -n "$out" ] || { echo "usage: $0 <output-file>" >&2; exit 2; }

state=.build/workspace-state.json
[ -f "$state" ] || { echo "error: $state is missing — resolve the packages first" >&2; exit 1; }

# identity, where it came from, which version, and the directory it was checked out into. Sorted by
# identity so the same dependencies always produce the same bytes: this file is one of the bundle's
# inputs, and a file that reordered itself would rebuild and re-sign the app for nothing.
packages=$(python3 - "$state" <<'PY'
import json, sys

for dependency in sorted(json.load(open(sys.argv[1]))["object"]["dependencies"],
                         key=lambda d: d["packageRef"]["identity"]):
    reference = dependency["packageRef"]
    checkout = dependency["state"].get("checkoutState", {})
    # A package pinned to a commit rather than a release has no version; the revision is what
    # names it, and the short form is the one a person can compare against a repository page.
    version = checkout.get("version") or checkout.get("revision", "")[:12]
    print("\t".join([reference["identity"], reference["location"], version, dependency["subpath"]]))
PY
)
[ -n "$packages" ] || { echo "error: $state lists no dependencies" >&2; exit 1; }

rule() { printf '%s\n' '--------------------------------------------------------------------------------'; }

# Written to one side and moved into place, so an interrupted run leaves the previous file rather
# than half of this one.
work=$(mktemp "${TMPDIR:-/tmp}/xiaolaidict-notices.XXXXXX")
trap 'rm -f "$work"' EXIT

{
    cat <<'HEADER'
XiaolaiDict is built from the open-source packages listed below. Each one's licence, and any
notice it ships alongside it, is reproduced here in full.

Some of these packages are used only while building and are not part of the app you are
reading this in. They are listed anyway: which is which is not something this file can read
off the build, and a complete list is worth more than one that guesses.

HEADER
    while IFS=$'\t' read -r identity location version subpath; do
        directory=.build/checkouts/$subpath
        [ -d "$directory" ] || { echo "error: $identity is not checked out at $directory" >&2; exit 1; }
        licence=$(find "$directory" -maxdepth 1 -type f \
            \( -iname 'LICENSE' -o -iname 'LICENCE' -o -iname 'COPYING' \
               -o -iname 'LICENSE.*' -o -iname 'LICENCE.*' -o -iname 'COPYING.*' \) | sort | head -1)
        [ -n "$licence" ] || { echo "error: $identity carries no licence file in $directory" >&2; exit 1; }

        printf '================================================================================\n'
        printf '%s %s\n%s\n' "$identity" "$version" "$location"
        rule
        cat "$licence"
        # Apache-2.0 §4(d) asks for the NOTICE itself, not only the licence, wherever the package
        # ships one. Two of these do.
        for notice in "$directory"/NOTICE "$directory"/NOTICE.*; do
            [ -f "$notice" ] || continue
            printf '\n%s\n' "NOTICE — $identity"
            rule
            cat "$notice"
        done
        printf '\n'
    done <<<"$packages"
} > "$work"

mkdir -p "$(dirname "$out")"
mv "$work" "$out"
trap - EXIT
