#!/bin/bash
# Assembles, signs and publishes XiaolaiDict.app around the SwiftPM products. The Makefile is the menu;
# this is the transaction. Every step that must happen in order — and must not interleave with
# another build — runs here, under one lock.
#
#   build-bundle.sh build    bring .build/XiaolaiDict.app up to date
#   build-bundle.sh run      build, quit the running copy, publish, open it, and check it came up
#   build-bundle.sh icon     regenerate Resources/XiaolaiDict.icon and MenuBarIcon.svg from Tools/icon
#   build-bundle.sh clean    remove the bundle, staging and records (not SwiftPM's build cache)
#
# Environment:
#   XIAOLAIDICT_SIGN_ID       Developer ID Application identity (required; see the Makefile for why)
#   XIAOLAIDICT_BUILD_NUMBER  CFBundleVersion for a release: a positive integer from the release counter.
#                      Unset, a development build is numbered from the UTC clock.
#
# Much of this is carried over from the TYPE app's Makefile, where each guard was learned by a
# build that looked successful and was not.

set -euo pipefail
cd "$(dirname "$0")/.."

readonly APP_NAME=XiaolaiDict
readonly BUNDLE_ID=com.xiaolaidict
# The platform floor, in one place: the three plists declare it, `verify_bundle_metadata` holds them
# to it, and `actool` validates the icon against it. A mismatch here is an icon checked for a macOS
# the app does not ship to.
readonly MINIMUM_MACOS=27.0
readonly SERVICE=XiaolaiDictService
readonly SERVICE_ID=$BUNDLE_ID.DictionaryService
# The local model's service: its own process, so a GPU fault or an out-of-memory kill takes it and
# not the app, and so unloading is ending it.
readonly MODEL_SERVICE=XiaolaiDictModelService
readonly MODEL_SERVICE_ID=$BUNDLE_ID.ModelService
# MLX's Metal shaders, as the SwiftPM resource bundle MLX looks them up in. It is named because it
# is asserted for by name; **every** resource bundle the model product builds is carried across —
# swift-transformers' fallback tokenizer configs are read through `Bundle.module`, whose accessor
# traps rather than returning nil when its bundle is missing, and swift-crypto's carries a privacy
# manifest. A service that ships one bundle of three works until the day it reaches for another.
readonly METAL_BUNDLE=mlx-swift_Cmlx.bundle
# How many times a `codesign` call is attempted. Only a release's `--timestamp` can fail for a
# reason worth repeating — it is a request to Apple's server — so a development build, which signs
# offline, always succeeds or fails on the first. Five, the same as release.sh's notarisation retry.
readonly SIGN_TRIES=5
readonly CONFIG=release
readonly APP=.build/$APP_NAME.app
# Assembled here, and published by an atomic swap only when every check has passed: $APP is the
# previous good bundle or this one — never a half-built mixture that looks up to date.
readonly STAGE_ROOT=.build/stage
readonly STAGE=$STAGE_ROOT/$APP_NAME.app
readonly XPC_PATH=Contents/XPCServices/$SERVICE.xpc
readonly MODEL_XPC_PATH=Contents/XPCServices/$MODEL_SERVICE.xpc
# Where MLX finds its shaders: the service's own Contents/Resources, which is what SwiftPM's
# generated accessor reads (`Bundle.main.resourceURL`). One level up, in Contents/, the service
# starts, acquires the Metal device, and dies with no message on its first array (the MLX-in-XPC
# spike, S2) — which is why the metallib's place is asserted, not assumed.
readonly METALLIB_PATH=$MODEL_XPC_PATH/Contents/Resources/$METAL_BUNDLE/Contents/Resources/default.metallib
# What the published bundle was built from. Removed before publication and written after it, so a
# build interrupted in between leaves no record — and is rebuilt — rather than a false one.
readonly BUNDLE_DIGEST=.build/$APP_NAME.app.inputs-sha256
readonly ICON_DIGEST=.build/icon.inputs-sha256
# The bundle is built from this copy of Resources/, taken under the icon generator's own lock.
readonly RESOURCES=.build/resources
readonly LOCK=.build/bundle.lock
readonly CATALOG=Strings/Localizable.xcstrings
# What the About pane opens: every linked package's licence, gathered by `third-party-notices.sh`.
readonly NOTICES=ThirdPartyNotices.txt

fail() { echo "error: $*" >&2; exit 1; }
note() { echo "$*"; }

# Every resource bundle the build produced, one per line — the model service carries all of them.
# Read from the products directory rather than listed here, because the list grows with the model
# service's dependencies and a hand-kept copy is one that silently falls behind.
#
# **Filtered to the model service's own build graph**, not by a glob and not by the resolved
# packages. `make clean` keeps the build cache on purpose, and the products directory is shared by
# every product this package builds — so a bundle left behind by a dependency that has since been
# removed, or one belonging to a product the service does not link, would go on being copied into
# the XPC service and signed with this project's Developer ID, with nothing to say where it came
# from. SwiftPM writes the graph it is about to build to `.build/manifest.pif`; the service
# product's dependency closure in that file names exactly the bundle targets it can load. Filtering
# by `Package.resolved` instead admitted all thirteen pins, `swift-syntax` and
# `swift-argument-parser` among them, which the model service does not link at all.
readonly PIF=.build/manifest.pif

# The bundle targets in the model service's dependency closure, by name. Whether each one actually
# produced a bundle is a separate question, answered by the products directory: a target with no
# resources of its own writes none.
model_service_bundle_targets() {
    [ -f "$PIF" ] || { echo "$PIF is missing, so the model service's graph cannot be read" >&2; return 1; }
    python3 - "$PIF" "$MODEL_SERVICE-product" <<'GRAPH'
import json, sys

plan = json.load(open(sys.argv[1]))
targets = {target["contents"]["guid"]: target["contents"]
           for target in plan if target.get("type") == "target"}
roots = [target for target in targets.values() if target["name"] == sys.argv[2]]
if not roots:
    sys.exit(f"{sys.argv[2]} is not in the build plan")
seen, pending = set(), [target["guid"] for target in roots]
while pending:
    guid = pending.pop()
    if guid in seen or guid not in targets:
        continue
    seen.add(guid)
    for dependency in targets[guid].get("dependencies", []):
        pending.append(dependency["guid"] if isinstance(dependency, dict) else dependency)
for guid in sorted(seen):
    if targets[guid].get("productTypeIdentifier") == "com.apple.product-type.bundle":
        print(targets[guid]["name"])
GRAPH
}

# Resolved once per run, into a list and an array. `verify_bundle` asks for the bundles four times
# and `assemble` twice, and each answer otherwise costs a SwiftPM invocation and a pass over a
# seven-megabyte build plan. The array is what loops read: an unquoted expansion of the
# newline-separated list is pathname expansion as well as word splitting, so a bundle whose name
# held a glob character would expand to whatever happened to sit beside it.
PRODUCTS=""
BUNDLES=""
BUNDLE_LIST=()
resolve_products() {
    [ -z "$PRODUCTS" ] || return 0
    local products targets name
    # **`XIAOLAIDICT_PRODUCTS` is for the checks that exercise this script**, and for nothing else.
    # Verification is the one thing here that can be asked of a bundle without building it — and a
    # test that has to start SwiftPM to ask cannot run inside `swift test`, where SwiftPM is already
    # running. A build never sets it, so a build always asks the build.
    products=${XIAOLAIDICT_PRODUCTS:-$(swift build -c "$CONFIG" --show-bin-path)} || return 1
    targets=$(model_service_bundle_targets) || return 1
    # Matched whole-line against the graph's target names. Written with `grep -x` rather than a
    # `case` because bash 3.2 mis-parses a `case` nested inside a command substitution at run time,
    # while `bash -n` accepts it — a syntax error that only a run can find.
    BUNDLES=$(find "$products" -maxdepth 1 -name '*.bundle' -exec basename {} \; | sort \
        | while read -r name; do
            printf '%s\n' "$targets" | grep -qx -- "${name%.bundle}" && echo "$name"
        done)
    BUNDLE_LIST=()
    while IFS= read -r name; do [ -z "$name" ] || BUNDLE_LIST+=("$name"); done <<<"$BUNDLES"
    PRODUCTS=$products
}


# ---------------------------------------------------------------------------------------------
# One build at a time, across processes. `.NOTPARALLEL` orders recipes within one make; two makes
# in two terminals would still delete and sign the same stage. lockf holds a flock(2) lock, which
# the kernel releases when the process dies, so a killed build never leaves the lock behind.
if [ "${XIAOLAIDICT_BUNDLE_LOCKED:-}" != 1 ]; then
    command -v lockf >/dev/null || fail "lockf(1) is missing; it ships with macOS 15 and later"
    mkdir -p .build
    XIAOLAIDICT_BUNDLE_LOCKED=1 exec lockf -k -t 900 "$LOCK" "$0" "$@"
fi

# ---------------------------------------------------------------------------------------------
# Inputs, by content. A timestamp misses a file restored with an older date, a deleted source,
# and a changed setting; a digest of every input's name and bytes misses none of them. Settings
# are hashed as data, never spliced into shell code, so quotes in a path or identity are inert.

digest_files() {  # the NUL-separated file list on stdin, each file's name and contents
    sort -z | while IFS= read -r -d '' file; do
        printf '%s\0' "$file"
        shasum -a 256 < "$file"
    done
}

bundle_inputs_digest() {
    {
        # The development build number is a property of each build, not an input: hashing it would
        # rebuild every time. A release number is an input.
        printf '%s\0' "$CONFIG" "$BUNDLE_ID" "$XIAOLAIDICT_SIGN_ID" "${XIAOLAIDICT_BUILD_NUMBER:-}"
        find Sources Strings "$RESOURCES" Package.swift Makefile Tools/build-bundle.sh \
            Tools/third-party-notices.sh -type f -print0 | digest_files
        [ ! -f Package.resolved ] || printf 'Package.resolved\0' | digest_files
    } | shasum -a 256 | cut -d' ' -f1
}

icon_inputs_digest() {
    # Every input has to exist. `find` is run with stderr discarded, so a path that moved — as
    # design/icon did when it became Tools/icon — would drop silently out of the digest and the
    # icon would simply stop being rebuilt when its art changed. A missing input is a broken
    # script, not a smaller digest.
    local input
    for input in Tools/icon Tools/make-icon.py Resources/XiaolaiDict.icon Resources/MenuBarIcon.svg; do
        [ -e "$input" ] || fail "icon digest input is missing: $input"
    done
    # The outputs are inputs too: a hand-edited generated file is regenerated, not shipped.
    find Tools/icon Tools/make-icon.py Resources/XiaolaiDict.icon Resources/MenuBarIcon.svg -type f -print0 2>/dev/null \
        | { cat; [ ! -d Tools/makeicon ] || find Tools/makeicon -name '*.py' -type f -print0; } \
        | digest_files | shasum -a 256 | cut -d' ' -f1
}

# ---------------------------------------------------------------------------------------------
# The icon: generated from the designer's art, so the art — not a stale copy — is what ships.

verify_icon_outputs() {  # $1: a Resources directory
    local resources=$1
    [ -s "$resources/XiaolaiDict.icon/icon.json" ] || fail "there is no $resources/XiaolaiDict.icon/icon.json"
    [ -s "$resources/MenuBarIcon.svg" ] || fail "there is no $resources/MenuBarIcon.svg"
    xmllint --noout "$resources/MenuBarIcon.svg" || fail "$resources/MenuBarIcon.svg is not well-formed"
    # Every asset icon.json names must exist; an icon document pointing at nothing compiles to a
    # blank icon without a word from actool.
    python3 - "$resources/XiaolaiDict.icon" <<'PY' || fail "$resources/XiaolaiDict.icon names assets it does not contain"
import json, os, sys
def names(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "image-name": yield value
            else: yield from names(value)
    elif isinstance(node, list):
        for value in node: yield from names(value)
document = json.load(open(os.path.join(sys.argv[1], "icon.json")))
listed = list(names(document))
missing = [n for n in listed if not os.path.isfile(os.path.join(sys.argv[1], "Assets", n))]
if not listed or missing:
    sys.exit(f"assets named: {listed}; missing: {missing}")
PY
}

# A copy of Resources/ taken under the icon generator's own lock (an flock on the directory), after
# the generator's own recovery: a direct run of Tools/make-icon.py in another terminal may be part
# way through replacing the icon pair, and the bundle must be built from one consistent pair — this
# copy — not from files that can change beneath it.
snapshot_resources() {
    rm -rf "$RESOURCES.new"
    python3 - "$RESOURCES.new" <<'PY' || fail "could not take a consistent copy of Resources/"
import shutil, sys
from pathlib import Path
sys.path.insert(0, "Tools")
from makeicon.publish import locked, recover_locked
resources = Path("Resources")
with locked(resources):
    recover_locked(resources)
    shutil.copytree(resources, sys.argv[1], symlinks=True, ignore=shutil.ignore_patterns(".make-icon-*", ".DS_Store"))
PY
    rm -rf "$RESOURCES"
    mv "$RESOURCES.new" "$RESOURCES"
    verify_icon_outputs "$RESOURCES"
}

# The generator first — it repairs a pair an interrupted run left mixed, and brings stale outputs
# up to date with changed art — then its tests, one of which checks the outputs against a fresh
# generation. The other way round, that test fails on exactly the stale or mixed outputs the
# generator is about to fix, and the build could never get past it. The tests still gate what is
# published: a failure stops the build before a bundle is assembled, and with no digest recorded
# the next build regenerates and tests again.
generate_icon() {
    note "regenerating the icon from Tools/icon"
    python3 Tools/make-icon.py Tools/icon Resources
    # The whole Python suite, not a pattern matching the icon's own files: a glob that excluded the
    # others would quietly stop covering the next test file whose name happened to match it.
    python3 -m unittest discover -s Tools/tests >/dev/null 2>.build/icon-tests.log \
        || { cat .build/icon-tests.log; fail "the tool tests fail"; }
    icon_inputs_digest > "$ICON_DIGEST"
}

ensure_icon() {
    [ "$(cat "$ICON_DIGEST" 2>/dev/null)" = "$(icon_inputs_digest)" ] || generate_icon
}

# ---------------------------------------------------------------------------------------------
# Build numbers.

build_number() {
    # What the published bundle was numbered: a newer build must count up from it.
    local previous
    previous=$(plist_value "$APP/Contents/Info.plist" CFBundleVersion || true)
    [[ "$previous" =~ ^[0-9]+(\.[0-9]+)*$ ]] || previous=""
    if [ -n "${XIAOLAIDICT_BUILD_NUMBER:-}" ]; then
        [[ "$XIAOLAIDICT_BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]] \
            || fail "XIAOLAIDICT_BUILD_NUMBER must be a positive integer from the release counter, not '$XIAOLAIDICT_BUILD_NUMBER'"
        # Checked against a published release build only: that is the one this machine can
        # compare. Across machines, counting up is the release counter's job.
        #
        # The same number twice is refused because it would name two different builds — **unless
        # the inputs are the same too**, in which case it is one release being put back together.
        # That happens whenever a published release fails verification and is rebuilt: a damaged
        # file, a signature without its timestamp. Refusing it left a release that could be
        # neither reused nor rebuilt under its own number. The recorded digest is what tells the
        # two apart, and it is only consulted when the numbers are equal.
        if [[ "$previous" =~ ^[0-9]+$ ]] && ! version_newer "$XIAOLAIDICT_BUILD_NUMBER" "$previous" \
           && ! same_release_again "$previous"; then
            fail "XIAOLAIDICT_BUILD_NUMBER $XIAOLAIDICT_BUILD_NUMBER is not above the published release build's $previous"
        fi
        echo "$XIAOLAIDICT_BUILD_NUMBER"
    else
        # year.monthday.time in UTC: rises with every build whatever the branch, rebase or clone
        # depth — which a commit count does not. One `date` call, so no field crosses a second.
        # Never at or below the published bundle's, so a clock set back, or two builds in one
        # second, still count up.
        local year monthday time candidate
        read -r year monthday time <<<"$(date -u '+%Y %m%d %H%M%S')"
        candidate="$year.$((10#$monthday)).$((10#$time))"
        if [ -n "$previous" ] && ! version_newer "$candidate" "$previous"; then
            candidate=$(version_after "$previous")
        fi
        echo "$candidate"
    fi
}

same_release_again() {  # $1: the published build number; whether this rebuilds that very release
    [ "$XIAOLAIDICT_BUILD_NUMBER" = "$1" ] \
        && [ -f "$BUNDLE_DIGEST" ] \
        && [ "$(cat "$BUNDLE_DIGEST")" = "$(bundle_inputs_digest)" ]
}

version_newer() {  # whether $1 is newer than $2: dot-separated integers, field by field, missing = 0
    local newer older field count
    IFS=. read -r -a newer <<<"$1"
    IFS=. read -r -a older <<<"$2"
    count=$(( ${#newer[@]} > ${#older[@]} ? ${#newer[@]} : ${#older[@]} ))
    for (( field = 0; field < count; field++ )); do
        (( 10#${newer[field]:-0} > 10#${older[field]:-0} )) && return 0
        (( 10#${newer[field]:-0} < 10#${older[field]:-0} )) && return 1
    done
    return 1
}

version_after() {  # the smallest development number after $1: its third field counted up
    local fields
    IFS=. read -r -a fields <<<"$1"
    while [ "${#fields[@]}" -lt 3 ]; do fields+=(0); done
    echo "${fields[0]}.${fields[1]}.$((10#${fields[2]} + 1))"
}

# ---------------------------------------------------------------------------------------------
# Verification: run on the staged bundle before publication, and on the published one before it
# is called up to date — a nested file deleted or damaged since does not change any timestamp
# make can see.

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# Four questions, each its own function: is everything there, do the plists agree, are the parts
# signed as one, and — for a release — stamped by Apple's server. `verify_bundle` asks them in turn.
verify_required_files() {
    local bundle=$1 file executable built language
    # Executables by `-x`, not `-s`: a binary whose executable bit was lost is still a file with
    # bytes in it, and launchd cannot run it. Everything else only has to be there and non-empty.
    for executable in Contents/MacOS/$APP_NAME "$XPC_PATH/Contents/MacOS/$SERVICE" \
                      "$MODEL_XPC_PATH/Contents/MacOS/$MODEL_SERVICE"; do
        [ -x "$bundle/$executable" ] || { echo "not executable: $bundle/$executable"; return 1; }
    done
    for file in Contents/Info.plist Contents/Resources/Assets.car \
                Contents/Resources/MenuBarIcon.svg "Contents/Resources/$NOTICES" \
                "$XPC_PATH/Contents/Info.plist" \
                "$MODEL_XPC_PATH/Contents/Info.plist" "$METALLIB_PATH"; do
        [ -s "$bundle/$file" ] || { echo "missing: $bundle/$file"; return 1; }
    done
    # Every resource bundle the model product built has to be here, not only the one named above.
    local present
    resolve_products || return 1
    for built in ${BUNDLE_LIST[@]+"${BUNDLE_LIST[@]}"}; do
        [ -d "$bundle/$MODEL_XPC_PATH/Contents/Resources/$built" ] \
            || { echo "missing from the model service: $built"; return 1; }
    done
    # **And nothing else.** The check above only ever asked whether what the cache holds reached the
    # app; it could not see a bundle the app carries that this build did not produce — which is what
    # a stale cache entry becomes once it has been copied in. Asked of the bundle being verified,
    # because that is the thing being shipped.
    for present in $(cd "$bundle/$MODEL_XPC_PATH/Contents/Resources" 2>/dev/null \
        && find . -maxdepth 1 -name '*.bundle' -exec basename {} \; | sort); do
        case " ${BUNDLE_LIST[*]} " in
            *" $present "*) ;;
            *) echo "the model service carries $present, which this build did not produce"; return 1 ;;
        esac
    done
    # A translation that never reached the bundle is a reader still reading English.
    for language in $(catalog_languages); do
        [ -s "$bundle/Contents/Resources/$language.lproj/Localizable.strings" ] \
            || { echo "missing from the bundle: $language.lproj/Localizable.strings"; return 1; }
    done
}

verify_bundle_metadata() {
    local bundle=$1
    [ "$(plist_value "$bundle/Contents/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] \
        || { echo "the app's CFBundleIdentifier is not $BUNDLE_ID"; return 1; }
    [ "$(plist_value "$bundle/$XPC_PATH/Contents/Info.plist" CFBundleIdentifier)" = "$SERVICE_ID" ] \
        || { echo "the service's CFBundleIdentifier is not $SERVICE_ID"; return 1; }
    [ "$(plist_value "$bundle/$MODEL_XPC_PATH/Contents/Info.plist" CFBundleIdentifier)" = "$MODEL_SERVICE_ID" ] \
        || { echo "the model service's CFBundleIdentifier is not $MODEL_SERVICE_ID"; return 1; }
    [ "$(plist_value "$bundle/Contents/Info.plist" CFBundleIconName)" = "$APP_NAME" ] \
        || { echo "CFBundleIconName is not $APP_NAME"; return 1; }
    # One version declared in three tracked plists, with nothing else holding them together: edit
    # one and the app and its services ship different answers to "which XiaolaiDict is this?".
    # Asserted here rather than remembered.
    local app_version service_version model_version
    app_version=$(plist_value "$bundle/Contents/Info.plist" CFBundleShortVersionString)
    service_version=$(plist_value "$bundle/$XPC_PATH/Contents/Info.plist" CFBundleShortVersionString)
    model_version=$(plist_value "$bundle/$MODEL_XPC_PATH/Contents/Info.plist" CFBundleShortVersionString)
    [ -n "$app_version" ] && [ "$app_version" = "$service_version" ] && [ "$app_version" = "$model_version" ] \
        || { echo "app ($app_version), service ($service_version) and model service ($model_version) declare different versions"; return 1; }

    # **The keys a service needs to launch at all**, not only the one that names it. A wrong
    # `CFBundleExecutable` or a missing `XPCService` dictionary builds, signs, verifies and ships —
    # and then every lookup fails at runtime with nothing to say why, because launchd refuses the
    # service rather than the app.
    local path executable
    for path in "$XPC_PATH:$SERVICE:$SERVICE_ID" "$MODEL_XPC_PATH:$MODEL_SERVICE:$MODEL_SERVICE_ID"; do
        local xpc=${path%%:*} rest=${path#*:} name id
        name=${rest%%:*}; id=${rest#*:}
        executable=$(plist_value "$bundle/$xpc/Contents/Info.plist" CFBundleExecutable)
        [ "$executable" = "$name" ] \
            || { echo "$xpc declares CFBundleExecutable '$executable', not '$name'"; return 1; }
        [ -x "$bundle/$xpc/Contents/MacOS/$executable" ] \
            || { echo "$xpc names an executable it does not have: $executable"; return 1; }
        [ "$(plist_value "$bundle/$xpc/Contents/Info.plist" CFBundlePackageType)" = XPC! ] \
            || { echo "$xpc is not declared as an XPC service (CFBundlePackageType)"; return 1; }
        [ "$(plist_value "$bundle/$xpc/Contents/Info.plist" "XPCService:ServiceType")" = Application ] \
            || { echo "$xpc does not declare XPCService:ServiceType Application"; return 1; }
        [ "$(plist_value "$bundle/$xpc/Contents/Info.plist" LSMinimumSystemVersion)" = "$MINIMUM_MACOS" ] \
            || { echo "$xpc declares a different LSMinimumSystemVersion from $MINIMUM_MACOS"; return 1; }
        [ -n "$id" ] || return 1
    done
    [ "$(plist_value "$bundle/Contents/Info.plist" LSMinimumSystemVersion)" = "$MINIMUM_MACOS" ] \
        || { echo "the app declares a different LSMinimumSystemVersion from $MINIMUM_MACOS"; return 1; }
}

verify_signatures() {
    local bundle=$1 built
    codesign --verify --strict --deep "$bundle" || { echo "the signature does not verify"; return 1; }
    # **The resource bundles are inside the signed service, sealed by it.** One copied in after the
    # service was signed would fail the deep check above; one signed apart from it, or left
    # unsigned, fails this — the service's own seal must cover its shaders and its tokenizer
    # resources, and each must itself be a signed code object ("code object is not signed at all"
    # otherwise, S2).
    codesign --verify --strict "$bundle/$MODEL_XPC_PATH" || { echo "the model service's signature does not cover its contents"; return 1; }
    resolve_products || return 1
    for built in ${BUNDLE_LIST[@]+"${BUNDLE_LIST[@]}"}; do
        codesign --verify --strict "$bundle/$MODEL_XPC_PATH/Contents/Resources/$built" \
            || { echo "$built is not a signed code object"; return 1; }
    done
    # The service trusts only its own team, so a bundle whose parts disagree is one where every
    # lookup is refused at runtime. Checked here, where the cause is still visible.
    #
    # **Equal team identifiers are not enough.** Read alone, this passed for any other team's
    # signature and for `TeamIdentifier=not set`, which is what an ad-hoc signature reports — and an
    # ad-hoc build keeps none of the permission grants this project signs Developer ID for. So each
    # part must carry the *configured* identity's authority, and must not be ad hoc.
    #
    # The resource bundles are checked the same way: they are signed code objects inside the
    # service, and one carrying another signature is one the service loads at runtime.
    local part team authority parts=("$bundle" "$bundle/$XPC_PATH" "$bundle/$MODEL_XPC_PATH")
    local app_team_expected=""
    for built in ${BUNDLE_LIST[@]+"${BUNDLE_LIST[@]}"}; do
        parts+=("$bundle/$MODEL_XPC_PATH/Contents/Resources/$built")
    done
    for part in "${parts[@]}"; do
        local described
        described=$(codesign -dvvv "$part" 2>&1 || true)
        team=$(grep '^TeamIdentifier=' <<<"$described" | head -1)
        authority=$(grep '^Authority=' <<<"$described" | head -1)
        case $team in
            TeamIdentifier=|TeamIdentifier=not\ set|"")
                echo "$part carries no team identifier — an ad-hoc signature keeps no permission grant"; return 1 ;;
        esac
        [ "$team" = "$app_team_expected" ] || [ -z "${app_team_expected:-}" ] \
            || { echo "$part is signed by $team, not by the app's $app_team_expected"; return 1; }
        app_team_expected=$team
        # The identity this build was told to sign with, by name: `Developer ID Application: …`.
        grep -qF "${XIAOLAIDICT_SIGN_ID}" <<<"$authority" \
            || { echo "$part is signed by '$authority', not by '$XIAOLAIDICT_SIGN_ID'"; return 1; }
        grep -q '^CodeDirectory .*flags=0x10000(runtime)' <<<"$described" \
            || { echo "$part is not signed with the hardened runtime"; return 1; }
    done
}

# **`--timestamp` is a network call, so it fails the way network calls fail.** Apple's timestamp
# server is contacted once per code object, and a release signs five of them back to back. Measured
# 2026-09-25 on the first release ever attempted: `mlx-swift_Cmlx.bundle` took a timestamp, the very
# next object failed with *"A timestamp was expected but was not found"*, and the build died with
# two resource bundles left unsigned — the same signature re-applied by hand a minute later
# succeeded first try. So the failure is transient and retrying is the whole fix.
#
# This is the house pattern already: `release.sh` retries notarisation and stapling five times for
# exactly this reason, and the signing step was the one network-dependent part of a release with no
# retry at all. A development build passes `--timestamp=none`, contacts nobody, and so can never
# spend more than its first attempt.
#
# stdout silenced, stderr kept, so a failure says why. The last attempt's stderr is not swallowed:
# a genuinely bad identity or a malformed bundle must still fail loudly rather than after five
# silent tries.
sign_part() {  # $1: the timestamp option; $2: the code object to sign
    local stamp=$1 part=$2 attempt
    for (( attempt = 1; attempt <= SIGN_TRIES; attempt++ )); do
        if (( attempt == SIGN_TRIES )); then
            codesign --force --options runtime "$stamp" --sign "$XIAOLAIDICT_SIGN_ID" "$part" >/dev/null
            return
        fi
        codesign --force --options runtime "$stamp" --sign "$XIAOLAIDICT_SIGN_ID" "$part" >/dev/null 2>&1 && return
        note "signing $(basename "$part") failed on attempt $attempt of $SIGN_TRIES — retrying"
        sleep $(( attempt * 2 ))
    done
}

# **A release must carry a secure timestamp, and this is where that is enforced.** The up-to-date
# check compares input digests, and the signing mode is not an input — so without this a release
# could reuse a bundle signed with `--timestamp=none`, and notarisation would reject it after the
# upload. `Signed Time=` is the local clock; only `Timestamp=` is Apple's. Output captured, then
# matched, for the SIGPIPE reason given in `assemble`.
verify_release_timestamps() {
    local bundle=$1 part info built
    is_release || return 0
    local parts=("$bundle" "$bundle/$XPC_PATH" "$bundle/$MODEL_XPC_PATH")
    resolve_products || return 1
    for built in ${BUNDLE_LIST[@]+"${BUNDLE_LIST[@]}"}; do parts+=("$bundle/$MODEL_XPC_PATH/Contents/Resources/$built"); done
    for part in "${parts[@]}"; do
        info=$(codesign -dvvv "$part" 2>&1)
        grep -q '^Timestamp=' <<<"$info" || { echo "a release is signed without a secure timestamp: $part"; return 1; }
    done
}

# **Each XPC service links the subject it serves, and nothing else.**
#
# The dictionary service exists to be the blast-radius container for a private API whose failure
# mode is a segfault. Measured on 2026-09-26, before the module split, it was 2,184,944 bytes and
# linked libsqlite3, CryptoKit, FoundationModels, Carbon, CoreGraphics and CoreServices, carrying 124
# `Ledger` symbols, 55 `ModelDownloader`, 63 `RangeWriter`, 259 `HoverPolicy` and the whole LLM wire
# protocol — 443 `ModelReply`, 367 `ModelRequest`. It calls none of it. The model service was the
# mirror image: 237 `DictionaryEntry` symbols, 275 `LookupFailure`, and libsqlite3.
#
# **Here rather than only in `BundleVerificationTests`, and that is the load-bearing part.** That
# suite disables itself whenever the published bundle does not match current inputs, and under a bare
# `swift test` there is no signing identity so it skips by name — while `make` runs the tests *before*
# it builds the replacement bundle. A regression could therefore land as: stale bundle, checks
# skipped, new bundle built, verification passes, four green test lines. This runs on the staged
# artifact every time, release or not.
#
# `otool -L` is load commands, not the runtime image closure: `DictionaryBridge` reaches
# DictionaryServices by `dlopen` and always will. What is asserted is what is *linked*.
#
# CryptoKit is permitted to the dictionary service, deliberately. `DictionarySense.hash` keys a sense
# the publisher gave no id by a SHA-256 of its own text and `DictionaryBridge` builds those values, so
# it is on that service's real execution path. An earlier draft of this check forbade it and was
# wrong; the algorithm cannot change without invalidating every `sense_hash` already in a reader's
# ledger.
verify_service_boundaries() {
    local bundle=$1 binary problem=0
    # service path : frameworks it must not link : module symbols it must not carry
    local checks=(
        "$XPC_PATH/Contents/MacOS/$SERVICE|libsqlite3|FoundationModels|Carbon|CoreGraphics|CoreServices!XiaolaiDictCore|ModelKit|Ledger|ModelStore|ModelDownloader|RangeWriter|HoverPolicy|DrawerGeometry|ModelRequest|ModelReply"
        "$MODEL_XPC_PATH/Contents/MacOS/$MODEL_SERVICE|libsqlite3!XiaolaiDictCore|DictionaryModel|Ledger|DictionaryEntry|EntryDocument|LookupReply|HoverPolicy"
    )
    local spec path frameworks symbols found
    for spec in "${checks[@]}"; do
        path=${spec%%|*}; spec=${spec#*|}
        frameworks=${spec%%!*}; symbols=${spec#*!}
        binary="$bundle/$path"
        [ -f "$binary" ] || { echo "no binary to check at $path"; return 1; }

        found=$(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}' \
            | grep -E "($(tr '|' '\n' <<<"$frameworks" | paste -sd'|' -))" || true)
        if [ -n "$found" ]; then
            echo "$(basename "$path") links what it must not:"; sed 's/^/    /' <<<"$found"; problem=1
        fi

        # Demangled, because a mangled name spells a module differently and a scan is only as wide
        # as the spelling it searches for.
        found=$(nm "$binary" 2>/dev/null | xcrun swift-demangle 2>/dev/null \
            | grep -oE "\b($(tr '|' '\n' <<<"$symbols" | paste -sd'|' -))\b" | sort -u || true)
        if [ -n "$found" ]; then
            echo "$(basename "$path") carries symbols it must not:"; sed 's/^/    /' <<<"$found"; problem=1
        fi

        # **A scan that finds nothing because it read nothing passes.** `nm` on an unreadable or
        # stripped binary is silent, and so is this check — so it asserts the tool answered at all.
        found=$(nm "$binary" 2>/dev/null | wc -l | tr -d ' ')
        if [ "${found:-0}" -lt 100 ]; then
            echo "$(basename "$path"): nm returned $found symbols — the boundary check read nothing"
            problem=1
        fi
    done
    [ "$problem" -eq 0 ]
}

verify_bundle() {
    local bundle=$1
    verify_required_files "$bundle" || return 1
    verify_bundle_metadata "$bundle" || return 1
    verify_signatures "$bundle" || return 1
    verify_release_timestamps "$bundle" || return 1
    verify_service_boundaries "$bundle" || return 1
}

# A release is a build numbered by the release counter. Everything that differs for one — the
# timestamp, and what the verifier demands — asks this, so the two cannot disagree.
is_release() { [ -n "${XIAOLAIDICT_BUILD_NUMBER:-}" ]; }

# ---------------------------------------------------------------------------------------------
# Assembly, in the stage.

# Translations reach the bundle as compiled `.strings`, one directory per language, read through
# `Bundle.main` — which is this bundle for every module linked into it, so no call site has to name
# a bundle of its own. **The source language gets no file**: its key is its value and Foundation
# falls back to the key, so this writes nothing while the catalog is English-only. That is also why
# `verify_bundle` checks the languages the catalog carries rather than a fixed path — the check is
# vacuous today and fails the day a translation is added and not packaged.
compile_strings() {
    local contents=$1
    [ -s "$CATALOG" ] || fail "missing string catalog: $CATALOG — run make strings"
    xcrun xcstringstool compile "$CATALOG" --output-directory "$contents/Resources" \
        || fail "the string catalog did not compile"
}

# Every language in the catalog that has a translated string, the source language apart.
catalog_languages() {
    python3 - "$CATALOG" <<'CATALOG_LANGUAGES'
import json, sys
catalog = json.load(open(sys.argv[1]))
source = catalog.get("sourceLanguage")
languages = set()
for entry in catalog.get("strings", {}).values():
    for language, unit in entry.get("localizations", {}).items():
        if language != source and unit.get("stringUnit", {}).get("value"):
            languages.add(language)
print(" ".join(sorted(languages)))
CATALOG_LANGUAGES
}

assemble() {
    # Output captured, then matched: `producer | grep -q` fails under pipefail whenever grep stops
    # reading early and the producer dies of SIGPIPE — a false failure for a true match.
    local identities
    identities=$(security find-identity -v -p codesigning)
    grep -qF "$XIAOLAIDICT_SIGN_ID" <<<"$identities" \
        || fail "signing identity not in the keychain: $XIAOLAIDICT_SIGN_ID — set SIGN_ID to another Developer ID Application identity"

    # One build for all three executable products: they share every module but their mains.
    swift build -c "$CONFIG"
    local products
    products=$(swift build -c "$CONFIG" --show-bin-path)
    [ -x "$products/$APP_NAME" ] && [ -x "$products/$SERVICE" ] && [ -x "$products/$MODEL_SERVICE" ] \
        || fail "swift build produced no $APP_NAME, $SERVICE or $MODEL_SERVICE"
    # Beside the products, where SwiftPM puts resource bundles. Fails closed: a service shipped
    # without its shaders loads, then dies at its first GPU op — a failure that looks like a model
    # problem, not a packaging one.
    [ -f "$products/$METAL_BUNDLE/Contents/Resources/default.metallib" ] \
        || fail "$products/$METAL_BUNDLE has no default.metallib; refusing to ship a model service with no Metal shaders"
    resolve_products || fail "the model service's build graph could not be read"
    grep -qx "$METAL_BUNDLE" <<<"$BUNDLES" \
        || fail "the build produced no $METAL_BUNDLE; refusing to ship a model service with no Metal shaders"

    local contents=$STAGE/Contents
    local xpc=$STAGE/$XPC_PATH
    local model_xpc=$STAGE/$MODEL_XPC_PATH
    rm -rf "$STAGE_ROOT"
    mkdir -p "$contents/MacOS" "$contents/Resources" "$xpc/Contents/MacOS" \
        "$model_xpc/Contents/MacOS" "$model_xpc/Contents/Resources"
    cp "$products/$APP_NAME" "$contents/MacOS/$APP_NAME"
    cp "$products/$SERVICE" "$xpc/Contents/MacOS/$SERVICE"
    cp "$products/$MODEL_SERVICE" "$model_xpc/Contents/MacOS/$MODEL_SERVICE"
    local resource
    for resource in ${BUNDLE_LIST[@]+"${BUNDLE_LIST[@]}"}; do
        cp -R "$products/$resource" "$model_xpc/Contents/Resources/$resource"
    done
    cp "$RESOURCES/Info.plist" "$contents/Info.plist"
    cp "$RESOURCES/DictionaryService-Info.plist" "$xpc/Contents/Info.plist"
    cp "$RESOURCES/ModelService-Info.plist" "$model_xpc/Contents/Info.plist"
    cp "$RESOURCES/MenuBarIcon.svg" "$contents/Resources/MenuBarIcon.svg"
    # The licences of what is statically linked into the two services. Generated here rather than
    # tracked, so it cannot drift from `Package.resolved` — which is itself one of the inputs this
    # bundle's digest is taken over, so a dependency changed is a bundle rebuilt.
    Tools/third-party-notices.sh "$contents/Resources/$NOTICES" \
        || fail "the third-party notices could not be gathered"

    # The build number is stamped into the copies, not the tracked files: it is a property of the
    # build. Then read back, because PlistBuddy reports success for keys it did not write.
    local number plist
    number=$(build_number)
    for plist in "$contents/Info.plist" "$xpc/Contents/Info.plist" "$model_xpc/Contents/Info.plist"; do
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $number" "$plist"
        [ "$(plist_value "$plist" CFBundleVersion)" = "$number" ] || fail "CFBundleVersion did not take in $plist"
    done

    compile_icon "$contents"
    compile_strings "$contents"

    # Inside out: the service first, then the app that seals it. `--options runtime` because that
    # is how XiaolaiDict ships, and a hardened-runtime problem is cheaper found now than at notarisation.
    # A secure timestamp needs Apple's server: required to notarise, pointless for a local build
    # that would then fail to sign offline. So a release gets one and a development build does
    # not. stdout silenced, stderr kept, so a failure says why.
    local stamp=--timestamp=none
    ! is_release || stamp=--timestamp
    # Innermost first: each resource bundle is a code object of its own, and the model service cannot
    # be signed over an unsigned one — "code object is not signed at all" (S2).
    for resource in ${BUNDLE_LIST[@]+"${BUNDLE_LIST[@]}"}; do
        sign_part "$stamp" "$model_xpc/Contents/Resources/$resource"
    done
    sign_part "$stamp" "$model_xpc"
    sign_part "$stamp" "$xpc"
    sign_part "$stamp" "$STAGE"

    verify_bundle "$STAGE" || fail "the staged bundle failed verification"
    note "assembled $STAGE (build $number)"
}

# The Icon Composer document, compiled to an asset catalogue. macOS 26 draws app icons itself —
# shape, lighting, dark and tinted variants — and can only do that from layered contents, not a
# finished picture. Absolute paths: actool resolves relative ones against a working directory it
# cached from an earlier invocation, not the current one.
compile_icon() {
    local contents=$1
    local partial=$STAGE_ROOT/icon-partial.plist
    local report=$STAGE_ROOT/actool.log
    # Its report is kept, not discarded: actool prints warnings and still exits 0, so a warning sent
    # to /dev/null is one nobody ever sees. Any warning or error stops the build.
    xcrun actool --compile "$PWD/$contents/Resources" --app-icon "$APP_NAME" \
        --output-partial-info-plist "$PWD/$partial" \
        --platform macosx --minimum-deployment-target "$MINIMUM_MACOS" --target-device mac \
        --errors --warnings --output-format human-readable-text "$PWD/$RESOURCES/XiaolaiDict.icon" \
        >"$report" 2>&1 || { cat "$report"; fail "actool failed"; }
    if grep -qiE ": (warning|error):" "$report"; then
        cat "$report"
        fail "actool reported problems with $RESOURCES/XiaolaiDict.icon"
    fi
    # actool says, in the partial Info.plist it requires, which icon name the catalogue holds;
    # that is what goes into Info.plist, not a name typed here. Its CFBundleIconFile names the
    # flattened .icns, which only systems older than XiaolaiDict's minimum read — so neither is kept.
    local icon_name
    icon_name=$(plist_value "$partial" CFBundleIconName)
    [ "$icon_name" = "$APP_NAME" ] || fail "actool compiled icon '$icon_name', not $APP_NAME"
    rm -f "$contents/Resources/$APP_NAME.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $icon_name" "$contents/Info.plist"
    # actool exits 0 having written nothing; a catalogue can hold only flattened bitmaps, which is
    # a picture of the icon rather than the icon.
    [ -s "$contents/Resources/Assets.car" ] || fail "actool wrote no Assets.car"
    local catalogue
    catalogue=$(xcrun assetutil --info "$contents/Resources/Assets.car" 2>/dev/null) || fail "assetutil cannot read Assets.car"
    grep -q IconImageStack <<<"$catalogue" || fail "Assets.car has no IconImageStack — no Liquid Glass icon"
}

# ---------------------------------------------------------------------------------------------
# Running copies, found by the exact path of this bundle's executables: by the executable ps
# reports, not the command line — arguments LaunchServices adds cannot hide a process — and by
# string equality, not a pattern. ps reports the path a process was started by; `open`, launchd and
# this script start XiaolaiDict and its service by absolute path. Never by name, which would also match any other process called
# XiaolaiDict. A `ps` that fails stops the build: "could not look" is not "nothing is running".

# Sets PIDS to the processes running the executable at $1. Not a $(…) function on purpose: a
# failing ps must stop the build, and inside a command substitution `fail` would stop only the
# subshell — leaving an empty answer that reads as "nothing is running".
find_pids() {
    local table pid executable
    table=$(ps -axww -o pid=,comm=) || fail "ps failed, so whether $1 is running cannot be told"
    PIDS=()
    while read -r pid executable; do
        [ "$executable" != "$PWD/$1" ] || PIDS+=("$pid")
    done <<<"$table"
}

is_running() {  # $1: executable path; fails the build, rather than answering, if ps fails
    find_pids "$1"
    [ "${#PIDS[@]}" -gt 0 ]
}

stop() {  # path of an executable; TERM, wait, then KILL, then insist
    local executable=$1 label=$2
    find_pids "$executable"
    [ "${#PIDS[@]}" -gt 0 ] || return 0
    note "quitting the running $label"
    # XiaolaiDict handles SIGTERM as a normal quit (NSApplication.terminate), not a mid-write exit.
    kill -TERM "${PIDS[@]}" 2>/dev/null || true
    for _ in $(seq 1 50); do is_running "$executable" || return 0; sleep 0.1; done
    note "the $label did not quit within 5 s; killing it"
    find_pids "$executable"
    [ "${#PIDS[@]}" -eq 0 ] || kill -KILL "${PIDS[@]}" 2>/dev/null || true
    for _ in $(seq 1 20); do is_running "$executable" || return 0; sleep 0.1; done
    fail "the $label is still running — quit it by hand"
}

quit_running() {
    stop "$APP/Contents/MacOS/$APP_NAME" "$APP_NAME"
    # launchd ends the app's XPC service with the app, but not at once; one that outlived it would
    # serve the next build's app with the old code and protocol.
    local service
    for service in "$APP/$XPC_PATH/Contents/MacOS/$SERVICE" "$APP/$MODEL_XPC_PATH/Contents/MacOS/$MODEL_SERVICE"; do
        local waited=0
        while is_running "$service" && [ "$waited" -lt 30 ]; do sleep 0.1; waited=$((waited + 1)); done
        stop "$service" "$(basename "$service")"
    done
}

# ---------------------------------------------------------------------------------------------
# Publication: one atomic exchange of the staged bundle with the published one (renamex_np with
# RENAME_SWAP), so $APP is never missing and never half-replaced; the old bundle ends up in the
# stage and is removed after.

swap_into_place() {
    python3 - "$STAGE" "$APP" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
RENAME_SWAP = 0x2
if libc.renamex_np(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), RENAME_SWAP) != 0:
    sys.exit("renamex_np: " + os.strerror(ctypes.get_errno()))
PY
}

record_digest() { printf '%s\n' "$1" > "$BUNDLE_DIGEST.new" && mv "$BUNDLE_DIGEST.new" "$BUNDLE_DIGEST"; }

publish() {
    local digest=$1
    # A running copy would go on using — and launch services from — the bundle being replaced.
    quit_running
    rm -f "$BUNDLE_DIGEST"
    if [ -e "$APP" ]; then
        swap_into_place || fail "could not swap the new bundle into place; $APP is unchanged"
        # The old bundle is in the stage until the new one is recorded: if recording fails, it is
        # swapped back rather than lost.
        if ! record_digest "$digest"; then
            swap_into_place || fail "could not record the build, nor swap the previous bundle back from $STAGE"
            fail "could not record the build; the previous bundle is back in place"
        fi
        rm -rf "$STAGE"
    else
        mv "$STAGE" "$APP"
        # With no previous bundle there is nothing to return to; an unrecorded one is rebuilt.
        record_digest "$digest" || fail "could not record the build; the next make rebuilds it"
    fi
    note "published $APP ($(du -sh "$APP" | cut -f1))"
}

# Builds and publishes unless the published bundle already matches its inputs and verifies.
build() {
    [ -n "${XIAOLAIDICT_SIGN_ID:-}" ] || fail "XIAOLAIDICT_SIGN_ID is not set"
    ensure_icon
    snapshot_resources
    local digest
    digest=$(bundle_inputs_digest)
    if [ -d "$APP" ] && [ "$(cat "$BUNDLE_DIGEST" 2>/dev/null)" = "$digest" ]; then
        local problem
        if problem=$(verify_bundle "$APP" 2>&1); then
            note "$APP is up to date"
            return 0
        fi
        note "$APP matches its inputs but fails verification ($problem); rebuilding"
    fi
    assemble
    publish "$digest"
}

# ---------------------------------------------------------------------------------------------
# After `open`: that the app stayed up, and that its embedded service answers a lookup through the
# real XPC path — a launch that dies at once, or a service that refuses the app's signature, is
# not a successful run.

health_check() {
    local executable=$APP/Contents/MacOS/$APP_NAME
    for _ in $(seq 1 100); do ! is_running "$executable" || break; sleep 0.1; done
    is_running "$executable" || fail "$APP_NAME did not start"
    sleep 1
    is_running "$executable" || fail "$APP_NAME started, then quit — see Console for the crash"
    # Bounded from outside: the probe's own 3 s service deadline does not cover its plain-text
    # fallback, which is a synchronous system call.
    "$PWD/$executable" --lookup ephemeral &
    local probe=$!
    for _ in $(seq 1 150); do kill -0 "$probe" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$probe" 2>/dev/null; then
        kill -KILL "$probe" 2>/dev/null || true
        fail "the lookup probe did not finish within 15 s"
    fi
    wait "$probe" || fail "the running bundle's dictionary service did not answer a lookup"
    # The model service evaluates one MLX op on its GPU: "it starts" is not "it can run MLX".
    local status
    status=$("$PWD/$executable" --model-status) || fail "the running bundle's model service cannot run MLX: $status"
    note "$APP_NAME is running, its dictionary service answers, and its model service runs MLX ($status)"
}

case "${1:-}" in
    build) build ;;
    # **Whether the published bundle was built from the inputs that are here now.** Digest only —
    # nothing is verified, nothing is built, and the resource snapshot is read rather than retaken,
    # so this stays a question. `BundleVerificationTests` asks it before mutating a copy of that
    # bundle: verifying a bundle older than the checks it is being measured against would fail on
    # what the last build did not know to produce, and say nothing about the checks.
    current)
        [ -d "$APP" ] && [ -d "$RESOURCES" ] \
            && [ "$(cat "$BUNDLE_DIGEST" 2>/dev/null)" = "$(bundle_inputs_digest)" ]
        ;;
    # Verification alone, over a bundle named on the command line — what `BundleVerificationTests`
    # drives. The checks refuse in `verify_bundle`'s own words, which is what those tests read.
    verify)
        [ -n "${2:-}" ] || fail "usage: $0 verify <bundle>"
        verify_bundle "$2" || fail "$2 failed verification"
        note "$2 verifies"
        ;;
    run)
        build
        quit_running
        open "$APP"
        health_check
        ;;
    icon)
        generate_icon
        snapshot_resources
        ;;
    clean)
        quit_running
        rm -rf "$STAGE_ROOT" "$APP" "$BUNDLE_DIGEST" "$ICON_DIGEST" "$RESOURCES" "$RESOURCES.new"
        ;;
    *)
        fail "usage: $0 build|run|icon|clean|current|verify <bundle>"
        ;;
esac
