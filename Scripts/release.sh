#!/usr/bin/env bash
# Builds the installer for a GitHub Release: dist/PorchLight-<version>.pkg, signed with Developer ID and
# notarized by Apple, so it opens normally on any Mac. The installer puts the app in /Applications, starts
# the guardian for the logged-in user and links the CLI (see Scripts/pkg/). This script installs and
# launches nothing.
#
# Needs, in the login keychain, for the team in Config/Signing.local.xcconfig:
#   - a "Developer ID Application" identity, for the app and its helpers;
#   - a "Developer ID Installer" identity, for the package;
#   - notarytool credentials saved as a profile, by default "porchlight-notary":
#       xcrun notarytool store-credentials porchlight-notary --apple-id <you@example.com> --team-id <TEAM>
#     (it asks for an app-specific password from appleid.apple.com). NOTARY_PROFILE picks another profile.
set -euo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
    echo "release.sh: $1" >&2
    exit 1
}

PROFILE="${NOTARY_PROFILE:-porchlight-notary}"
SIGNING_CONFIG="Config/Signing.local.xcconfig"
APP="build/PorchLight.app"
HELPERS="$APP/Contents/Helpers"
DIST="dist"
WORK="$DIST/work"

[ -f "$SIGNING_CONFIG" ] || fail "$SIGNING_CONFIG is missing. Run Scripts/bootstrap.sh."
team="$(sed -nE 's/^DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' "$SIGNING_CONFIG")"
[ -n "$team" ] || fail "$SIGNING_CONFIG has no DEVELOPMENT_TEAM."

app_identity="$(security find-identity -v -p codesigning | sed -nE "s/.*\"(Developer ID Application: .*\($team\))\"/\1/p" | head -1)"
installer_identity="$(security find-identity -v | sed -nE "s/.*\"(Developer ID Installer: .*\($team\))\"/\1/p" | head -1)"
[ -n "$app_identity" ] || fail "no \"Developer ID Application\" identity for team $team in the keychain."
[ -n "$installer_identity" ] || fail "no \"Developer ID Installer\" identity for team $team in the keychain."
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "notarytool has no working profile \"$PROFILE\". See the top of this script."

# Submits $1 to Apple and waits. Notarization can say Invalid with exit code 0, so read the status.
notarize() {
    local output
    output="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1)" || true
    echo "$output" | sed 's/^/  notarytool: /'
    echo "$output" | grep -q 'status: Accepted' \
        || fail "Apple didn't accept $1. Run: xcrun notarytool log <submission id> --keychain-profile $PROFILE"
}

# 1. The app, built and signed with Apple Development by build.sh, then signed again, inner to outer, with
#    Developer ID and a secure timestamp, which notarization needs. Same identifiers as build.sh.
Scripts/build.sh
sign() {
    codesign --force --timestamp --options runtime --sign "$app_identity" "$@"
}
sign --identifier com.alexluncan.PorchLight.cli "$HELPERS/porchlight"
sign --identifier com.alexluncan.PorchLight.guardian "$HELPERS/porchlight-guardian"
sign --entitlements Config/PorchLight.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q get-task-allow; then
    fail "$APP carries com.apple.security.get-task-allow, which notarization refuses."
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PKG="$DIST/PorchLight-$version.pkg"

rm -rf "$DIST"
mkdir -p "$WORK/root/Applications" "$WORK/scripts"

# 2. Notarize the app on its own and staple the ticket to it, so it also opens on a Mac that's offline.
ditto -c -k --keepParent "$APP" "$WORK/PorchLight.zip"
notarize "$WORK/PorchLight.zip"
xcrun stapler staple "$APP"

# 3. The package: the app into /Applications, never moved to wherever another copy happens to be, with the
#    scripts that stop the old copy first and start the guardian after.
ditto "$APP" "$WORK/root/Applications/PorchLight.app"
cp Scripts/pkg/preinstall Scripts/pkg/postinstall "$WORK/scripts/"
cp Config/com.alexluncan.PorchLight.guardian.plist "$WORK/scripts/guardian.plist"
chmod 755 "$WORK/scripts/preinstall" "$WORK/scripts/postinstall"
# Without this, extended attributes come along as ._ files next to the scripts.
xattr -c "$WORK/scripts"/*
export COPYFILE_DISABLE=1
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
pkgbuild \
    --root "$WORK/root" \
    --component-plist "$WORK/component.plist" \
    --scripts "$WORK/scripts" \
    --identifier com.alexluncan.PorchLight.pkg \
    --version "$version" \
    --install-location / \
    "$WORK/PorchLight-component.pkg"
productbuild --package "$WORK/PorchLight-component.pkg" --sign "$installer_identity" --timestamp "$PKG"

# 4. Notarize the package, staple it, and check both the way Gatekeeper will.
notarize "$PKG"
xcrun stapler staple "$PKG"
spctl --assess --type install --verbose=2 "$PKG"
spctl --assess --type execute --verbose=2 "$APP"

rm -rf "$WORK"
(cd "$DIST" && shasum -a 256 "PorchLight-$version.pkg" > "PorchLight-$version.pkg.sha256")
echo "release.sh: built $PKG"
cat "$DIST/PorchLight-$version.pkg.sha256"
