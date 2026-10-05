#!/bin/bash
# Holds one directory of Swift to its boundary, with the toolchain as the authority — ADR-0047.
#
#   Tools/portability.sh --imports <module,...> <directory> [swiftc flag ...]
#   Tools/portability.sh --list-imports <directory> [--siblings <module,...>]
#   Tools/portability.sh --list-conditions <directory>
#
# **`--list-conditions` prints every `#if` and `#elseif` condition under the directory, as the Swift parser
# reads it** — `<file>\t<directive>\t<condition>`, one a line, sorted — for
# `ModuleBoundaryTests.everyConditionIsOneTheBuildConfigurationsDecide` to judge (the final closing pass,
# finding 3). The import list below is asked in the three configurations and with every sibling importable
# and not, which decides a define and an all-or-nothing `canImport` of a sibling; it cannot decide another
# package's `canImport(MLX)`, or `canImport(A) && !canImport(B)` of two siblings, both true in some
# incremental build — and the import behind either went unlisted. So the verdict stops depending on what is
# importable: a condition is judged as text the parser bounded, never evaluated. A condition the parser does
# not bound — a postfix `#if` — prints empty, and an empty condition is refused. Files are parsed only where
# their text holds `#if` or `#elseif`: a directive is one token spelled that way, so a file without those
# bytes holds none, and the parser is not paid for the rest of the tree.
#
# **`--list-imports` prints what the compiler lists the directory importing, for macOS 27, one module a
# line, sorted** — the list `ModuleBoundaryTests.theCompilerHoldsEveryTargetToItsBoundary` judges every
# target's table and declared dependencies by (ADR-0047, addendum of 2026-10-05). Asked in every
# configuration a real build compiles under — `swift test` (`DEBUG`), a development bundle
# (`XIAOLAIDICT_CAPTURE_INSTRUMENTS`) and a release, all `SWIFT_PACKAGE` — so an import any of them
# compiles is listed, and one in a clause none compiles binds nothing in any build. Each module named by
# `--siblings` is made importable for a second pass of each, because `canImport` of a sibling is true in
# an incremental build, where its module is already in `.build`, and false in a clean one. The compiler
# lists an import without loading the module, so no sibling has to be built first: about 0.6 s a target.
# As in the gate, it lists explicit imports only, and a module rather than a submodule
# (`import Carbon.HIToolbox` is `Carbon`). It refuses a directory with no Swift and a file the compiler
# cannot read, printing nothing then. `Tools/tests/test_portability.py` holds the configurations to the
# defines the Makefile, Tools and the manifest pass.
#
# Without `--list-imports`, it is the gate:
#
# `make portability` runs it over Sources/ReviewKit with `--imports Foundation` and -DSWIFT_PACKAGE, the
# condition every real build compiles under, and `test-swift` depends on that target, so `make`,
# `make run`, `make test` and `make release` all run it. Three questions, each answered by the tools
# that compile Swift rather than by a reading of its text:
#
# 1. **Does any file hold conditional compilation?** Asked of swift-syntax, the toolchain's own Swift
#    parser, through `swift-format`'s token stream — once, before anything is compiled. A directive is
#    a token to the parser however it is spelled or placed (after a `;`, between regex literals), and
#    text inside a string or a comment is not. The C++ frontend cannot be asked: since Swift 6 its AST
#    holds no `#if`, and `-dump-parse` drops every clause, active or not (measured, Swift 6.4). The
#    reader checks itself first on a control file holding a directive, so a toolchain whose debug
#    output changed shape refuses here instead of finding nothing. A string literal whose whole text is
#    a directive reads as one too, which refuses rather than passes.
# 2. **Does it typecheck alone, for iOS, watchOS, tvOS and macOS 27?** No module of this package is on
#    the search path, so a reference to `Ledger`, or an import of any sibling, fails here whatever a
#    stale module in `.build` would have let an incremental build get away with.
# 3. **What does it import, on each of those platforms?** `swiftc -emit-imported-modules` — the
#    compiler's own list, which reads a backticked name as the module it names and an import between
#    two regex literals as an import. It must be exactly `--imports`: anything else is a module the
#    boundary does not allow, and a module missing from it is a list that cannot be trusted. The
#    compiler reports only explicit imports — no implicit standard-library module, measured on Swift
#    6.4 for all four platforms — so nothing beyond the named set is pinned.
#
# It refuses, each loudly: no Swift files (a check over nothing passes), no `swift-format`, a platform SDK
# that is not installed (named), a file the parser cannot read, a directive, a platform the sources do
# not typecheck for, and an import set that is not the one named. Its controls are
# `Tools/tests/test_portability.py`, which plants into a copy and never into Sources.
set -euo pipefail

usage() {
    echo "usage: $0 --imports <module,...> <directory> [swiftc flag ...]" >&2
    echo "       $0 --list-imports <directory> [--siblings <module,...>]" >&2
    echo "       $0 --list-conditions <directory>" >&2
    exit 2
}
siblings=
if [ "${1:-}" = --list-conditions ]; then
    [ $# -eq 2 ] || usage
    mode=conditions
    directory=$2
elif [ "${1:-}" = --list-imports ]; then
    # The configurations are this script's, so there is no caller's flag for it to pass on.
    if [ $# -eq 2 ]; then :
    elif [ $# -eq 4 ] && [ "$3" = --siblings ] && [ -n "$4" ]; then siblings=$4
    else usage
    fi
    mode=list
    directory=$2
else
    [ $# -ge 3 ] && [ "$1" = --imports ] || usage
    mode=gate
    allowed=$(printf '%s' "$2" | tr ',' '\n' | sed '/^$/d' | sort -u)
    directory=$3
    shift 3
    [ -n "$allowed" ] || usage
fi
[ -d "$directory" ] || { echo "portability: $directory is not a directory" >&2; exit 1; }

# SDK : the OS in the target triple. Overridable only so the controls can name an SDK nobody installed.
platforms=${PORTABILITY_PLATFORMS:-"iphoneos:ios watchos:watchos appletvos:tvos macosx:macos"}
# The deployment version Package.swift names for macOS, held for every platform.
readonly deployment=27.0

# A module cache and scratch of its own, removed on every exit: a shared one could answer from a build
# of something else, and the per-user temporary directory is not this script's to fill.
cache=$(mktemp -d "${TMPDIR:-/tmp}/xiaolaidict-portability.XXXXXX")
trap 'rm -rf "$cache"' EXIT

# **Listed into a file whose producer's status is read**, never through `< <(find …)`: a process
# substitution's exit status reaches nobody, and `find` reports a directory it cannot enter and goes
# on — so a partial, non-empty list would pass the files it missed unread.
if ! find "$directory" -name '*.swift' -type f -print0 | sort -z > "$cache/files"; then
    echo "portability: could not list the Swift files under $directory, so some would go unchecked" >&2
    exit 1
fi
files=()
while IFS= read -r -d '' file; do files+=("$file"); done < "$cache/files"
if [ "${#files[@]}" -eq 0 ]; then
    echo "portability: no Swift files under $directory, so nothing would be checked" >&2
    exit 1
fi

# --- What a target imports, in every build that compiles it (--list-imports) -------------------------

if [ "$mode" = list ]; then
    # Each one a build this repository runs: `swift test`, a development bundle, a release
    # (Tools/build-bundle.sh builds both bundles `-c release`, and passes the define to the first).
    configurations=("-DSWIFT_PACKAGE -DDEBUG" "-DSWIFT_PACKAGE -DXIAOLAIDICT_CAPTURE_INSTRUMENTS" "-DSWIFT_PACKAGE")
    # The second pass's search path: every sibling an empty Clang module, which is all `canImport` asks for.
    if [ -n "$siblings" ]; then
        mkdir "$cache/siblings"
        : > "$cache/siblings/empty.h"
        for module in $(printf '%s' "$siblings" | tr ',' ' '); do
            # Written into a module map, so nothing but a module's name is let through.
            if ! printf '%s' "$module" | grep -Eqx '[A-Za-z_][A-Za-z0-9_]*'; then
                echo "portability: --siblings names '$module', which is not a module name" >&2
                exit 2
            fi
            printf 'module %s { header "empty.h" }\n' "$module" >> "$cache/siblings/module.modulemap"
        done
    fi
    # As SwiftPM parses it: a target with a `main.swift` is an executable's top-level code, and every
    # other file is a library's. Read wrong, `main.swift`'s first statement is an error and nothing lists.
    library=(-parse-as-library)
    for file in "${files[@]}"; do
        [ "$(basename "$file")" != main.swift ] || library=()
    done
    : > "$cache/imported.txt"
    for configuration in "${configurations[@]}"; do
        for importable in no ${siblings:+yes}; do
            search=()
            [ "$importable" = no ] || search=(-I "$cache/siblings")
            rm -f "$cache/listed.txt"
            # `$configuration` splits into its defines by design. `${a[@]+"${a[@]}"}` is an empty array
            # under `set -u` in bash 3.2, which calls a bare `"${a[@]}"` unbound.
            # shellcheck disable=SC2086
            if ! xcrun --sdk macosx swiftc -emit-imported-modules ${library[@]+"${library[@]}"} \
                    -module-name "$(basename "$directory")" -swift-version 6 -module-cache-path "$cache" \
                    -target "arm64-apple-macos$deployment" $configuration ${search[@]+"${search[@]}"} \
                    "${files[@]}" -o "$cache/listed.txt"; then
                echo "portability: the compiler could not list what $directory imports" \
                     "($configuration$([ "$importable" = no ] || echo ', siblings importable'))" >&2
                exit 1
            fi
            # A run that said nothing and wrote nothing would read as a target importing nothing.
            if [ ! -f "$cache/listed.txt" ]; then
                echo "portability: the compiler exited 0 and wrote no list for $directory" >&2
                exit 1
            fi
            cat "$cache/listed.txt" >> "$cache/imported.txt"
        done
    done
    sort -u "$cache/imported.txt"
    exit 0
fi

# --- The parser: swift-syntax, through swift-format's token stream ------------------------------------

# Overridable only so a control can hand the gate a reader that sees nothing.
formatter=${PORTABILITY_SWIFT_FORMAT:-$(xcrun --find swift-format 2>/dev/null || true)}
if [ -z "$formatter" ]; then
    echo "portability: swift-format is not in this toolchain, so no parser can be asked for directives" >&2
    exit 1
fi

# **Unique to this run, appended to every copy the parser reads** — what proves a stream is one file's and
# nothing else's (`sole_stream`).
sentinel="PORTABILITY_SENTINEL_$$_${RANDOM}${RANDOM}"
mkdir "$cache/parse"

# token_stream <file> <stream>: the parser's token stream for <file>, written to <stream>.
#
# **Formatted in place, in a copy.** Formatted to standard output, the source shares the stream it is dumped
# beside, and lands wherever the dump's buffer is flushed — measured mid-token, at byte 24,576 of one dump —
# so the very line a directive is read from could be split and the directive read as nothing.
token_stream() {
    local copy
    copy="$cache/parse/$(basename "$1")"
    cp "$1" "$copy"
    printf '\n// %s\n' "$sentinel" >> "$copy"
    if ! "$formatter" format --in-place --debug-dump-token-stream "$copy" > "$2" 2>"$cache/parse-errors.txt"; then
        echo "portability: the Swift parser could not read $1:" >&2
        cat "$cache/parse-errors.txt" >&2
        return 1
    fi
}

# sole_stream <stream> <file>: refuses a stream that is not <file>'s token stream alone. The sentinel comment
# is in it exactly once — as a comment token's text. None is not this file's stream; two is the formatted
# source written into it as well.
sole_stream() {
    local seen
    seen=$(grep -c -F -- "$sentinel" "$1" || true)
    if [ "$seen" != 1 ]; then
        echo "portability: the Swift parser's token stream for $2 holds its sentinel $seen times, not once," >&2
        echo "             so it is not that file's stream alone and cannot be read for directives" >&2
        return 1
    fi
}

directives() {  # directives <stream>: every directive token in it, one a line
    sed -nE 's/^[[:space:]]*\[SYNTAX "(#if|#elseif|#else|#endif)" Length:.*/\1/p' "$1"
}

# conditions <stream>: every `#if` and `#elseif` in it, `<directive>\t<condition>`, the condition its tokens
# as the parser reads them — a space round `&&` and `||`, after `,` and `:`, and nowhere else.
#
# **Bounded by swift-format's own markers**: it opens a condition with `disableBreaking` before the
# condition's first token and closes it with `enableBreaking` after its last, nesting. A postfix `#if` carries
# no such markers, so its condition cannot be told from the body that follows: it prints empty, which is
# refused. A string segment whose whole text is a directive's spelling reads as a directive with no bound,
# which refuses rather than passes.
conditions() {
    awk '
        function open_directive(keyword) { inside = 1; state = "start"; depth = 0; directive = keyword; cond = "" }
        match($0, /^[[:space:]]*\[SYNTAX "#(if|elseif)" Length: [0-9]+ Idx: [0-9]+\]$/) {
            line = $0; sub(/^[[:space:]]*\[SYNTAX "/, "", line); sub(/".*$/, "", line)
            open_directive(line); next
        }
        inside && state == "start" && /^[[:space:]]*\[SPACE / { next }
        inside && state == "start" {
            if ($0 ~ /^[[:space:]]*\[PRINTER CONTROL Kind: disableBreaking\(allowDiscretionary: true\)/) {
                state = "condition"; depth = 1; next
            }
            printf "%s\t\n", directive; inside = 0
        }
        inside && /^[[:space:]]*\[PRINTER CONTROL Kind: disableBreaking/ { depth++; next }
        inside && /^[[:space:]]*\[PRINTER CONTROL Kind: enableBreaking/ {
            if (--depth == 0) { printf "%s\t%s\n", directive, cond; inside = 0 }
            next
        }
        inside && /^[[:space:]]*\[SYNTAX "/ {
            token = $0
            sub(/^[[:space:]]*\[SYNTAX "/, "", token); sub(/" Length: [0-9]+ Idx: [0-9]+\]$/, "", token)
            if (token == "&&" || token == "||") cond = cond " " token " "
            else if (token == "," || token == ":") cond = cond token " "
            else cond = cond token
        }
        END { if (inside) printf "%s\t\n", directive }
    ' "$1"
}

# **The reader checks itself first**, on a control holding a directive and a condition it must read whole —
# so a toolchain whose debug output changed shape refuses here instead of finding nothing.
printf '#if canImport(PORTABILITY_CONTROL) && !DEBUG\nlet control = 1\n#endif\n' > "$cache/Control.swift"
token_stream "$cache/Control.swift" "$cache/control-stream.txt" || exit 1
if [ "$(directives "$cache/control-stream.txt" | tr '\n' ' ')" != "#if #endif " ]; then
    echo "portability: the directive reader found no directive in its own control, so it cannot be" >&2
    echo "             trusted to find one in $directory — has swift-format's token stream changed shape?" >&2
    exit 1
fi
sole_stream "$cache/control-stream.txt" "its own control" || exit 1
if [ "$(conditions "$cache/control-stream.txt")" != "$(printf '#if\tcanImport(PORTABILITY_CONTROL) && !DEBUG')" ]; then
    echo "portability: the condition reader did not read its own control's condition whole, so it cannot be" >&2
    echo "             trusted to read one in $directory — has swift-format's token stream changed shape?" >&2
    exit 1
fi

# --- Every condition, as the parser reads it (--list-conditions) --------------------------------------

if [ "$mode" = conditions ]; then
    : > "$cache/conditions.txt"
    for file in "${files[@]}"; do
        # Exit 1 is "no match"; 2 is a file grep could not read, which must not read as one without a `#if`.
        status=0
        grep -q -F -e '#if' -e '#elseif' -- "$file" || status=$?
        if [ "$status" -eq 1 ]; then continue; fi
        if [ "$status" -ne 0 ]; then
            echo "portability: could not read $file, so its conditions would go unchecked" >&2
            exit 1
        fi
        token_stream "$file" "$cache/stream.txt" || exit 1
        sole_stream "$cache/stream.txt" "$file" || exit 1
        relative=${file#"$directory"/}
        conditions "$cache/stream.txt" | while IFS= read -r line; do
            printf '%s\t%s\n' "$relative" "$line"
        done >> "$cache/conditions.txt"
    done
    LC_ALL=C sort "$cache/conditions.txt"
    exit 0
fi

# --- 1. Conditional compilation, by the parser -------------------------------------------------------

conditional=0
for file in "${files[@]}"; do
    token_stream "$file" "$cache/stream.txt" || exit 1
    sole_stream "$cache/stream.txt" "$file" || exit 1
    found=$(directives "$cache/stream.txt")
    if [ -n "$found" ]; then
        echo "portability: $file holds conditional compilation ($(printf '%s' "$found" | tr '\n' ' ' | sed 's/ $//')):" >&2
        echo "             a second build whose conditions this check cannot match (ADR-0047)" >&2
        conditional=1
    fi
done
[ "$conditional" -eq 0 ] || exit 1
echo "portability: no conditional compilation, ${#files[@]} files"

# --- 2 and 3. Every platform: typechecks alone, and imports exactly what is allowed -------------------

for platform in $platforms; do
    sdk=${platform%%:*}
    os=${platform#*:}
    if ! xcrun --sdk "$sdk" --show-sdk-path >/dev/null 2>&1; then
        echo "portability: the $sdk SDK is not installed. ReviewKit is checked for iOS, watchOS, tvOS and" >&2
        echo "             macOS on every build; add the $os platform in Xcode > Settings > Components." >&2
        exit 1
    fi
    # As SwiftPM compiles a library target: its module name, library parsing, Swift 6, warnings as
    # errors (Package.swift sets that for every target). The caller adds the defines.
    common=(-parse-as-library -module-name "$(basename "$directory")" -swift-version 6
            -module-cache-path "$cache" -target "arm64-apple-$os$deployment")
    if ! xcrun --sdk "$sdk" swiftc -typecheck -warnings-as-errors "${common[@]}" "$@" "${files[@]}"; then
        echo "portability: $directory does not typecheck for $os $deployment" >&2
        exit 1
    fi
    imported="$cache/imports-$os.txt"
    if ! xcrun --sdk "$sdk" swiftc -emit-imported-modules "${common[@]}" "$@" "${files[@]}" -o "$imported"; then
        echo "portability: the compiler could not list what $directory imports for $os" >&2
        exit 1
    fi
    actual=$(sort -u "$imported")
    if [ "$actual" != "$allowed" ]; then
        for module in $(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$allowed")); do
            echo "portability: $directory imports $module on $os, and may import only: $(echo $allowed)" >&2
        done
        for module in $(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$allowed")); do
            echo "portability: the compiler reports no import of $module on $os — a list that lost a" >&2
            echo "             module cannot be trusted to have found the rest" >&2
        done
        exit 1
    fi
    echo "portability: $os $deployment, ${#files[@]} files, imports $(echo $allowed)"
done
