#!/bin/bash
# build/Sitr-<version>.dmg from build/Sitr.app: UDZO, volume "Sitr", /Applications symlink; SHA-256 line in
# build/checksums.txt (`shasum -a 256` format, one line per artifact). Verifies the image by mounting it read-only.
# Usage: scripts/make-dmg.sh   (after scripts/release.sh or scripts/build-app.sh; VERSION defaults to the app's plist)
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Sitr.app; [ -d "$APP" ] || { echo "make-dmg.sh: $APP missing; run scripts/release.sh first"; exit 1; }
VERSION=${VERSION:-$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")}; VERSION=${VERSION#v}
DMG=build/Sitr-$VERSION.dmg
STAGE=$(mktemp -d); MNT=$(mktemp -d)
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true; rm -rf "$STAGE" "$MNT"' EXIT  # || true: errexit applies in traps

# ponytail: plain hdiutil, no background art or icon layout (create-dmg is installed if that ever matters). The DMG
# itself is not notarized; the stapled app inside is what Gatekeeper assesses at launch. Upgrade: submit the DMG too.
# HFS+ on purpose: the default APFS image is auto-sized too small for -srcfolder ("No space left on device").
ditto "$APP" "$STAGE/Sitr.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Sitr -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" >/dev/null

# Verify: attach read-only, check the app and the Applications link, detach.
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$DMG" >/dev/null
[ -d "$MNT/Sitr.app" ] && [ -L "$MNT/Applications" ] || { echo "FAIL: $DMG lacks Sitr.app or Applications link"; ls -la "$MNT"; exit 1; }
codesign --verify --deep --strict "$MNT/Sitr.app"
hdiutil detach "$MNT" >/dev/null

# Checksums: replace any earlier line for this DMG, append, then recompute every listed artifact and compare.
cd build
{ [ -f checksums.txt ] && grep -v " $(basename "$DMG")\$" checksums.txt || true; } > checksums.tmp
mv checksums.tmp checksums.txt
shasum -a 256 "$(basename "$DMG")" >> checksums.txt
shasum -a 256 -c checksums.txt
echo "built $DMG ($(du -h "$(basename "$DMG")" | awk '{print $1}')); checksums in build/checksums.txt"
