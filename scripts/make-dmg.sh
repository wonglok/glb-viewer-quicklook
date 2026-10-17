#!/bin/bash
#
# Build a timestamped, signed DMG from the packaged app.
#
#   scripts/make-dmg.sh                     sign the DMG, no Apple round-trip
#   NOTARY_PROFILE=AC_PASSWORD scripts/make-dmg.sh --notarize
#
# The app itself is expected to have been built, signed and (ideally) stapled by
# scripts/package.sh. The DMG adds only the Applications symlink and the disk
# image wrapper; it never re-signs the app.
#
# hdiutil rather than create-dmg on purpose: create-dmg drives Finder through
# AppleScript to lay out icons, which needs a GUI session and fails opaquely
# when it does not get one. The layout here is the part Gatekeeper cares about
# (the app and a drop target), so it is built deterministically.
#
# The DMG is signed with the same Developer ID identity as the app. Signing the
# image and notarizing the app are independent: a stapled app still opens from
# any distribution channel. Pass --notarize to also submit the DMG itself, so
# the image is recognized before it is opened.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="GLB 3D model viewer"
DIST="$ROOT/build/dist"
APP="$DIST/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

NOTARIZE=0
APP_ARG=""
for arg in "$@"; do
    case "$arg" in
        --notarize) NOTARIZE=1 ;;
        --help|-h) sed -n '2,22p' "$0"; exit 0 ;;
        *) APP_ARG="$arg" ;;
    esac
done
[[ -n "$APP_ARG" ]] && APP="$APP_ARG"

[[ -d "$APP" ]] || die "no app at $APP — run scripts/package.sh first"
codesign --verify --deep --strict "$APP" || die "$APP does not verify"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
STAMP="$(date +%Y%m%d-%H%M)"
DMG="$DIST/GLB-3D-Model-Viewer-$VERSION-$STAMP.dmg"
[[ ! -e "$DMG" ]] || die "$(basename "$DMG") already exists — two builds in the same minute"

step "Staging $APP_NAME"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# --noextattr --norsrc: same reason as the zip in package.sh — com.apple.provenance
# cannot be removed with xattr -cr and would otherwise become AppleDouble noise.
ditto --noextattr --norsrc "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

step "Creating $(basename "$DMG")"
mkdir -p "$DIST"
hdiutil create \
    -volname "$APP_NAME" \
    -fs HFS+ \
    -srcfolder "$STAGE" \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

step "Signing the disk image"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"
hdiutil verify "$DMG" >/dev/null

if (( NOTARIZE )); then
    : "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile, e.g. NOTARY_PROFILE=AC_PASSWORD}"
    step "Submitting the DMG to the notary service as '$NOTARY_PROFILE' (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    step "Stapling the ticket to the DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    step "Asking Gatekeeper what it thinks"
    spctl -a -t open --context context:primary-signature "$DMG" -vv \
        || die "Gatekeeper still rejects the DMG"
fi

printf '\n\033[32mDone.\033[0m %s\n' "$DMG"
ls -lh "$DMG"
if (( ! NOTARIZE )); then
    printf '\033[33mDMG signed but not notarized.\033[0m The app inside carries its own ticket if\n'
    printf 'scripts/package.sh notarized and stapled it.\n'
fi
