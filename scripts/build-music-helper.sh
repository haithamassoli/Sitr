#!/bin/bash
# Assemble a self-contained macOS arm64 helper at build/SitrMusicHelper.app.
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON="${MUSIC_PYTHON:-/opt/homebrew/opt/python@3.12/bin/python3.12}"
[ -x "$PYTHON" ] || PYTHON="$(command -v python3.12 || true)"
[ -n "$PYTHON" ] && [ -x "$PYTHON" ] || { echo 'Python 3.12 is required to build the helper' >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo 'Build the helper on Apple Silicon' >&2; exit 1; }

VENV=.build/music-venv
if [ ! -x "$VENV/bin/python" ]; then "$PYTHON" -m venv "$VENV"; fi
if command -v uv >/dev/null; then
  uv pip install --python "$VENV/bin/python" -r MusicBackend/requirements.txt pyinstaller imageio-ffmpeg
else
  "$VENV/bin/python" -m pip install -r MusicBackend/requirements.txt pyinstaller imageio-ffmpeg
fi

WORK=.build/music-helper
mkdir -p "$WORK/downloads"
# The official Deno binary has no Homebrew library dependencies.
DENO_VERSION=2.9.7
DENO_ZIP="$WORK/downloads/deno-$DENO_VERSION-aarch64-apple-darwin.zip"
if [ ! -f "$DENO_ZIP" ]; then
  curl -fL --retry 2 "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-aarch64-apple-darwin.zip" -o "$DENO_ZIP"
fi
printf '%s  %s\n' '5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c' "$DENO_ZIP" | shasum -a 256 -c -

FFPROBE_TGZ="$WORK/downloads/ffprobe-darwin-arm64-5.0.1.tgz"
if [ ! -f "$FFPROBE_TGZ" ]; then
  curl -fL --retry 2 'https://registry.npmjs.org/@ffprobe-installer/darwin-arm64/-/darwin-arm64-5.0.1.tgz' -o "$FFPROBE_TGZ"
fi
printf '%s  %s\n' '27069fc32879761968823c3ce5353d3c6573f5df7d83d40b60bc2d878e886d39' "$FFPROBE_TGZ" | shasum -a 256 -c -

# No model weights in the bundle: the helper downloads htdemucs from Meta on first use (hash-checked by demucs).
"$VENV/bin/pyinstaller" --noconfirm --windowed --onedir \
  --name SitrMusicHelper --osx-bundle-identifier com.goldentik.Sitr.MusicHelper \
  --distpath "$WORK/dist" --workpath "$WORK/pyinstaller" --specpath "$WORK" \
  --paths MusicBackend --hidden-import engines.mlx_engine --hidden-import numpy.core.multiarray \
  --collect-all demucs --collect-all yt_dlp \
  --collect-all yt_dlp_ejs --collect-all certifi \
  MusicBackend/server.py

APP="$WORK/dist/SitrMusicHelper.app"
mkdir -p "$APP/Contents/Resources/bin" "$APP/Contents/Resources/licenses"
cp "$("$VENV/bin/python" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')" "$APP/Contents/Resources/bin/ffmpeg"
unzip -p "$DENO_ZIP" deno > "$APP/Contents/Resources/bin/deno"
tar xOzf "$FFPROBE_TGZ" package/ffprobe > "$APP/Contents/Resources/bin/ffprobe"
chmod 755 "$APP/Contents/Resources/bin/ffmpeg" "$APP/Contents/Resources/bin/ffprobe" "$APP/Contents/Resources/bin/deno"
cp MusicBackend/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp MusicBackend/licenses/* "$APP/Contents/Resources/licenses/"

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Set :LSUIElement true' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 15.0' "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 15.0' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Sitr Music Helper' "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Sitr Music Helper' "$PLIST"

SIGN_ID="${MUSIC_SIGN_ID:--}"
TIMESTAMP=--timestamp; [ "$SIGN_ID" = - ] && TIMESTAMP=--timestamp=none
codesign --force --sign "$SIGN_ID" --options runtime "$TIMESTAMP" "$APP/Contents/Resources/bin/ffmpeg" "$APP/Contents/Resources/bin/ffprobe" "$APP/Contents/Resources/bin/deno"
codesign --force --deep --sign "$SIGN_ID" --options runtime "$TIMESTAMP" --entitlements MusicBackend/Helper.entitlements "$APP"
rm -rf build/SitrMusicHelper.app
cp -R "$APP" build/SitrMusicHelper.app
codesign --verify --deep --strict build/SitrMusicHelper.app
echo 'built build/SitrMusicHelper.app'
