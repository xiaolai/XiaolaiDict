#!/bin/bash
# Clears the build cache when the Metal toolchain's cryptex mount has moved.
#
# `metal` lives on a cryptex whose directory name carries a random suffix —
# `…MobileAsset.MetalToolchain-v27.1.266.1.Apk4m6/…` — and that suffix changes when the volume
# remounts. Xcode's build cache records the absolute path, so the next build dies with "unable to
# spawn process '…/metal' (No such file or directory)": zero `Test run with` lines and exit 1, a
# build failure wearing a test failure's clothes. `touch Package.swift` does not help, because a
# re-plan re-reads the same cache. See ADR-0026.
#
# This ran as a hand-typed `rm -rf` twice, and the second time the path in the ADR was wrong — there
# are two `XCBuildData` directories and the *Release* Metal directory holds the id as well as Debug.
# So the holders are **found**, never listed: a hardcoded list is what failed.
#
#   metal-cache-guard.sh [build-root] [metal-path]
#
# Both optional — `.build` and `xcrun -f metal`. They are arguments so the Python suite can drive
# this against a fixture tree without a real cryptex.
set -uo pipefail

root="${1:-.build}"
metal="${2:-$(xcrun -f metal 2>/dev/null || true)}"

# Nothing built yet, or no Metal toolchain on this machine: not this script's business either way.
[ -d "$root" ] || exit 0
[ -n "$metal" ] || exit 0

# `-a` matters more than it looks: the cache files are msgpack, and on a binary file `grep -o`
# prints "Binary file … matches" rather than the match. That line equals no id, so **every**
# directory read as stale and the guard deleted a current cache on every run — measured here before
# it shipped. Treating the input as text is what makes `-o` mean what it says.
id_of() { printf '%s\n' "$1" | grep -ao 'MetalToolchain-v[^/]*' | head -1; }

current="$(id_of "$metal")"
# A metal path with no cryptex component at all — a toolchain installed somewhere else. Nothing to
# compare against, so nothing to clear.
[ -n "$current" ] || exit 0

# Cheap prefilter by name, then the grep decides. A directory is only removed because it actually
# holds an id that is not the current one.
stale_dirs=()
while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    found="$(grep -arho 'MetalToolchain-v[^/]*' "$dir" 2>/dev/null | sort -u)"
    [ -n "$found" ] || continue
    if printf '%s\n' "$found" | grep -qv "^${current}$"; then
        stale_dirs+=("$dir")
    fi
done < <(find "$root" -type d \( -name XCBuildData -o -name Metal \) 2>/dev/null)

[ "${#stale_dirs[@]}" -gt 0 ] || exit 0

echo "metal cache: the toolchain moved to ${current}; clearing ${#stale_dirs[@]} stale director$([ "${#stale_dirs[@]}" -eq 1 ] && echo y || echo ies)"
for dir in "${stale_dirs[@]}"; do
    # Belt and braces before an `rm -rf`: inside the build root, and not the build root itself.
    case "$dir" in
        "$root"/*) ;;
        *) echo "metal cache: refusing to remove '$dir' — outside '$root'" >&2; exit 1 ;;
    esac
    echo "  $dir"
    rm -rf "$dir"
done

# **The assertion, not just the fix.** The first hand-typed cure looked done and the very next build
# failed identically, because a holder had been missed. If one survives, say so rather than letting
# the build discover it.
survivors="$(find "$root" \( -name '*.dat' -o -name '*.xcbuilddata' \) -print0 2>/dev/null \
    | xargs -0 grep -alo 'MetalToolchain-v[^/]*' 2>/dev/null \
    | xargs -I{} sh -c 'grep -ao "MetalToolchain-v[^/]*" "{}" | grep -qv "^'"$current"'$" && echo "{}"' 2>/dev/null)"
if [ -n "$survivors" ]; then
    echo "metal cache: a stale toolchain path SURVIVED in:" >&2
    printf '  %s\n' $survivors >&2
    echo "metal cache: the build will fail on it — widen the search in $0" >&2
    exit 1
fi
