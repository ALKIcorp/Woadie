# Phase 4 Chrome Heart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the macOS-first Chrome Heart Instrument Console visual shell, appearance settings, inline Pro log, and one-entry export/import.

**Architecture:** Preserve `AppModel` as the behavioral facade and add small domain helpers for appearance and archive formatting. Replace the old Woadie shell with Alki Corp glass components while keeping the existing engine, queue, playback, waveform, persistence, and log paths.

**Tech Stack:** SwiftUI, AppKit window interop, SwiftData, UserDefaults, XCTest, macOS 26 glass APIs with material fallbacks.

---

### Task 1: Preferences And Archive Domain

**Files:**
- Create: `AlkiSpeak/Models/AppAppearance.swift`
- Create: `AlkiSpeak/Persistence/SpeechEntryArchiveService.swift`
- Modify: `AlkiSpeak/Persistence/SpeechEntryStore.swift`
- Modify: `AlkiSpeak/App/AppDependencies.swift`
- Modify: `AlkiSpeakTests/EngineSupervisorTests.swift`

- [ ] Add failing tests for appearance default/persistence and archive export/import validation.
- [ ] Implement `AppAppearance` with `light`, `dark`, `system`, a `preferredColorScheme` bridge, and UserDefaults key `AlkiSpeak.appearance`.
- [ ] Implement `SpeechEntryArchiveService` that writes `SpeechExport_<ISO8601timestamp>`, `manifest.json`, and `segment_###.wav`.
- [ ] Add import validation that fails before inserting when any referenced audio file is missing.
- [ ] Add a `SpeechEntryStore.copyAudioIntoNewEntryDirectory(from:)` helper so imported files land under a new UUID Application Support folder.

### Task 2: App State And Commands

**Files:**
- Modify: `AlkiSpeak/App/AppStore.swift`
- Modify: `AlkiSpeak/AppModel.swift`
- Modify: `AlkiSpeak/AlkiSpeakApp.swift`

- [ ] Add app-wide `appearance` and `selectedLogEntryID` state.
- [ ] Load/save appearance through `AppAppearance`.
- [ ] Add `selectLogEntry(_:)`, `selectedLogEntry`, `exportSelectedEntry()`, and `importSpeechEntry()` on `AppModel`.
- [ ] Wire File -> Export and File -> Import commands to the model.
- [ ] Disable export when no log entry is selected.

### Task 3: Alki Corp Theme Components

**Files:**
- Modify: `AlkiSpeak/Theme/WoadieTheme.swift`
- Modify: `AlkiSpeak/Views/Components/WoadieBackground.swift`
- Modify: `AlkiSpeak/Views/Components/WoadieButton.swift`
- Modify: `AlkiSpeak/Views/Components/WoadieTextEditor.swift`
- Create or modify focused glass components as needed.

- [ ] Port Chrome Heart palette and Alki Corp radii/opacity conventions.
- [ ] Add `AlkiGlassSurface`, `AlkiTagPill`, and action/secondary button styles.
- [ ] Replace old dark teal defaults with adaptive Chrome Heart surfaces.
- [ ] Keep legacy names where useful to reduce churn, but change their implementation to Alki Corp style.

### Task 4: Instrument Console Layout

**Files:**
- Modify: `AlkiSpeak/Views/ContentView.swift`
- Modify: `AlkiSpeak/Views/Sections/WoadieHeaderView.swift`
- Modify: `AlkiSpeak/Views/Sections/WoadieControlsBar.swift`
- Modify: `AlkiSpeak/Views/Sections/WoadiePlaybackPanel.swift`
- Modify: `AlkiSpeak/Views/Sections/WoadieInputRow.swift`
- Modify: `AlkiSpeak/Views/Sections/SpeechLogView.swift`
- Modify: `AlkiSpeak/Views/Sections/SpeechLogItemView.swift`

- [ ] Rebuild the root as the Chrome Heart Instrument Console: top bar, Quick/Pro pill, engine pill, waveform left, transport right, input below.
- [ ] Show Quick mode as the focused workspace only.
- [ ] Show Pro mode inline log below the input.
- [ ] Add selected log styling and selection behavior.
- [ ] Keep existing open/delete/stats/playback behavior.

### Task 5: Engine Status And Voice Sheet

**Files:**
- Modify: `AlkiSpeak/Views/Components/StatusIndicatorView.swift`
- Modify: `AlkiSpeak/Views/Components/VoicePickerView.swift`

- [ ] Convert engine status into expandable Chrome Heart pill.
- [ ] Show diagnostics, Restart, CPU, RAM, and waiting-for-resources messaging from existing store data.
- [ ] Polish voice stepper as `[up] Voice [down]` glass pill with crossfade and long-press sheet.

### Task 6: Verification

**Files:**
- Existing test and project files.

- [ ] Run focused unit tests.
- [ ] Run full macOS test target.
- [ ] Run an Xcode build.
- [ ] Inspect git diff for unrelated changes and leave pre-existing visual companion artifacts alone.
