#!/bin/bash
# Release build of build/Sitr.app: Developer ID signature, notarization, staple, Gatekeeper + entitlement checks.
# Usage:
#   VERSION=0.1.0 SIGN_ID="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=<xcrun notarytool store-credentials profile>            # or the API-key form:
#   NOTARY_KEY_ID=… NOTARY_ISSUER=… NOTARY_KEY_PATH=AuthKey_XXXX.p8 \
#   scripts/release.sh [--dry-run]
# --dry-run (implied by the default ad-hoc SIGN_ID="-") does everything except notarize + staple and prints those
# commands instead. VERSION defaults to App/Info.plist. Idempotent: build/ is recreated on every run.
set -euo pipefail
cd "$(dirname "$0")/.."
SIGN_ID=${SIGN_ID:--}
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1; [ "$SIGN_ID" = - ] && DRY=1
VERSION=${VERSION:-$(plutil -extract CFBundleShortVersionString raw App/Info.plist)}; VERSION=${VERSION#v}
APP=build/Sitr.app; ZIP=build/Sitr-$VERSION.zip

# notarytool credentials: a keychain profile or an App Store Connect API key. Required unless dry-running.
NOTARY=()
if [ -n "${NOTARY_PROFILE:-}" ]; then NOTARY=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY_ID:-}" ]; then NOTARY=(--key "${NOTARY_KEY_PATH:?}" --key-id "$NOTARY_KEY_ID" --issuer "${NOTARY_ISSUER:?}")
elif [ $DRY = 0 ]; then echo "release.sh: set NOTARY_PROFILE or NOTARY_KEY_ID/NOTARY_ISSUER/NOTARY_KEY_PATH, or pass --dry-run"; exit 2
fi

# ponytail: only build/ is wiped; .build/ stays (CI checkouts are clean anyway, `swift package clean` locally buys nothing).
rm -rf build
VERSION=$VERSION scripts/build-app.sh --sign="$SIGN_ID"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ $DRY = 1 ]; then
  echo "dry run (sign=$SIGN_ID): skipping notarization. Would run:"
  echo "  xcrun notarytool submit $ZIP --wait --timeout 30m ${NOTARY[*]:-<NOTARY_PROFILE or NOTARY_KEY_* credentials>}"
  echo "  xcrun stapler staple $APP && xcrun stapler validate $APP"
  spctl -a -vv --type exec "$APP" || echo "spctl rejected $APP: expected for an unnotarized build (pending credentials)"
else
  xcrun notarytool submit "$ZIP" --wait --timeout 30m "${NOTARY[@]}" | tee build/notarytool.log
  grep -q 'status: Accepted' build/notarytool.log \
    || { echo "notarization not accepted; inspect with: xcrun notarytool log <submission id> ${NOTARY[*]}"; exit 1; }
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -vv --type exec "$APP"
fi
scripts/check-entitlements.sh "$APP"
echo "release: $APP v$VERSION sign=$SIGN_ID notarized=$([ $DRY = 1 ] && echo no-dry-run || echo yes)"
