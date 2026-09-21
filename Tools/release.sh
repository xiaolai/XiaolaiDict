#!/bin/bash
# Notarises a release of XiaolaiDict and packages it for download.
#
#   make release BUILD_NUMBER=<n>
#
# Signing is not enough to ship. Gatekeeper on someone else's Mac demands a notarisation ticket as
# well, and a signed-but-unnotarised XiaolaiDict reads there as "rejected / source=Unnotarized Developer
# ID" — the state every development build is in. This script is the rest of the way:
#
#   1. build, signed with a secure timestamp        (notarisation rejects a signature without one)
#   2. notarise the app, staple its ticket          (so first launch works offline)
#   3. build the disk image from the stapled app
#   4. sign the disk image                          (a ticket alone is not enough for a .dmg)
#   5. notarise the disk image, staple its ticket
#   6. ask Gatekeeper, and fail unless it says "Notarized Developer ID"
#
# The order is load-bearing: each step consumes the one before it, and a disk image built before
# its app was stapled ships the unstapled app.
#
# Environment:
#   XIAOLAIDICT_SIGN_ID          Developer ID Application identity (the Makefile sets it)
#   XIAOLAIDICT_BUILD_NUMBER     the release counter's value — required; it is what makes this a release
#   XIAOLAIDICT_NOTARY_PROFILE   a notarytool keychain profile — `chase-notary`, the one this developer's
#                         projects share. A profile authenticates the *account*, not the app, so a
#                         per-project copy would only be a second password to rotate; TYPE uses the
#                         same one. Credentials live in the keychain and never in this script, the
#                         Makefile or the environment.
#
# Measured in TYPE, and the reason no API key is offered here: the App Store Connect API key is
# refused for notarisation with a 403 while the team's agreement is unsigned. The Apple ID behind
# the keychain profile is unaffected.

set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "error: $*" >&2; exit 1; }
note() { echo "$*"; }

readonly BUILT=.build/XiaolaiDict.app
readonly OUT=.build/release
# Released from a copy, so stapling never touches the bundle development builds are published to.
readonly APP=$OUT/XiaolaiDict.app
# Apple's notary service drops connections and notarytool has no retry of its own. Five is TYPE's
# measured count, not a guess.
readonly TRIES=5

[ -n "${XIAOLAIDICT_SIGN_ID:-}" ] || fail "XIAOLAIDICT_SIGN_ID is not set"
[ -n "${XIAOLAIDICT_BUILD_NUMBER:-}" ] \
    || fail "a release needs a number from the release counter: make release BUILD_NUMBER=<n>"
[ -n "${XIAOLAIDICT_NOTARY_PROFILE:-}" ] || fail "XIAOLAIDICT_NOTARY_PROFILE is not set"

# Before anything is built or uploaded: the profile exists, and Apple accepts it. Asking for the
# submission history is the cheapest authenticated call there is, and failing here costs seconds
# rather than a full build.
xcrun notarytool history --keychain-profile "$XIAOLAIDICT_NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notarytool cannot use the keychain profile '$XIAOLAIDICT_NOTARY_PROFILE'. It is shared across projects and made once per Mac with \`xcrun notarytool store-credentials\` — check the name, or that the keychain is unlocked"

# Uploads, then waits — as two calls, because they fail differently. notarytool has no retry of its
# own and Apple's service drops connections; a single `submit --wait` that times out while
# *polling* reports failure for an upload that already went through, and re-running it uploads
# twice. So the upload is retried only while it has produced no submission id, and once there is an
# id only the wait is retried, which never uploads anything.
#
# Parsed from notarytool's plist with `plutil`, which is on every Mac and fails loudly on a missing
# key. **stdout alone is parsed**: merging stderr in, as this first did, meant any warning notarytool
# printed would have corrupted the document being read. And a *verdict* ends the wait whatever
# notarytool's exit code is — only a dropped connection is worth asking again, so a rejection is
# reported at once rather than after every retry has slept. This is the pattern the apple-cosign
# skill's reference.md documents and tests.
notarize() {  # $1: the file to submit — a .zip of the app, or the .dmg
    local file=$1 attempt out id="" status=""
    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        if out=$(xcrun notarytool submit "$file" --keychain-profile "$XIAOLAIDICT_NOTARY_PROFILE" \
                    --output-format plist) \
           && id=$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null); then
            break
        fi
        id=""
        (( attempt < TRIES )) || break
        note "upload attempt $attempt of $TRIES did not return a submission id; retrying"
        sleep $(( attempt * 10 ))
    done
    [ -n "$id" ] || fail "could not upload $file for notarisation after $TRIES attempts"
    note "submitted $(basename "$file") as $id; waiting for Apple"

    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        out=$(xcrun notarytool wait "$id" --keychain-profile "$XIAOLAIDICT_NOTARY_PROFILE" \
                --output-format plist) || true
        status=$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null) || status=""
        case $status in Accepted | Invalid | Rejected) break ;; esac
        (( attempt < TRIES )) || break
        note "no verdict for $id yet (attempt $attempt of $TRIES); asking again — the upload stands"
        sleep $(( attempt * 15 ))
    done
    if [ "$status" != "Accepted" ]; then
        # Apple's log names each rejected file and why; without it a rejection is a guess.
        xcrun notarytool log "$id" --keychain-profile "$XIAOLAIDICT_NOTARY_PROFILE" >&2 || true
        fail "notarisation of $(basename "$file") ended as '${status:-no verdict}' (submission $id)"
    fi
    note "notarised $(basename "$file")"
}

# Retried too: stapling fetches the ticket from Apple, and drops the same way an upload does. TYPE
# retries it for that reason. A ticket not yet propagated reads the same as a dropped connection,
# which is a second reason to try again rather than fail at once.
staple() {  # $1: the notarised artifact
    local attempt
    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        xcrun stapler staple "$1" >/dev/null 2>&1 && break
        (( attempt < TRIES )) || fail "could not staple a ticket to $1 after $TRIES attempts"
        note "stapling $(basename "$1") failed (attempt $attempt of $TRIES); retrying"
        sleep 10
    done
    xcrun stapler validate "$1" >/dev/null || fail "$1 has no valid ticket after stapling"
}

# The only verdict that counts: what Gatekeeper tells a user who downloaded this. Captured rather
# than piped, so the exit status is spctl's and not grep's, and never `|| true` — a check that
# cannot fail is not a check.
gatekeeper() {  # $1: artifact; the rest: spctl's assessment options
    local artifact=$1 verdict
    shift
    verdict=$(spctl -a -vvv "$@" "$artifact" 2>&1) || fail "Gatekeeper rejected $artifact: $verdict"
    grep -q 'source=Notarized Developer ID' <<<"$verdict" \
        || fail "Gatekeeper accepted $artifact, but not as notarised: $verdict"
    note "Gatekeeper: $(basename "$artifact") accepted, source=Notarized Developer ID"
}

# 1. Build. A release number makes build-bundle.sh sign with a secure timestamp and refuse any
#    bundle that lacks one, so this cannot quietly reuse a development signature.
Tools/build-bundle.sh build
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUILT/Contents/Info.plist")
[ "$build" = "$XIAOLAIDICT_BUILD_NUMBER" ] || fail "the built bundle is numbered $build, not $XIAOLAIDICT_BUILD_NUMBER"

# `get-task-allow` lets a debugger attach, and the notary service refuses any binary carrying it.
# Checked before the upload, as TYPE does, so the refusal arrives in a second rather than minutes
# later from Apple. Captured, then matched: a piped `grep -q` can SIGPIPE its producer.
for part in "$BUILT" "$BUILT/Contents/XPCServices/XiaolaiDictService.xpc"; do
    entitlements=$(codesign -d --entitlements :- "$part" 2>/dev/null || true)
    ! grep -q "get-task-allow" <<<"$entitlements" \
        || fail "get-task-allow is set on $part — the notary service would refuse it"
done

rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$BUILT" "$APP"

# 2. The app. notarytool takes an archive rather than a bundle, and `ditto -c -k --keepParent` is
#    the form Apple documents. Not because a plain zip would lose the signature — TYPE claimed that,
#    measured it, and retracted it: in a bundle the signature is ordinary file content and survives
#    either way. `zip` does flatten symlinks without `-y`, which matters to a bundle with frameworks
#    and not to this one; the documented form costs nothing and keeps that true if XiaolaiDict gains one.
ditto -c -k --keepParent "$APP" "$OUT/XiaolaiDict.zip"
notarize "$OUT/XiaolaiDict.zip"
rm -f "$OUT/XiaolaiDict.zip"
staple "$APP"
codesign --verify --strict --deep "$APP" || fail "stapling broke the app's signature"

# 3. The disk image, from the stapled app, with the usual Applications link to drag it onto.
dmg=$OUT/XiaolaiDict-$version.dmg
staging=$(mktemp -d)
mount=""
# One exit path, so an image mounted to be checked is detached even when a check fails.
cleanup() {
    if [ -n "$mount" ]; then
        hdiutil detach -quiet "$mount" 2>/dev/null || true
        rmdir "$mount" 2>/dev/null || true
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
ditto "$APP" "$staging/XiaolaiDict.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "XiaolaiDict $version" -srcfolder "$staging" -ov -format UDZO "$dmg" \
    || fail "hdiutil could not build $dmg"

# 4–5. Signed, then notarised and stapled in its own right. A .dmg is assessed on its own
#      signature before anything inside it is looked at.
codesign --force --timestamp --sign "$XIAOLAIDICT_SIGN_ID" "$dmg" || fail "could not sign $dmg"
notarize "$dmg"
staple "$dmg"

# 6. As a user meets them: the disk image they downloaded, and **the app inside it** — not the copy
#    this script built the image from. Those are different files, and only one of them ships. TYPE
#    round-trips its archive for the same reason: the property that matters is that what is *in*
#    the distributable still passes, and asserting it costs seconds. Mounted read-only and hidden
#    from Finder, so checking it cannot change it.
gatekeeper "$dmg" -t open --context context:primary-signature
mount=$(mktemp -d)
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg" || fail "could not mount $dmg to check it"
shipped=$mount/XiaolaiDict.app
codesign --verify --strict --deep "$shipped" || fail "the app inside $(basename "$dmg") does not verify"
xcrun stapler validate "$shipped" >/dev/null || fail "the app inside $(basename "$dmg") carries no ticket"
gatekeeper "$shipped" -t exec
hdiutil detach -quiet "$mount" || fail "could not detach $mount"
rmdir "$mount" 2>/dev/null || true
mount=""

note ""
note "released XiaolaiDict $version ($build)"
note "  $dmg"
note "  size   $(du -h "$dmg" | cut -f1)"
note "  sha256 $(shasum -a 256 "$dmg" | cut -d' ' -f1)"
