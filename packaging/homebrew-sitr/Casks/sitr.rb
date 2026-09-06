# Homebrew cask for Sitr. This file is the source of truth; its home at install time is the tap repository
# github.com/haithamassoli/homebrew-sitr, at the same path (Casks/sitr.rb), so that
# `brew install --cask haithamassoli/sitr/sitr` finds it. `scripts/bump-cask.sh` (run by
# .github/workflows/release.yml on a v* tag) rewrites `version` and `sha256` below and pushes the result to the tap;
# the values committed here are placeholders until the first release exists.
# The repository owner is hard-coded in `url` and `homepage`: change both if the public repo ever moves.
cask "sitr" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/haithamassoli/Sitr/releases/download/v#{version}/Sitr-#{version}.dmg"
  name "Sitr"
  desc "Menu bar app that covers people on screen with a blur, on device"
  homepage "https://github.com/haithamassoli/Sitr"

  # `releases/latest` skips pre-releases, and the regex keeps it that way: v0.1.0 matches, v0.1.0-rc1 does not.
  livecheck do
    url :url
    strategy :github_latest
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  # App/Info.plist: LSMinimumSystemVersion 15.0. Apple silicon only (Core ML on the Neural Engine, README Requirements).
  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "Sitr.app"

  # LSUIElement app: no Dock icon, so brew has to be the one to quit it before replacing the bundle.
  uninstall quit: "com.goldentik.Sitr"

  # com.goldentik.Sitr is CFBundleIdentifier (App/Info.plist) and therefore the UserDefaults domain
  # (Sources/Sitr/Preferences.swift uses UserDefaults.standard). The app is sandboxed (App/Sitr.entitlements), so the
  # live copies of both the defaults plist and of Application Support/Sitr (rules.json, rules.json.bak — see
  # Sources/SitrCore/Rules.swift and AppModel.rulesDirectory) sit inside the container; the unsandboxed paths are
  # listed as well because a locally built, ad-hoc signed run writes those instead.
  zap trash: [
    "~/Library/Application Support/Sitr",
    "~/Library/Caches/com.goldentik.Sitr",
    "~/Library/Containers/com.goldentik.Sitr",
    "~/Library/Preferences/com.goldentik.Sitr.plist",
    "~/Library/Saved Application State/com.goldentik.Sitr.savedState",
  ]
  # Not zapped: the Launch at login entry (SMAppService.mainApp, Sources/Sitr/LaunchAtLogin.swift) lives in the
  # BackgroundItems database, which macOS prunes when the app is deleted; `zap login_item:` drives System Events and
  # does not see SMAppService registrations. The Screen Recording grant is TCC state, cleared with
  # `tccutil reset ScreenCapture com.goldentik.Sitr`.
end
