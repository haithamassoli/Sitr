#!/bin/bash
# Assemble build/Sitr.app from the SwiftPM build. Usage: scripts/build-app.sh [--debug] [--sign=<identity>]
# Ad-hoc signed by default (runs locally, sandboxed). scripts/release.sh wraps this with Developer ID + notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=release; SIGN_ID="-"
for a in "$@"; do case $a in --debug) CONFIG=debug;; --sign=*) SIGN_ID="${a#--sign=}";; esac; done

swift build -c "$CONFIG" --product Sitr
APP=build/Sitr.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Sitr" "$APP/Contents/MacOS/Sitr"
cp App/Info.plist "$APP/Contents/Info.plist"
# VERSION=x.y.z[-pre] (release.sh passes the tag) stamps the plist; CFBundleVersion takes the numeric part.
if [ -n "${VERSION:-}" ]; then
  V=${VERSION#v}
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" -c "Set :CFBundleVersion ${V%%-*}" "$APP/Contents/Info.plist"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -d App/Resources ] && cp -R App/Resources/. "$APP/Contents/Resources/"
# Shipped CoreML models (M1-T05 classifier, M1-T06b person detector): compile each .mlpackage into the bundle.
for m in Models/dist/*.mlpackage; do
  [ -d "$m" ] && xcrun coremlcompiler compile "$m" "$APP/Contents/Resources" >/dev/null
done

# Secure timestamp for real identities (notarization requires it); ad-hoc has no cert to timestamp.
TS=--timestamp; [ "$SIGN_ID" = "-" ] && TS=--timestamp=none
codesign --force --sign "$SIGN_ID" --options runtime $TS --entitlements App/Sitr.entitlements "$APP"
echo "built $APP ($CONFIG, sign=$SIGN_ID)"
