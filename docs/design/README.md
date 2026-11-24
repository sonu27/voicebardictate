# VoiceBar design reference

`voicebar-dark-mockups.html` is the visual reference for the menu bar popover, the recording overlay, and the
menu bar icon. Open it in a browser. The SwiftUI implementation lives in `MenuBarView.swift`,
`RecordingOverlay.swift`, `MenuBarIcon.swift`, `AppWindows.swift` (status item, panel, Settings window),
and `Theme.swift`. Right-clicking the menu bar icon shows Settings and Quit.

## Rules

- Dark mode only. The app forces the dark appearance at launch; do not add light-mode colours.
- One accent: blue (`#2F6FE8` fills, `#4C8DFF` icons and meters). Recording uses the same blue as Start;
  it is told apart by the stop icon, the running timer, and the pulsing dot, not by colour.
- Amber is for things the user must fix (permissions, missing API key, no audio). Red is for errors only.
- Popover is 316pt wide with 13pt titles and 11–12pt body text, like other macOS menu bar panels.
- Keyboard shortcuts are shown as separate keycaps (`⌃` `⌥` `Space`), never as one pill.
- Sentence case everywhere ("Start dictation", "Stop and insert").

## Behaviour decisions captured in the mockups

- The privacy caption follows the engine: "Audio stays on this Mac" for on-device,
  "Audio is sent to OpenAI · <model>" for OpenAI.
- The popover shows at most one notice at a time, in this order: model download, Accessibility missing,
  microphone denied, API key missing, on-device unavailable, other errors, one-off info (e.g. a retired
  OpenAI model was replaced).
- While the on-device model downloads, Start is dimmed but still clickable; clicking explains why it cannot
  start. The app never falls back to OpenAI on its own.
- The engine switch is disabled (not hidden) while dictating.
- The overlay shows live text for on-device (2 lines, cut from the start so the newest words stay visible),
  a timer, and keycap hints (`↩ Insert`, `esc Cancel`; "Release to insert" in hold mode).
- "No audio from <device>" appears only if no sound at all has been heard ~4 s into a recording.
- After dictation stops, the overlay shows "Transcribing…" and disappears as soon as the text is pasted. The
  mockup's "Inserted · N words" card was dropped so nothing stays on screen; if no speech was heard, the
  overlay simply disappears too. If pasting is impossible, the transcript is left on the clipboard and the
  overlay says so.
