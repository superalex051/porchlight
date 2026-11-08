#!/usr/bin/env bash
# Builds build/PorchLight.app with its helpers inside, signs it inner to outer with the Apple
# Development identity, and verifies it. Never ad-hoc, because macOS would then ask for every permission
# again after each rebuild. A build changes no display state: this neither installs nor launches anything.
set -euo pipefail
exec </dev/null

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
    echo "build.sh: $1" >&2
    exit 1
}

SIGNING_CONFIG="Config/Signing.local.xcconfig"
IDENTITY="Apple Development"
DERIVED="build/DerivedData"
APP="build/PorchLight.app"
HELPERS="$APP/Contents/Helpers"

[ -f "$SIGNING_CONFIG" ] || fail "$SIGNING_CONFIG is missing. Run Scripts/bootstrap.sh."
[ -d PorchLight.xcodeproj ] || fail "PorchLight.xcodeproj is missing. Run Scripts/gen.sh."
team="$(sed -nE 's/^DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' "$SIGNING_CONFIG")"
[ -n "$team" ] || fail "$SIGNING_CONFIG has no DEVELOPMENT_TEAM. Run Scripts/bootstrap.sh."

swift build -c release --product porchlight
swift build -c release --product porchlight-guardian
bin_path="$(swift build -c release --show-bin-path)"

xcodebuild \
    -project PorchLight.xcodeproj \
    -scheme PorchLight \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' \
    build

# A copy of what Xcode made, so its own incremental state never sees the helpers.
rm -rf "$APP"
ditto "$DERIVED/Build/Products/Release/PorchLight.app" "$APP"
mkdir -p "$HELPERS"
cp "$bin_path/porchlight" "$bin_path/porchlight-guardian" "$HELPERS/"

# Inner to outer, because the app's signature covers the helpers. Fixed identifiers, because the default
# for a loose binary can change from build to build, and permissions are tied to it.
sign() {
    codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$@"
}
sign --identifier com.alexluncan.PorchLight.cli "$HELPERS/porchlight"
sign --identifier com.alexluncan.PorchLight.guardian "$HELPERS/porchlight-guardian"
sign --entitlements Config/PorchLight.entitlements "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

# The same team on all three, which also proves that none of them is ad-hoc.
for code in "$HELPERS/porchlight" "$HELPERS/porchlight-guardian" "$APP"; do
    details="$(codesign -dv --verbose=2 "$code" 2>&1)"
    case "$details" in
        *"TeamIdentifier=$team"*) ;;
        *) fail "$code isn't signed by the team in $SIGNING_CONFIG." ;;
    esac
    case "$details" in
        *"Authority=Apple Development"*) ;;
        *) fail "$code isn't signed with an Apple Development identity." ;;
    esac
    case "$details" in
        *"(runtime)"*) ;;
        *) fail "$code doesn't have the hardened runtime." ;;
    esac
done

echo "build.sh: built and signed $APP"
