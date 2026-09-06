#!/bin/bash
# Renders packaging/homebrew-sitr/Casks/sitr.rb for a released version and pushes it to the Homebrew tap
# (github.com/<owner>/homebrew-sitr, path Casks/sitr.rb). Only `version` and `sha256` change; everything else in the
# cask — url template, livecheck, zap — comes from the file in this repo.
# Usage:
#   VERSION=0.1.0 [SHA256=<hex>] [TAP_REPO=haithamassoli/homebrew-sitr] [TAP_URL=<git url>] \
#   [HOMEBREW_TAP_TOKEN=<PAT with contents:write on the tap>] scripts/bump-cask.sh [--dry-run]
# VERSION defaults to App/Info.plist; SHA256 to the DMG's line in build/checksums.txt, else to hashing
# build/Sitr-$VERSION.dmg.
# Without HOMEBREW_TAP_TOKEN (forks, local runs) it writes and prints build/sitr.rb and exits 0 — a missing tap secret
# must never fail the release workflow, same contract as the unsigned-build fallback in release.yml.
# ponytail: the bump runs during the tagged build, so until the draft release is published the tap points at a URL
# that 404s. Ceiling: a few minutes of a broken `brew install`. Upgrade: a second workflow on `release: published`
# that downloads the asset and hashes it instead. See docs/m5/release.md.
set -euo pipefail
cd "$(dirname "$0")/.."
TEMPLATE=packaging/homebrew-sitr/Casks/sitr.rb
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
VERSION=${VERSION:-$(plutil -extract CFBundleShortVersionString raw App/Info.plist)}; VERSION=${VERSION#v}
DMG=Sitr-$VERSION.dmg

# SHA-256 of the release asset: explicit, else the make-dmg.sh line ("<hash>  <file>"), else the local DMG.
SHA=${SHA256:-}
[ -n "$SHA" ] || [ ! -f build/checksums.txt ] || SHA=$(awk -v f="$DMG" '$2 == f { print $1 }' build/checksums.txt)
[ -n "$SHA" ] || [ ! -f "build/$DMG" ] || SHA=$(shasum -a 256 "build/$DMG" | awk '{ print $1 }')
[ -n "$SHA" ] || { echo "bump-cask.sh: no SHA-256 for $DMG; run scripts/make-dmg.sh first or pass SHA256=<hex>"; exit 1; }
[[ $SHA =~ ^[0-9a-f]{64}$ ]] || { echo "bump-cask.sh: SHA256 is not 64 lowercase hex characters: $SHA"; exit 1; }

mkdir -p build
sed -e "s|^  version \".*\"\$|  version \"$VERSION\"|" \
    -e "s|^  sha256 \".*\"\$|  sha256 \"$SHA\"|" "$TEMPLATE" > build/sitr.rb
if ! grep -qx "  version \"$VERSION\"" build/sitr.rb || ! grep -qx "  sha256 \"$SHA\"" build/sitr.rb; then
  echo "bump-cask.sh: $TEMPLATE no longer has plain 'version'/'sha256' lines to rewrite"; exit 1
fi
! command -v ruby >/dev/null || ruby -c build/sitr.rb

TAP_REPO=${TAP_REPO:-haithamassoli/homebrew-sitr}
TAP_URL=${TAP_URL:-https://github.com/$TAP_REPO.git}
if [ $DRY = 1 ] || [ -z "${HOMEBREW_TAP_TOKEN:-}" ]; then
  [ $DRY = 1 ] || echo "::notice::No HOMEBREW_TAP_TOKEN secret: cask rendered but not pushed to $TAP_REPO."
  echo "bump-cask.sh: not pushing. Copy build/sitr.rb into $TAP_REPO as Casks/sitr.rb by hand (docs/m5/release.md):"
  cat build/sitr.rb
  exit 0
fi

# The token reaches git through GIT_ASKPASS reading the environment: never in a remote URL, in .git/config, or on disk.
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# shellcheck disable=SC2016  # deliberate: the askpass script must read $HOMEBREW_TAP_TOKEN when git runs it, not now.
printf '#!/bin/sh\ncase "$1" in Username*) echo x-access-token ;; *) echo "$HOMEBREW_TAP_TOKEN" ;; esac\n' > "$WORK/askpass"
chmod +x "$WORK/askpass"
export HOMEBREW_TAP_TOKEN GIT_ASKPASS="$WORK/askpass" GIT_TERMINAL_PROMPT=0
git clone --depth 1 "$TAP_URL" "$WORK/tap"
mkdir -p "$WORK/tap/Casks"
cp build/sitr.rb "$WORK/tap/Casks/sitr.rb"
git -C "$WORK/tap" add Casks/sitr.rb
if git -C "$WORK/tap" diff --cached --quiet; then echo "bump-cask.sh: $TAP_REPO already carries sitr $VERSION"; exit 0; fi
git -C "$WORK/tap" -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -q -m "sitr $VERSION"
git -C "$WORK/tap" push origin HEAD
echo "bump-cask.sh: pushed sitr $VERSION (sha256 $SHA) to $TAP_REPO"
