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
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -d App/Resources ] && cp -R App/Resources/. "$APP/Contents/Resources/"
# Classifier model (M2-T07): compile the shipped .mlpackage into the bundle.
if [ -d Models/dist/GenderClassifier.mlpackage ]; then
  xcrun coremlcompiler compile Models/dist/GenderClassifier.mlpackage "$APP/Contents/Resources" >/dev/null
fi

TS=--timestamp; [ "$SIGN_ID" = "-" ] && TS=--timestamp=none
codesign --force --sign "$SIGN_ID" --options runtime $TS --entitlements App/Sitr.entitlements "$APP"
echo "built $APP ($CONFIG, sign=$SIGN_ID)"
