# Chrome Web Store Listing — Sitr Music

> Last Updated: 2026-09-27 · Ready to submit (upload `build/sitr-music-extension-0.2.0.zip`)

## Store Listing

**Extension Name:** Sitr Music

**Short Description:** Remove music from web videos while keeping speech with the Sitr app.

**Detailed Description:**

Sitr Music lets you listen to speech in web videos with the music reduced.

Install the Sitr app (https://github.com/haithamassoli/Sitr/releases) and turn on Settings › Music. Then open a video and press the "Remove music" button on the video. Press it again to return to the original sound. You can optionally keep some effects and ambient sounds, or download the processed audio or video.

Separation runs on your Mac. Results vary by video: singing can remain with speech, and the optional effects setting can let some music through. Some sites or protected videos cannot be processed. The Sitr app is required.

The extension sends the current video's URL to the local Sitr service, which may download source audio from the video provider. Audio processing stays on the device. The extension does not include analytics.

**Category:** Accessibility

**Single Purpose:** Reduce music in web videos while preserving speech using the local Sitr app.

**Primary Language:** Arabic

## Graphics & Assets

| Asset | Dimensions | Status | Filename |
|---|---:|---|---|
| Store icon | 128×128 PNG | Ready | `icons/icon-128.png` |
| Screenshot | 1280×800 | Ready | `docs/chrome-web-store/screenshot-1280x800.png` |

## Permissions Justification

| Permission | Type | Justification |
|---|---|---|
| `storage` | permission | Saves the user's optional choice to retain effects so it is applied on future videos. Chrome may sync this choice between signed-in browser profiles. |
| `downloads` | permission | Saves MP3 audio or MP4 video only when the user picks a download format from the video control. |
| `http://127.0.0.1:8724/*` | host permission | Connects the extension to the Sitr Music service running on the user's own Mac to start processing and play the processed audio. |
| `<all_urls>` in `content_scripts` and `web_accessible_resources` | page access | Finds video players and places the user-operated Sitr Music control over them across video sites. It reads a page's video URL only after the user starts processing. |

## Privacy & Data Use

The extension does not send analytics or browsing history to Sitr. When the user presses the video control, it sends that video's URL and the chosen audio setting to the local service at `127.0.0.1:8724`. The local service may contact the video's provider to download its audio and stores temporary processing files on the Mac. The optional effects choice is saved in `chrome.storage.sync`, which may sync through the user's Chrome account. The user can delete the local processing cache from the popup.

- [x] Data is not sold to third parties.
- [x] Data is not used for unrelated purposes.
- [x] Data is not used for creditworthiness or lending.

**Privacy policy URL:** https://github.com/haithamassoli/Sitr/blob/main/browser-extension/PRIVACY.md

## Distribution

**Visibility:** Public

**Regions:** All regions

**Publisher name:** the name on your Chrome Web Store developer account

**Contact email:** your developer account email (verified in the dashboard)

**Support URL:** https://github.com/haithamassoli/Sitr/issues

## Version History

| Version | Date | Changes | Status |
|---|---|---|---|
| 0.1.0 | 2026-09-26 | Initial Sitr Music extension and Arabic onboarding | Draft |
| 0.2.0 | 2026-09-27 | YouTube ad handling, lower memory, sync fixes | Ready to submit |

## Review Notes

Build the upload with `browser-extension/package.sh` (writes `build/sitr-music-extension-<version>.zip`, without tests
and store notes). After approval, set `MusicService.storeURL` in `Sources/Sitr/UI/MusicTab.swift` to the listing URL:
the Music tab then shows one **Add to Chrome** button instead of the manual steps.
