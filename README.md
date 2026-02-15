# VoiceBarDictate (Native macOS Menu Bar Dictation)

Native SwiftUI/AppKit menu bar app for push-to-talk dictation using OpenAI speech-to-text.

## Features

- Menu bar app (`MenuBarExtra`)
- Global hotkey: `Control + Option + Space`
- Press once to start recording, press again to stop and transcribe
- Uses OpenAI Audio Transcriptions API (`/v1/audio/transcriptions`)
- Pastes transcript into the active app using synthetic `Cmd+V`
- API key stored in macOS Keychain
- Low idle CPU usage (no always-on audio processing)

## Run

```bash
cd /Users/amarjeetrai/sonu27/test/VoiceBarDictate
swift run
```

## Use `.env` For API Key (Dev)

If a `.env` file exists, the app uses `OPENAI_API_KEY` from that file and skips Keychain API key access.

```bash
cp .env.example .env
# edit .env and set OPENAI_API_KEY
swift run
```

## Setup

1. Launch the app (from `swift run` or Xcode).
2. Open Settings from the menu bar popover.
3. Paste your OpenAI API key.
4. If your OpenAI project has regional residency, set the API Base URL:
   - EU: `https://eu.api.openai.com`
   - US: `https://us.api.openai.com`
5. Grant microphone permission when prompted.
6. Grant accessibility permission so the app can paste text into other apps.

## Notes

- If you run this via Terminal (`swift run`), macOS may attribute privacy prompts to Terminal.
- For regular daily use, open `Package.swift` in Xcode and run it from Xcode so permissions are tied to the app/debug target.
