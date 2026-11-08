#!/usr/bin/env bash
# Checks the tools the app build needs, then writes Config/Signing.local.xcconfig, which is gitignored,
# with the team of this Mac's Apple Development certificate. Changes nothing else.
set -euo pipefail
exec </dev/null

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
    echo "bootstrap.sh: $1" >&2
    exit 1
}

xcodebuild -version >/dev/null 2>&1 || fail "Xcode is missing or not selected. See xcode-select."
swift --version >/dev/null 2>&1 || fail "swift is missing."
command -v xcodegen >/dev/null 2>&1 || fail "XcodeGen is missing. Install it with: brew install xcodegen"

# codesign can't choose between two, and it would be a guess which one this build should use.
identities="$(security find-identity -v -p codesigning | grep '"Apple Development' || true)"
count="$(printf '%s' "$identities" | grep -c . || true)"
case "$count" in
    0) fail "no valid Apple Development identity in the keychain. Add an account in Xcode's settings." ;;
    1) ;;
    *) fail "$count Apple Development identities in the keychain, so the name alone doesn't pick one." ;;
esac

# The certificate of that valid identity, found by its SHA-1, so an expired one or another team's can't
# be read in its place.
sha1="$(printf '%s\n' "$identities" | awk '{ print toupper($2) }')"
certificate="$(security find-certificate -a -c "Apple Development" -Z -p | awk -v want="$sha1" '
    /^SHA-1 hash:/ { take = (toupper($3) == want); next }
    take { print; if ($0 ~ /-----END CERTIFICATE-----/) exit }
')"
[ -n "$certificate" ] || fail "the certificate of the valid Apple Development identity isn't in the keychain."

# The subject's OU is the team. The name in parentheses in the certificate's CN is not. openssl and
# LibreSSL print the subject differently, and this reads both.
subject="$(printf '%s\n' "$certificate" | openssl x509 -noout -subject)"
team="$(printf '%s\n' "$subject" | sed -nE 's/.*OU[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*/\1/p')"
[ -n "$team" ] || fail "the certificate's subject has no team in its OU."

cat > Config/Signing.local.xcconfig <<XCCONFIG
// Written by Scripts/bootstrap.sh. Not in git.
DEVELOPMENT_TEAM = $team
XCCONFIG

echo "bootstrap.sh: tools found, Config/Signing.local.xcconfig written"
