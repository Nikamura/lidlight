#!/bin/sh
# Build, notarize, staple, and verify a Developer ID-signed release.
set -eu
cd "$(dirname "$0")"

case "${1:-}" in
  --help|-h)
    echo 'Usage: VERSION=x.y.z SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" ./release.sh [--check]'
    echo 'NOTARY_PROFILE defaults to lidlight-notary (credentials stored in Keychain).'
    exit 0
    ;;
  ""|--check) ;;
  *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

: "${VERSION:?Set VERSION to the release version.}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to the full Developer ID Application identity name.}"
NOTARY_PROFILE="${NOTARY_PROFILE:-lidlight-notary}"
export VERSION SIGNING_IDENTITY

case "$SIGNING_IDENTITY" in
  "Developer ID Application: "*) ;;
  *) echo "A Developer ID Application certificate is required; ad-hoc/development signing cannot notarize a release." >&2; exit 1 ;;
esac

# Check credentials before building, without exposing them or silently falling
# back to an unsigned release. Exact full-name matching avoids another team.
if ! security find-identity -v -p codesigning | /usr/bin/awk -v identity="$SIGNING_IDENTITY" '
    index($0, "\"" identity "\"") { found = 1 }
    END { exit !found }
'; then
  echo "Signing identity not found in Keychain: $SIGNING_IDENTITY" >&2
  echo "See SIGNING.md to create or import the certificate and its private key." >&2
  exit 1
fi
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null
if [ "${1:-}" = --check ]; then
  echo "Signing identity and notarization credentials are available."
  exit 0
fi

./build.sh --zip
APP=build/Lidlight.app
ZIP=build/Lidlight.zip
RESULT=build/notarization.json

if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$RESULT"; then
  echo "Notarization did not complete successfully. The ZIP is not ready to publish." >&2
  echo "Check $RESULT and: xcrun notarytool history --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi
STATUS=$(/usr/bin/plutil -extract status raw -o - "$RESULT")
if [ "$STATUS" != Accepted ]; then
  SUBMISSION=$(/usr/bin/plutil -extract id raw -o - "$RESULT")
  echo "Notarization status: $STATUS" >&2
  echo "Inspect: xcrun notarytool log $SUBMISSION --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi

# ZIPs cannot be stapled. Staple the app, then recreate the distributable ZIP.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 Lidlight.zip > Lidlight.zip.sha256)
echo "Verified notarized release: $ZIP ($VERSION)"
echo "Download and test a quarantined copy before publishing. See SIGNING.md."
