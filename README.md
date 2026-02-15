# VoiceBarDictate (Native macOS Menu Bar Dictation)

Native SwiftUI/AppKit menu bar app for push-to-talk dictation using OpenAI speech-to-text.

## Features

- Menu bar app (`MenuBarExtra`)
- Global hotkey: `Control + Option + Space`
- Press once to start recording, press again to stop and transcribe
- Optional **Live Preview (Beta)** mode with realtime transcript text in HUD
- Live Preview pastes only final text (no partial text injection while speaking)
- Automatic fallback to standard file transcription if realtime streaming fails
- Uses OpenAI Audio Transcriptions API (`/v1/audio/transcriptions`)
- Pastes transcript into the active app using synthetic `Cmd+V`
- API key stored in macOS Keychain
- Low idle CPU usage (no always-on audio processing)

## Run

```bash
cd VoiceBarDictate
swift run
```

## Run Without Terminal (Dockless Menu Bar App)

Build a real `.app` bundle (agent app), then launch it from Finder. The app runs in the menu bar only and does not show in the Dock.

```bash
PRODUCT_BUNDLE_IDENTIFIER=com.yourcompany.VoiceBarDictate \
OPEN_APP=1 \
./scripts/build-app-bundle.sh
```

After launch, use the menu bar icon and choose `Quit` from the menu to exit.

Optional local self-signed certificate:

```bash
SIGNING_MODE=selfcert \
CODE_SIGN_IDENTITY="VoiceBarDictate Local Self Sign" \
PRODUCT_BUNDLE_IDENTIFIER=com.yourcompany.VoiceBarDictate \
OPEN_APP=1 \
./scripts/build-app-bundle.sh
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
PRODUCT_BUNDLE_IDENTIFIER=com.yourcompany.VoiceBarDictate \
./scripts/xcode-build-signed.sh
```

3. Optional: use your own local self-signed cert from Keychain:

```bash
SIGNING_MODE=selfcert \
CODE_SIGN_IDENTITY="My Local Mac Dev Cert" \
PRODUCT_BUNDLE_IDENTIFIER=com.yourcompany.VoiceBarDictate \
./scripts/xcode-build-signed.sh
```

4. Optional overrides:
   - `SIGNING_MODE` (`auto` default; values: `adhoc`, `selfcert`, `apple`)
   - `DEVELOPMENT_TEAM` (only needed for `SIGNING_MODE=apple`)
   - `CONFIGURATION` (default: `Debug`)
   - `DERIVED_DATA_PATH` (default: `.build/XcodeDerivedData`)

## Use `.env` For API Key (Dev)

If a `.env` file exists, the app uses `OPENAI_API_KEY` from that file and skips Keychain API key access.

```bash
cp .env.example .env
# edit .env and set OPENAI_API_KEY
swift run
```

## Setup

1. Launch the app (from `swift run` or Xcode).
2. Open Settings from the menu bar menu.
3. Paste your OpenAI API key.
4. If your OpenAI project has regional residency, set the API Base URL:
   - EU: `https://eu.api.openai.com`
   - US: `https://us.api.openai.com`
5. Grant microphone permission when prompted.
6. On startup, the app asks for Accessibility permission automatically.
7. After Accessibility is enabled, the app relaunches itself once so paste injection is fully active.
8. Optional: enable **Live Preview (Beta)** in Settings for realtime HUD text.
   - Supported models: `gpt-4o-mini-transcribe`, `gpt-4o-transcribe`
   - `whisper-1` will disable the toggle automatically

## Notes

- If you run this via Terminal (`swift run`), macOS may attribute privacy prompts to Terminal.
- For regular daily use, open `Package.swift` in Xcode and run it from Xcode so permissions are tied to the app/debug target.
- Live Preview uses Realtime transcription when available, then falls back to `/v1/audio/transcriptions` on any live-stream interruption.
