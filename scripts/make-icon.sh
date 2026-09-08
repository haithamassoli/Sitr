#!/bin/bash
# Rasterize App/Icon/icon.svg into App/Icon/AppIcon.icns. Run after editing the SVG; the .icns is committed
# so building the app needs neither Chrome nor this script.
# ponytail: one Chrome render at 1024 + sips downsampling. Chrome clamps tiny window sizes, so per-size
# --screenshot renders come out blank below ~128px.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SET=$(mktemp -d)/AppIcon.iconset; mkdir -p "$SET"
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --default-background-color=00000000 --window-size=1024,1024 \
  --screenshot="$SET/icon_512x512@2x.png" "file://$PWD/App/Icon/icon.svg" >/dev/null 2>&1
for n in icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 icon_128x128:128 \
         icon_128x128@2x:256 icon_256x256:256 icon_256x256@2x:512 icon_512x512:512; do
  sips -z "${n#*:}" "${n#*:}" "$SET/icon_512x512@2x.png" --out "$SET/${n%%:*}.png" >/dev/null
done
iconutil -c icns "$SET" -o App/Icon/AppIcon.icns
cp "$SET/icon_128x128@2x.png" App/Icon/icon.png
echo "wrote App/Icon/AppIcon.icns"
