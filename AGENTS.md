# AGENTS.md

Repository-specific instructions for coding agents working on `VoiceBarDictate`.

## Project Snapshot
- App type: native macOS menu bar app (`MenuBarExtra`) built with SwiftUI + AppKit.
- Package type: Swift Package executable target `VoiceBarDictate`.
- Minimum platform: macOS 14 (Apple On-Device needs macOS 26; gate it with `#available`).
- Primary source folder: `Sources/VoiceBarDictate`.

## Build and Run
- Build with `swift build`.
- Run with `swift run VoiceBarDictate` (or `swift run`).
- Run tests with `swift test` (Swift Testing, `Tests/VoiceBarDictateTests`). Add tests for pure logic you change.
- Microphone capture, transcription, and paste injection are not covered by tests; verify them manually.

## Architecture Rules
- Keep UI-facing state in `AppState` (`@Observable`, `@MainActor`). Dictation state is the single `DictationPhase` enum; do not reintroduce parallel booleans.
- Preserve the existing orchestration pattern: `AppState` coordinates services (`AudioRecorderService`, `OpenAITranscriptionClient`, `TextInjector`, `HotkeyManager`, `SettingsStore`).
- Keep service responsibilities narrow:
  - `AudioRecorderService`: microphone permission + `AVAudioEngine` capture. `RecordingSink` receives buffers on the audio thread; keep closures it runs nonisolated.
  - `OpenAITranscriptionClient`: HTTP multipart transcription request + API error mapping.
  - `AppleLiveTranscription` / `AppleSpeechModel`: streaming SpeechAnalyzer session and language-model downloads.
  - `TextInjector`: transient clipboard write + synthetic `Cmd+V` injection, then clipboard restore.
  - `SettingsStore` / `KeychainService`: persistence and secret handling.
  - `HotkeyManager`: Carbon global hotkey registration (pressed and released events).
  - `EscapeKeyMonitor`: Escape/Return capture while dictating.

## Behavior That Must Not Regress
- Global shortcut defaults to `Control + Option + Space`.
- In toggle mode (the default), press hotkey/menu action once to start recording, again to stop and transcribe.
- Bundle identifier and Keychain service are `dev.arai.VoiceBarDictate`; changing them resets users' permissions.
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
- `.env` API keys are a debug-build convenience only (`SettingsStore.dotEnvEnabled`); never enable them in release builds.

## Manual Verification Checklist
When changing runtime behavior, verify the impacted flow end-to-end:
1. Launch app and confirm menu bar item appears.
2. Confirm hotkey registration, toggle and hold-to-talk behavior, and recording a custom shortcut.
3. Confirm microphone permission flow still works.
4. Confirm transcription request succeeds (or produces actionable API error).
5. Confirm paste injection, clipboard restore, and accessibility permission handling.
6. Confirm Settings changes persist across relaunch (engine, OpenAI model ID, base URL, language, prompt, API key, shortcut, shortcut behavior).

## Safety
- Never commit real API keys, tokens, or transcripts containing sensitive user content.
- Do not log secrets (especially API keys).
- Keep permissions-related prompts and error messages clear and actionable for macOS users.
