# AGENTS.md

Repository-specific instructions for coding agents working on `VoiceBarDictate`.

## Project Snapshot
- App type: native macOS menu bar app (`MenuBarExtra`) built with SwiftUI + AppKit.
- Package type: Swift Package executable target `VoiceBarDictate`.
- Minimum platform: macOS 13.
- Primary source folder: `Sources/VoiceBarDictate`.

## Build and Run
- Build with `swift build`.
- Run with `swift run VoiceBarDictate` (or `swift run`).
- There are currently no automated tests in this repository; use focused manual verification for changed behavior.

## Architecture Rules
- Keep UI-facing state in `AppState` and maintain `@MainActor` semantics for UI mutations.
- Preserve the existing orchestration pattern: `AppState` coordinates services (`AudioRecorderService`, `OpenAITranscriptionClient`, `TextInjector`, `HotkeyManager`, `SettingsStore`).
- Keep service responsibilities narrow:
  - `AudioRecorderService`: microphone permission + local recording lifecycle.
  - `OpenAITranscriptionClient`: HTTP multipart transcription request + API error mapping.
  - `TextInjector`: clipboard + synthetic `Cmd+V` injection.
  - `SettingsStore` / `KeychainService`: persistence and secret handling.
  - `HotkeyManager`: Carbon global hotkey registration.

## Behavior That Must Not Regress
- Global shortcut defaults to `Control + Option + Space`.
- Press hotkey/menu action once to start recording, again to stop and transcribe.
- API key is stored in Keychain (`KeychainService`), not in plain-text defaults.
- Transcript injection uses accessibility APIs and should fail with a clear user-facing error if permission is missing.
- Temporary audio files should be cleaned up after transcription attempt.
- Base URL handling must continue to support default OpenAI URL and regional endpoints.

## Coding Conventions
- Follow existing Swift style in the repo:
  - Prefer small `final class`/`struct` types with explicit responsibilities.
  - Use `LocalizedError` enums for user-facing failures.
  - Trim user-entered string settings before persistence or use.
- Keep dependency additions minimal. Prefer Apple frameworks already linked in `Package.swift`.
- Avoid broad refactors unless explicitly requested.

## Manual Verification Checklist
When changing runtime behavior, verify the impacted flow end-to-end:
1. Launch app and confirm menu bar item appears.
2. Confirm hotkey registration and toggle behavior.
3. Confirm microphone permission flow still works.
4. Confirm transcription request succeeds (or produces actionable API error).
5. Confirm paste injection behavior and accessibility permission handling.
6. Confirm Settings changes persist across relaunch (model, base URL, language, prompt, API key).

## Safety
- Never commit real API keys, tokens, or transcripts containing sensitive user content.
- Do not log secrets (especially API keys).
- Keep permissions-related prompts and error messages clear and actionable for macOS users.
