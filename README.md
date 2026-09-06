# Sitr

[العربية](README.ar.md)

Sitr is a macOS menu bar app that hides people on your screen as they appear — women, men, or everyone — in every
app: browsers, chat apps, photo libraries, video players, video calls. It captures the screen with ScreenCaptureKit,
finds people with Core ML on the Neural Engine, classifies each one as Woman, Man, or Unknown, and covers the whole
body of everyone in the category you chose with a blur, pixelation, or a solid block.

Everything runs on your Mac. Sitr is sandboxed and ships without a network entitlement, so it cannot open a network
socket: no pixels, logs, telemetry, or crash reports leave the machine. Frames stay in memory and are never written
to disk. You can check this yourself, see [Verify the privacy claim](#verify-the-privacy-claim).

## Requirements

- macOS 15 or later.
- A Mac with Apple silicon (M1 or newer). Intel Macs are not supported.
- The Screen & System Audio Recording permission (video only; Sitr never records audio).

## Install

**DMG.** Download `Sitr-<version>.dmg` from [GitHub Releases](https://github.com/haithamassoli/Sitr/releases), open
it, drag `Sitr` to `Applications`, and launch it. Release builds are Developer ID signed and notarized. The
`checksums.txt` file next to the DMG carries its SHA-256; `shasum -a 256 Sitr-<version>.dmg` must print the same line.

**Homebrew** (available after the first release):

```sh
brew install --cask haithamassoli/sitr/sitr
```

## First run

Sitr has no Dock icon; look for the eye-slash icon in the menu bar. The first launch opens a five-step setup window:

1. What Sitr does, and the verification command.
2. **Screen Recording.** Click *Allow Screen Recording* and approve the macOS dialog, or open System Settings ›
   Privacy & Security › Screen & System Audio Recording and turn Sitr on. Setup continues on its own once the
   permission is granted. Without it Sitr covers nothing and shows a warning icon.
3. **Who should be hidden:** Women, Men, or Everyone. *Blur Unknown (Strict Mode)* is on by default and also covers
   people Sitr cannot classify; Everyone always includes them.
4. **Recommended Protection:** apply the preset below, or configure the rules yourself.
5. The Reveal Hold shortcut, and *Launch at login*.

### Monthly re-approval

Starting with macOS 15.1, macOS asks you to re-approve screen recording for every app roughly once a month. When the
grant lapses, Sitr's menu bar icon gets a warning badge, the status line reads *Needs Screen Recording permission*,
one notification is posted, and the permission step of the setup window comes back. Until capture resumes, apps in
Curtain mode are covered with a solid block over each window; apps in Blur mode are uncovered.

## How protection works

Every app runs in one of three modes:

| Mode | What happens |
|---|---|
| **Off** | The app is never captured or analyzed. |
| **Blur** | Frames are captured and analyzed; people in the hidden set are covered as soon as they are detected, roughly 100–200 ms after they appear. |
| **Curtain** | Changed regions of the app's windows are covered the moment they change, then uncovered once detection has verified them safe. Exposure is bounded by capture-to-draw latency, not zero. A region that keeps changing and stays safe for half a second (video without people, a long scroll) behaves like Blur until it is static again. |

The **Default Rule** is the mode for every app without an override. Its initial value is Off, so a fresh install
covers nothing until you add rules; setting it to Blur or Curtain protects the entire Mac. **Overrides** in Settings ›
Protection assign a mode per app: pick a running app, or any `.app` file.

**Recommended preset**, offered during setup and available in Settings › Protection › *Use recommended settings*
(the Default Rule stays Off):

| Group | Apps | Mode |
|---|---|---|
| Browsers | Safari, Chrome, Arc | Curtain |
| Communication | Telegram, WhatsApp, Discord | Curtain |

**Categories.** Each detected person is Woman, Man, or Unknown. Unknown means facing away, face hidden or too small,
too far, or classifier confidence below 80 %. The hidden set is Women, Men, or Everyone. *Blur Unknown (Strict Mode)*
adds Unknown to the hidden set; it is forced on for Everyone.

**Covers.** The full body box, expanded by *Body Padding* (default 15 %), is covered with the style chosen in
Settings › Appearance: Gaussian blur (default, strength 70 %), Pixelate, or Solid. A cover appears on the first
detected frame and lingers briefly after the person leaves, so it does not flicker.

**Reveal Hold.** Hold ⌃⌥Space to see what is under the covers on every display; release to cover again. As a safety
net the covers come back after 30 seconds of holding, or when the modifier keys are released without a matching
key-up event. Reveal is unavailable while protection is paused or disabled, or while the permission is missing.
Change the shortcut in Settings › Shortcuts; ⌥Space is refused because Siri and the ChatGPT app use it.

**Menu bar.** The status line reads Protected, Paused until a time, Disabled, Needs Screen Recording permission, or
Degraded. *Pause Protection* for 15 minutes or 1 hour removes all covers and resumes on its own; *Disable Protection*
stays off until you enable it again. The icon is dimmed while paused or disabled and carries a warning badge when the
permission is missing or detection is running slowly.

## Verify the privacy claim

Run this in Terminal (Settings › About shows the same command with a Copy button):

```sh
codesign -d --entitlements :- --xml /Applications/Sitr.app
```

Expected output (append `| plutil -convert xml1 -o - -` to the command for this indented form):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
</dict>
</plist>
```

`com.apple.security.app-sandbox` is `true`, and there is no `com.apple.security.network.client` or
`com.apple.security.network.server` key: the sandbox refuses every socket the process could try to open. The second
entitlement only lets Sitr read the bundle identifier of an `.app` you pick in the Add dialog of Settings › Protection.
CI runs the same check on every build (`scripts/check-entitlements.sh`).

## Screen sharing and screenshots

- **Sharing your entire screen** (Zoom, FaceTime, Meet, …): the overlay is a normal window above everything else, so
  viewers usually see the covers.
- **Sharing a single window:** the overlay is not part of that window, so covers are not guaranteed to reach the
  viewers.
- **Screenshots and screen recordings** include the covers.

Sitr does not try to hide its covers from screen sharing or screenshots: a person who is covered on your screen is
covered in the capture as well.

## Performance

Detection runs at up to 15 frames per second (8 in Low Power Mode when the Settings › General toggle is on), only on
the displays and apps that need it, and skips frames in which nothing changed. The targets Sitr is built and measured
against on an M1 with 8 GB are: person visible to covered in at most 150 ms (95th percentile) in Blur mode and 50 ms
in Curtain mode; Reveal press or release within one frame; under 1 % CPU on a static screen, about 15 % of one
performance core while browsing, about 25 % during 1080p video with people; under 300 MB of memory. Later chips do
correspondingly better. A saturated GPU (games, video export) can delay covers, which the menu bar reports as Degraded.

## Build from source

Requirements: Xcode 26 (Swift 6, macOS 15 SDK) on Apple silicon. There is no Xcode project; Sitr is a Swift package.

```sh
git clone https://github.com/haithamassoli/Sitr.git && cd Sitr
swift build                                    # every target
swift test                                     # unit tests: policy, tracker, curtain, settings, onboarding, localization, model checksums
scripts/build-app.sh                           # assembles build/Sitr.app: Info.plist, Core ML models, String Catalog, ad-hoc signature
scripts/check-entitlements.sh build/Sitr.app   # sandbox on, no network entitlement
scripts/check-strings.sh                       # every UI string is in the String Catalog with an Arabic translation
```

`build/Sitr.app` is signed ad hoc, so macOS treats it as an app you built yourself; launch it from Finder or run
`build/Sitr.app/Contents/MacOS/Sitr` from a terminal. Release builds come from `scripts/release.sh` and
`scripts/make-dmg.sh`, see `docs/m5/release.md`.

The two Core ML models are committed under `Models/dist/`: no download step, no build-time network access.
`Models/dist/CHECKSUMS.txt` and `Models/dist/CHECKSUMS-PersonDetector.txt` list the SHA-256 of every file inside the
packages, and the `ModelChecksumTests` test fails when anything differs. By hand:
`cd Models/dist && shasum -a 256 -c CHECKSUMS.txt CHECKSUMS-PersonDetector.txt`.

## Models and licenses

| Model | Origin | License |
|---|---|---|
| Person detector, `PersonDetector.mlpackage` | YOLOX-S by Megvii Inc., converted to Core ML without retraining | Apache-2.0 |
| Gender classifier, `GenderClassifier.mlpackage` | `dima806/fairface_gender_image_detection` (ViT-B/16), converted to Core ML without retraining; trained on FairFace | Apache-2.0; FairFace is CC BY 4.0 |

Provenance, conversion commands, and the full license texts: [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md),
`Models/dist/SOURCE.md`, `Models/dist/SOURCE-PersonDetector.md`. Sitr has no Swift package dependencies.

## Languages

English and Arabic, with a right-to-left layout for Arabic. Sitr follows the system language order; Settings ›
General › Language overrides it for Sitr alone, and the change applies after a relaunch.

## Uninstall

1. Quit Sitr from the menu bar (*Quit Sitr*).
2. Delete `/Applications/Sitr.app`.
3. Delete `~/Library/Containers/com.goldentik.Sitr`, the sandbox container that holds your settings and the rules file.
4. If *Launch at login* was on, remove Sitr from System Settings › General › Login Items & Extensions (deleting the
   app usually removes the entry on its own).

With Homebrew, `brew uninstall --zap --cask sitr` removes the app and the container.

## License

GPL-3.0-only, see [`LICENSE`](LICENSE). Security reports: [`SECURITY.md`](SECURITY.md). Contributions:
[`CONTRIBUTING.md`](CONTRIBUTING.md).
