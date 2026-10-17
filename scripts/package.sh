#!/bin/bash
#
# Build, sign, notarize and staple the app, and leave a distributable zip behind.
#
#   scripts/package.sh                  build → sign → notarize → staple → zip
#   scripts/package.sh --skip-notarize  build → sign → zip (no Apple round-trip)
#
# The signing overrides below are not in the project on purpose: the everyday
# `xcodebuild ... build` keeps automatic signing with an Apple Development
# identity, and only this script signs for distribution.
#
# The two overrides that matter:
#   CODE_SIGN_IDENTITY="Developer ID Application"  distribution, not development
#   CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO          without it Xcode injects
#       com.apple.security.get-task-allow, and the notary service rejects any
#       binary that requests it. Hardened runtime comes from
#       ENABLE_HARDENED_RUNTIME = YES in the project.
#
# Notarization needs a notarytool keychain profile, named by NOTARY_PROFILE —
# there is deliberately no default, so no credential name is baked into the repo:
#
#   NOTARY_PROFILE=AC_PASSWORD scripts/package.sh
#
# Create it once with:
#   xcrun notarytool store-credentials AC_PASSWORD --apple-id ... --team-id CY8MDF5N35

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="GLB 3D model viewer"               # CFBundleDisplayName; the product is named otherwise
BUILT_APP="$ROOT/build/Release/glb-viewer-quicklook.app"
DIST="$ROOT/build/dist"
APP="$DIST/$APP_NAME.app"
# Set after the build, from the version the app was actually stamped with — see
# "Zipping for submission". Older archives are left in place, so the timestamp
# is what tells two builds apart.
ZIP=""
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
TEAM_ID="${TEAM_ID:-CY8MDF5N35}"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
    || die "no '$SIGN_IDENTITY' identity in the keychain"

step "Building (Release, $SIGN_IDENTITY, hardened runtime)"
rm -rf "$ROOT/build/Release"
xcodebuild -project "$ROOT/glb-viewer-quicklook.xcodeproj" \
           -target glb-viewer-quicklook \
           -configuration Release \
           CODE_SIGN_STYLE=Manual \
           CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
           CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
           OTHER_CODE_SIGN_FLAGS="--timestamp" \
           DEVELOPMENT_TEAM="$TEAM_ID" \
           build

step "Checking the signature"
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

# Captured rather than piped into grep: `grep -q` exits at the first match, which
# sends SIGPIPE to codesign, and under `pipefail` that non-zero status becomes the
# pipeline's — turning a match into a failure.
SIGNATURE_INFO="$(codesign -dvvv "$BUILT_APP" 2>&1)"
ENTITLEMENTS="$(codesign -d --entitlements - "$BUILT_APP" 2>/dev/null)"

grep -q "flags=.*runtime" <<<"$SIGNATURE_INFO" \
    || die "hardened runtime is not enabled"
grep -q "Authority=$SIGN_IDENTITY" <<<"$SIGNATURE_INFO" \
    || die "not signed with a '$SIGN_IDENTITY' identity"
if [[ "$ENTITLEMENTS" == *get-task-allow* ]]; then
    die "com.apple.security.get-task-allow is present; the notary service rejects it"
fi
echo "hardened runtime on, no get-task-allow, '$SIGN_IDENTITY' signature valid"

step "Assembling $APP_NAME.app"
mkdir -p "$DIST"
# Only the bundle is cleared, not the whole directory: earlier archives stay put
# and the timestamp in the name is what distinguishes one build from the next.
rm -rf "$APP"
# Renaming after signing is safe: the seal covers the bundle's contents, not the
# name of the bundle itself. Verified below rather than assumed.
cp -R "$BUILT_APP" "$APP"
codesign --verify --deep --strict "$APP" || die "signature broke on rename"

# Zipping with --noextattr --norsrc, not simply xattr -cr: every file the kernel
# touches carries com.apple.provenance, which xattr cannot remove, and ditto
# would turn each one into a visible ._Foo AppleDouble entry in the archive —
# dozens of them, none of which a signature needs. The notarization ticket is
# not an xattr either: stapler writes Contents/CodeResources as a plain file, so
# nothing here can drop it.
zip_app() { ditto -c -k --keepParent --noextattr --norsrc "$1" "$2"; }

step "Zipping for submission"
# Version from the built bundle rather than from the project file, so the name
# cannot drift from what was actually signed.
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
STAMP="$(date +%Y%m%d-%H%M)"
ZIP="$DIST/GLB-3D-Model-Viewer-$VERSION-$STAMP.zip"
[[ ! -e "$ZIP" ]] || die "$(basename "$ZIP") already exists — two builds in the same minute"
zip_app "$APP" "$ZIP"
ls -lh "$ZIP"
[[ "$(unzip -l "$ZIP" | grep -c '\._')" == "0" ]] || die "archive contains AppleDouble entries"

if (( SKIP_NOTARIZE )); then
    printf '\n\033[33mSkipped notarization.\033[0m %s is signed but NOT notarized, so Gatekeeper\n' "$ZIP"
    printf 'will still refuse it on another Mac. Re-run without --skip-notarize.\n'
    exit 0
fi

: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile, e.g. NOTARY_PROFILE=AC_PASSWORD}"

step "Submitting to the notary service as '$NOTARY_PROFILE' (this takes a few minutes)"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
    cat >&2 <<EOF

$(printf '\033[31m')Notarization did not run.$(printf '\033[0m')

If the error above is:

    HTTP status code: 403. A required agreement is missing or has expired.

then the credentials are fine and the build is fine — the *team* has no
in-effect Apple Developer Program License Agreement, and the notary service
refuses every submission until one is signed. Only the Account Holder can fix
it, at:

    https://appstoreconnect.apple.com  →  Business (Agreements, Tax, and Banking)

This is not something the build can work around, and no other credential type
(API key, app-specific password) avoids it.

If the error is instead "Invalid credentials", the keychain profile is wrong:
re-create it with

    xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id ... --team-id CY8MDF5N35
EOF
    exit 1
fi

step "Stapling the ticket to the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Re-zipping the stapled app"
rm -f "$ZIP"
zip_app "$APP" "$ZIP"
# Captured, not piped — see the note on `grep -q` under "Checking the signature".
ARCHIVE_LISTING="$(unzip -l "$ZIP")"
[[ "$ARCHIVE_LISTING" == *"Contents/CodeResources"* ]] \
    || die "the staple ticket is not in the archive"
[[ "$ARCHIVE_LISTING" != *"._"* ]] || die "archive contains AppleDouble entries"

step "Asking Gatekeeper what it thinks"
# spctl reports on a copy: assessing the original can leave a cached verdict.
TMP="$(mktemp -d)"
ditto "$APP" "$TMP/$APP_NAME.app"
spctl -a -vvv -t exec "$TMP/$APP_NAME.app" || die "Gatekeeper still rejects the app"
rm -rf "$TMP"

printf '\n\033[32mDone.\033[0m %s — signed, notarized, stapled, and zipped.\n' "$ZIP"
