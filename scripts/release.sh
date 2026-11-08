#!/bin/bash
# Builds a signed and notarized BlueSkyship.dmg for people outside this Mac.
#
# Needed once, by the owner of the developer account:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > "Developer ID Application".
#   2. An app-specific password from https://account.apple.com, then:
#        xcrun notarytool store-credentials BlueSkyship --apple-id YOUR_APPLE_ID --team-id U52XA965SR
#      It asks for the password and keeps it in the login keychain.
#
# Usage: scripts/release.sh 1.0.0
set -euo pipefail

VERSION="${1:-}"
TEAM="U52XA965SR"
PROFILE="BlueSkyship"
cd "$(dirname "$0")/.."
OUT="build/release"

fail() {
    echo "error: $1" >&2
    exit 1
}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "give a version such as 1.0.0"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || fail "no Developer ID Application certificate; see step 1 at the top of this script"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "no notarization credentials named $PROFILE; see step 2 at the top of this script"

mkdir -p "$OUT"
rm -rf "${OUT:?}/BlueSkyship.xcarchive" "${OUT:?}/export" "${OUT:?}/BlueSkyship.dmg"

xcodegen generate
xcodebuild archive \
    -project BlueSkyship.xcodeproj -scheme BlueSkyship -configuration Release \
    -archivePath "$OUT/BlueSkyship.xcarchive" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development"

cat > "$OUT/export-options.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$OUT/BlueSkyship.xcarchive" \
    -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/export-options.plist" \
    -allowProvisioningUpdates

APP="$OUT/export/BlueSkyship.app"
codesign --verify --deep --strict "$APP"

hdiutil create -volname "BlueSkyship" -srcfolder "$APP" -ov -format UDZO "$OUT/BlueSkyship.dmg"
codesign --sign "Developer ID Application" --timestamp "$OUT/BlueSkyship.dmg"

xcrun notarytool submit "$OUT/BlueSkyship.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/BlueSkyship.dmg"
spctl --assess --type open --context context:primary-signature --verbose "$OUT/BlueSkyship.dmg"

echo "ready: $OUT/BlueSkyship.dmg"
