# VoiceBarDictate (Native macOS Menu Bar Dictation)

Native SwiftUI/AppKit menu bar app for dictation using OpenAI or on-device Apple speech-to-text.

## Features

- Menu bar app. Click the icon for the dictation panel: start or stop dictation, switch between OpenAI and
  on-device, and copy or paste the last transcript again. Right-click it for Settings and Quit.
- Dark mode only. The design reference is in [`docs/design`](docs/design).
- Global hotkey, `Control + Option + Space` by default. Change it in Settings.
- Two shortcut behaviors:
  - **Toggle** (default): press once to start recording, press again to stop and transcribe
  - **Hold to talk**: record while the shortcut is held, transcribe on release
- While dictating, a small overlay shows a timer, an input level meter, and live text for on-device. `Escape`
  cancels and `Return` finishes; you can also click **Insert** or **Cancel** in the overlay. It shows
  "Transcribing…" after you stop and disappears as soon as the text is pasted.
- **OpenAI** (default) records to a local 16 kHz m4a and uploads it to `/v1/audio/transcriptions` when you stop. The model ID (`gpt-transcribe` by default) is configurable.
- **Apple On-Device** transcribes locally without an API key on supported Macs running macOS 26 or later. Audio streams into Apple's SpeechAnalyzer while you speak, so partial text appears in the overlay and the result is ready almost as soon as you stop. The language model downloads in the background when you first select this engine.
- Pastes the transcript into the active app with a synthetic `Cmd+V`, then restores your previous clipboard. The temporary clipboard entry is marked transient, so clipboard managers ignore it.
- API key stored in macOS Keychain
- Low idle CPU usage (no always-on audio processing)
- Optional start-at-login toggle (when running from the signed `.app` bundle)

## Run

Building from source requires Xcode 26 or later with the macOS 26 SDK or later for Apple’s SpeechAnalyzer APIs.
The app runs on macOS 14 or later. Apple On-Device requires macOS 26 or later and a supported Mac.

```bash
cd VoiceBarDictate
swift run
```

## Test

```bash
swift test
```

Tests use Swift Testing and cover settings persistence and migration, `.env` parsing, OpenAI request building and regional endpoint hints, shortcut validation, and the audio conversion and m4a encoding pipeline. Microphone capture, transcription, and paste injection still need manual verification.

## Run Without Terminal (Dockless Menu Bar App)

Build a real `.app` bundle (agent app), then launch it from Finder. The app runs in the menu bar only and does not show in the Dock.

```bash
OPEN_APP=1 ./scripts/build-app-bundle.sh
```

The bundle identifier defaults to `dev.arai.VoiceBarDictate`. Override it with `PRODUCT_BUNDLE_IDENTIFIER`, but keep it stable: macOS ties microphone and Accessibility permissions to it. `APP_VERSION` and `BUILD_NUMBER` set the bundle version.

After launch, right-click the menu bar icon and choose **Quit VoiceBar** to exit.

Optional local signing certificate. Ad-hoc builds get a new signature every time, so macOS drops the
Accessibility approval after each rebuild; signing with a stable certificate (any identity from
`security find-identity -v -p codesigning`) keeps it:

```bash
SIGNING_MODE=selfcert \
CODE_SIGN_IDENTITY="VoiceBarDictate Local Self Sign" \
OPEN_APP=1 \
./scripts/build-app-bundle.sh
```

Developer ID signing with the hardened runtime, for distribution:

```bash
SIGNING_MODE=developer-id \
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./scripts/build-app-bundle.sh
```

## Release Signing and Notarization

Ad-hoc signatures change on every build, so macOS asks users to grant microphone and Accessibility permission again after each update. Signing with a Developer ID certificate and notarizing avoids that, and removes the Gatekeeper warning on first launch.

The release workflow (`.github/workflows/release-dmg.yml`) signs and notarizes automatically when these repository secrets are set. Without them it falls back to an ad-hoc build and logs a warning.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64 of the exported "Developer ID Application" certificate (`.p12`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `NOTARY_KEY_P8` | Contents of the App Store Connect API key (`AuthKey_XXXX.p8`) |
| `NOTARY_KEY_ID` | API key ID |
| `NOTARY_ISSUER_ID` | API issuer ID |

To notarize locally, build and sign the DMG, then run:

```bash
NOTARY_KEY_PATH=~/keys/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER_ID=xxxx-xxxx \
./scripts/notarize.sh dist/VoiceBarDictate.dmg
```

## Xcode Signing (Local)

This repository is a pure Swift package, so code signing values are applied locally (Xcode/xcodebuild), not persisted in `Package.swift`.

No Apple Developer membership is required for local self-signing.

1. Install full Xcode and point `xcode-select` at it:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

2. Build with default ad-hoc signing (recommended if you do not have an Apple Developer account):

```bash
./scripts/xcode-build-signed.sh
```

3. Optional: use your own local self-signed cert from Keychain:

```bash
SIGNING_MODE=selfcert \
CODE_SIGN_IDENTITY="My Local Mac Dev Cert" \
./scripts/xcode-build-signed.sh
```

4. Optional overrides:
   - `SIGNING_MODE` (`auto` default; values: `adhoc`, `selfcert`, `apple`)
   - `DEVELOPMENT_TEAM` (only needed for `SIGNING_MODE=apple`)
   - `PRODUCT_BUNDLE_IDENTIFIER` (default: `dev.arai.VoiceBarDictate`)
   - `CONFIGURATION` (default: `Debug`)
   - `DERIVED_DATA_PATH` (default: `.build/XcodeDerivedData`)

## Use `.env` For API Key (Debug Builds Only)

In debug builds, if a `.env` file exists in the working directory or any parent, the app uses `OPENAI_API_KEY` from it and skips Keychain access. Release builds ignore `.env` files.

```bash
cp .env.example .env
# edit .env and set OPENAI_API_KEY
swift run
```

## Setup

1. Launch the app (from `swift run` or Xcode).
2. Open Settings: right-click the menu bar icon and choose **Settings…**, or use the `⋯` button in the panel.
3. Choose an engine. For OpenAI, paste your OpenAI API key.
4. If you use OpenAI with a regional project, set the API Base URL:
   - EU: `https://eu.api.openai.com`
   - US: `https://us.api.openai.com`
5. Optional: click the shortcut to record a new one, and choose toggle or hold-to-talk.
6. Grant microphone permission when prompted.
7. On first launch, the app shows the macOS Accessibility prompt. If you skip it, the panel shows a notice
   that opens System Settings. Once you enable it, the app picks it up without restarting. It relaunches only
   if macOS does not allow key capture yet.
8. To run at login, open Settings and enable **Start at login**.

## Upgrading

- Settings from earlier versions that stored a retired OpenAI model ID (for example `gpt-4o-mini-transcribe`) switch to `gpt-transcribe` on first launch, and the panel says so once.
- An API key saved under the old `com.codex.voicebardictate` Keychain service moves to `dev.arai.VoiceBarDictate` the first time it is read.

## Notes

- If you run this via Terminal (`swift run`), macOS may attribute privacy prompts to Terminal.
- For regular daily use, open `Package.swift` in Xcode and run it from Xcode so permissions are tied to the app/debug target.
