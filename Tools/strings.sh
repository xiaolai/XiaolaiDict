#!/bin/bash
# Extracts every localizable string from the source and syncs it into the catalog.
#
# `swiftc -emit-localized-strings` writes one .stringsdata file per source file, holding the keys
# passed to APIs that localize — `String(localized:)`, and every SwiftUI initialiser that takes a
# `LocalizedStringKey`, which is most of them. `xcstringstool sync` merges those into the catalog,
# adding what is new and marking stale what the source no longer says. The catalog is the file a
# translator is given; nothing is hand-edited into it.
#
# Extraction runs through `swift build` because the compiler needs the module it is compiling
# against — invoked directly on the files it fails with "no such module XiaolaiDictCore". It builds
# into a scratch path of its own, so every run compiles every file: against the ordinary build
# directory an up-to-date target is not recompiled, emits no .stringsdata, and a sync against none
# would mark every string in the catalog stale.
#
# Strings that are not prose must never arrive here. A composed label is `Text(verbatim:)` and a
# number is `Text(value, format: .number)`, which also gets the reader's own digits and grouping.
set -euo pipefail
cd "$(dirname "$0")/.."

readonly CATALOG=Strings/Localizable.xcstrings
# Absolute: the compiler resolves this path per target, from a working directory of its own, and a
# relative one silently writes nothing where this script then looks.
readonly EXTRACTED=$PWD/.build/localized-strings

# Both are cleared: a kept scratch path recompiles only what changed, and a sync against one
# file's strings marks every other string in the catalog stale. Measured — a one-file rebuild took
# the catalog from 117 strings to 42.
rm -rf "$EXTRACTED" .build/strings
mkdir -p "$EXTRACTED" "$(dirname "$CATALOG")"
[ -e "$CATALOG" ] || printf '{\n  "sourceLanguage" : "en",\n  "strings" : {},\n  "version" : "1.0"\n}\n' > "$CATALOG"

# The app's product only — which is every module the reader sees text from: the app, the view layer
# and the core. The two services carry no reader-facing text, and building the model service would
# compile all of MLX again into this scratch path, minutes of it, to extract nothing.
swift build --scratch-path .build/strings --product XiaolaiDict \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$EXTRACTED" > /dev/null

# Two guards, because a partial extraction silently empties the catalog. `.stringsdata` files are
# named after the source file, and this package has two `main.swift` and two `PinnedNote.swift`, so
# counting them against the sources can never be exact — the count catches only the total failure.
count=$(find "$EXTRACTED" -name '*.stringsdata' | wc -l | tr -d ' ')
if [ "$count" -eq 0 ]; then
    echo "error: the build produced no .stringsdata, so nothing was extracted; the catalog is left alone." >&2
    exit 1
fi

# The one that matters: sync into a copy and look at what it would do. A build that recompiled only
# part of the package takes strings out wholesale — measured, a one-file rebuild would have gone
# from 117 strings to 42 — while a real deletion removes a few. Losing more than a fifth is refused
# unless the caller says it is meant.
before=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['strings']))" "$CATALOG")
candidate=$(mktemp -d)/Localizable.xcstrings
cp "$CATALOG" "$candidate"
xcrun xcstringstool sync "$candidate" --stringsdata "$EXTRACTED"/*.stringsdata
after=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['strings']))" "$candidate")

if [ "$before" -gt 0 ] && [ $((after * 5)) -lt $((before * 4)) ] && [ "${ALLOW_SHRINK:-}" != "1" ]; then
    echo "error: the sync would take the catalog from $before strings to $after, which is more than a" >&2
    echo "       deletion and looks like a partial extraction. Nothing was written." >&2
    echo "       If the strings really are gone, run: ALLOW_SHRINK=1 make strings" >&2
    exit 1
fi
cp "$candidate" "$CATALOG"
stale=$(python3 -c "
import json, sys
strings = json.load(open(sys.argv[1]))['strings']
print(sum(1 for v in strings.values() if v.get('extractionState') == 'stale'))" "$CATALOG")

echo "strings: $after in $CATALOG (was $before), from $count source files; $stale marked stale"
