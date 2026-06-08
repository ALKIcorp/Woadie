# Phase 4 Chrome Heart Design

## Purpose

Phase 4 wraps the stable AlkiSpeak Kokoro TTS app in a polished Alki Corp visual shell without resetting the working engine, queue, playback, waveform, persistence, stats, or log behavior from Phases 1-3.

The implementation is macOS-first. It should keep view boundaries portable for future iOS, iPadOS, and visionOS layouts, but this phase does not add new platform targets.

## Locked Product Decisions

- Visual language: `AlkiCorpUIStyle`
- Palette: `Chrome Heart`
- First-launch appearance: System
- Appearance settings: Light, Dark, System
- Main layout: Chrome Heart Instrument Console, option A from the visual companion
- Quick mode: focused workspace only
- Pro mode: inline Log Console expands below the input
- Floating window behavior: transparent visual treatment at normal window level
- Export/import scope: one exported folder per `SpeechEntry`

## Visual System

The app should use the design vocabulary from `AlkiCorpUIStyle`:

- Ambient background based on `AlkiBackgroundView`
- `ThemePalette` as the theme boundary, shipping only Chrome Heart for now
- Continuous rounded geometry with 18, 22, and 28 point radii
- `.ultraThinMaterial` fallback surfaces and macOS 26 glass APIs where available
- White/black opacity conventions from the style folder, especially `0.18`, `0.12`, `0.10`, and `0.08`
- Rounded system typography for labels and controls
- Monospaced metadata for technical readouts, timings, resource stats, and tags

Chrome Heart should default to a neutral white accent and adapt to Light, Dark, and System appearance. The code should not hardcode unrelated one-off colors or radii in feature views; use reusable theme helpers and shared surface/button/pill components.

## macOS Window

The main macOS window should feel like a glass panel over desktop content while remaining a normal application window.

Requirements:

- `NSWindow.backgroundColor = .clear`
- `titlebarAppearsTransparent = true`
- `.fullSizeContentView` remains enabled
- Default title text stays hidden
- Native close, minimize, and zoom controls remain available
- Window level remains normal, not always-on-top
- Content draws its own top bar inside the glass shell

## Main Layout

The primary layout is the Chrome Heart Instrument Console:

- Transparent glass outer shell with native traffic lights
- Custom top bar with the app name centered and Settings access on the right
- Top controls row with Quick/Pro segmented pill on the left and Engine Status pill on the right
- Main workspace split into two glass panels:
  - Left panel: real FFT waveform as the visual centerpiece, current utterance title, buffer indicator, voice stepper, and signal metadata
  - Right panel: playback transport, skip controls, scrubber, timestamp, and compact resource stats
- Input surface below the workspace:
  - Multiline text input that grows naturally
  - Generate Speech button
  - Add to Log button only when Manual log mode is active
- Pro mode adds the Log Console inline below the input without changing the main workspace hierarchy

Quick mode should show only the focused speech workflow: waveform, voice, playback, input, and engine status. Pro-only diagnostics, log management, expanded resource details, and advanced stats should be hidden unless needed for an error or explicit Pro mode.

## Engine Status

`EngineStatusView` becomes a clickable Chrome Heart pill with expandable details.

States:

- Ready: green dot/icon, `ENGINE READY`
- Starting: amber pulsing dot/icon, `STARTING ENGINE`
- Degraded: yellow dot/icon, `DEGRADED`, with reason
- Stopped: red dot/icon, `ENGINE STOPPED`, with error detail
- Unreachable: red dot/icon, `CANNOT REACH LOCALHOST:[PORT]`

Expanded details show:

- Last engine log lines
- Restart button
- CPU percent bar and number
- RAM used/available bar and numbers
- `Waiting for resources...` when the queue is paused by resource pressure

Resource stats update every 5 seconds. Engine offline states must not crash the UI or block log browsing/playback of existing audio.

## Voice Stepper

The voice selector becomes an inline glass pill:

`[up] Voice Name [down]`

Behavior:

- Up/down buttons cycle voices
- Voice name crossfades when changed
- Long-pressing the voice name opens the full voice sheet
- The sheet uses the same Chrome Heart glass surface style

## Appearance Settings

Settings include a persisted appearance choice:

- Light
- Dark
- System

New installs default to System. The selected mode applies app-wide. Chrome Heart surfaces, waveform contrast, text, status colors, and semantic warning/error colors must remain legible in both Light and Dark appearances.

## Export And Import

Export operates on one `SpeechEntry`.

Export triggers:

- macOS File -> Export
- Export acts on the currently selected Log Console entry; the command is disabled when no entry is selected

Export format:

```text
SpeechExport_<ISO8601timestamp>/
  manifest.json
  segment_000.wav
  segment_001.wav
  segment_002.wav
```

`manifest.json` maps one-to-one to `SpeechEntry` plus codable query stats. Audio paths inside the manifest are relative to the export folder.

Import behavior:

- User selects an exported folder
- App reads `manifest.json`
- App validates that every referenced segment file exists
- App copies `.wav` files into Application Support under a new UUID subdirectory
- App creates a new SwiftData `SpeechEntry` with updated relative paths
- Imported entry appears in the Log Console immediately
- Imported, restored, and newly generated audio all use the same playback path

Invalid imports should produce a readable error and leave persistence unchanged.

## Platform Positioning

This phase does not create iOS, iPadOS, or visionOS targets. The implementation should still avoid unnecessarily macOS-specific logic inside reusable SwiftUI components.

Where useful, use small platform adapters around macOS-only APIs such as `NSWindow`, `NSSavePanel`, and file dialogs. Future iOS/iPadOS/visionOS work can then add platform-specific shell and document picker behavior without rewriting the core visual components.

## Cleanup And Accessibility

The polish pass should:

- Remove obsolete history/dropdown UI only if safely unused
- Keep all existing Phase 1-3 behavior intact
- Preserve app stability when the engine is offline
- Provide clear hover, focus, pressed, disabled, and loading states
- Keep keyboard access reasonable for mode toggle, transport, voice stepping, send, log open/delete, export, and import
- Make empty states intentional
- Hide Pro-only features in Quick mode
- Show Manual Add to Log only in Manual log mode

## Testing And Acceptance

Build and test the macOS app after implementation.

Acceptance criteria:

- Chrome Heart Instrument Console visual shell is implemented
- macOS window is transparent/floating in appearance while staying normal window level
- Light, Dark, and System appearance settings persist and apply globally
- Existing engine lifecycle, queue, playback, waveform, stats, and log behavior still work
- Quick mode remains focused
- Pro mode shows inline Log Console
- Export creates a valid one-entry folder with manifest and audio segments
- Import validates, copies audio, and restores the entry into SwiftData
- Generated, restored, and imported audio play through the same playback path
- Engine offline and invalid import states show errors without crashing
