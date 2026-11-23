# AGENTS.md

Repository-specific instructions for coding agents working on `VoiceBarDictate`.

## Project Snapshot
- App type: native macOS menu bar app (`NSStatusItem` + SwiftUI views) built with SwiftUI + AppKit.
- Package type: Swift Package executable target `VoiceBarDictate`.
- Minimum platform: macOS 14 (Apple On-Device needs macOS 26; gate it with `#available`).
- Primary source folder: `Sources/VoiceBarDictate`.
- Dark mode only. `docs/design/voicebar-dark-mockups.html` is the visual reference for the popover, overlay, and
  menu bar icon; `docs/design/README.md` lists the design rules. Match it when changing UI.

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
  - `AppWindows.swift`: AppKit shell. `StatusItemController` owns the menu bar icon (left-click toggles the panel,
    right-click shows Settings and Quit) and hosts `MenuBarView` in a non-activating `PopoverPanel`;
    `SettingsWindowController` hosts `SettingsView`. The app starts from an AppKit entry point
    (`VoiceBarDictateApp.swift`), not SwiftUI scenes: `MenuBarExtra` cannot show a right-click menu.
  - `MenuBarView`, `RecordingOverlay`, `MenuBarIcon`: UI only; colours and shared controls live in `Theme.swift`.
    Popover actions that paste must close the panel and hand focus back to the previous app first
    (`AppState.focusPreviousApplicationIfNeeded`).

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

## Local installs
- Ad-hoc signatures change on every build, and macOS then drops the Accessibility and Keychain approvals. For a
  copy in `/Applications`, sign with a real certificate so approvals survive rebuilds:
  `SIGNING_MODE=selfcert CODE_SIGN_IDENTITY="<identity from security find-identity -v -p codesigning>" ./scripts/build-app-bundle.sh`
- The app shows the system Accessibility prompt only once (`SettingsStore.hasShownAccessibilityPrompt`); after
  that the popover's notice card links to System Settings.

## UI snapshots
- Debug builds render PNGs of the interface when launched with `VOICEBAR_SNAPSHOT_DIR=<dir>`: overlay states at
  launch, popover states after `touch <dir>/cmd-popovers`. Use them to compare against the mockups.
  `touch <dir>/cmd-toggle` opens the panel and `touch <dir>/cmd-dump` appends state and windows to `dump.log`.
- Debug builds take a `.env` path from `VOICEBAR_DOTENV_PATH`, so `open --env VOICEBAR_DOTENV_PATH=…` can launch
  the bundle the way Finder does without reading the Keychain.

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
