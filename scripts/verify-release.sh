#!/bin/bash
# Checks a finished DMG the way people receive it, without starting the app.
# Usage: scripts/verify-release.sh build/release/BlueSkyship.dmg
set -euo pipefail

DMG="${1:?give the path to a DMG}"

fail() {
    echo "error: $1" >&2
    exit 1
}

xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

MOUNT="$(mktemp -d)"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null
APP="$MOUNT/BlueSkyship.app"

[ -d "$APP" ] || fail "the DMG contains no app"
[ -L "$MOUNT/Applications" ] || fail "the link to Applications is missing"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
syspolicy_check distribution "$APP"

SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=Developer ID Application:"* ]] || fail "the app is not signed with Developer ID"
[[ "$SIGNATURE" == *"Timestamp="* ]] || fail "the signature has no secure timestamp"
[[ "$SIGNATURE" == *"(runtime)"* ]] || fail "the hardened runtime is off"
[ -f "$APP/Contents/embedded.provisionprofile" ] || fail "the provisioning profile for iCloud is missing"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/BlueSkyship")"
[[ "$ARCHS" == *x86_64* && "$ARCHS" == *arm64* ]] || fail "the app is not universal: $ARCHS"

echo "verified: $DMG"
