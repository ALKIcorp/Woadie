# AlkiSpeak Dropdown, Voice, Playback, and Storage Foundation Plan

## Summary
Build this as a foundation-first update. The first implementation pass should deliver reusable dropdown/disclosure components, voice favorites/source grouping, playback/control polish, query-average CPU/RAM stats, live speed+pitch playback effects, caret alignment, and a custom settings/storage overlay.

Defer the macOS menu bar extra and right-click “Speak Out Loud” Services integration to the next pass, but design the new components and app state so those surfaces can reuse them.

## Key Changes
- Add reusable SwiftUI components for `AlkiDropdown`, dropdown sections/options, disclosure setting rows, icon-only transport buttons, and a reusable vocal signal view.
- Extend voice data with source metadata, availability, and persisted favorites. Show `Favorites`, `Apple`, and `Kokoro` sections now; model Edge/API sources for later but do not enable unsupported synthesis yet.
- Replace the circular play control with a plain glyph-only play/pause button using just `play.fill` and `pause.fill`.
- Add playback-only tuning: speed range `0.65x...1.75x`, pitch range `-6...+6` semitones, default `1.0x / 0`, persisted per app.
- Refactor playback through `AVAudioEngine` + `AVAudioPlayerNode` + `AVAudioUnitTimePitch` so speed/pitch affect listening only and never rewrite generated clips.
- Add `QueryResourceUsage` to `QueryStats` as optional Codable data: sample count, average CPU %, average RAM used MB, peak RAM used MB.
- Replace current CPU/RAM tiles with labels like `CPU used avg` and `RAM used avg` from the completed query.
- Add a custom gear-triggered settings overlay with appearance, open clips folder, storage cleanup, and a storage dashboard.
- Add a storage dashboard over the main content area showing saved clips sorted by name, date, duration, voice, and size, with delete, show in Finder, copy, and rename actions.

## Implementation Notes
- Keep `AppModel` as the facade and `AppStore` as state owner.
- Keep existing Kokoro and Apple synthesis paths working; do not build the full provider framework in this pass.
- Add optional `displayName` to `SpeechEntry` for clip rename without mutating transcript text.
- Add clip inventory helpers behind persistence/services rather than scanning files directly from views.
- Keep the native macOS `Settings` scene as a fallback for app menu behavior, but route the in-app gear to the custom overlay.
- Phase 2 should add `MenuBarExtra`, a compact quick-speak popover, app lifecycle changes so the app can work after the main window closes, and an AppKit Services provider for selected text.

## Test Plan
- Unit test voice grouping, favorites persistence, unavailable provider handling, and selected voice preservation.
- Unit test `QueryResourceUsage` averaging and old `QueryStats` decoding with missing usage data.
- Unit test playback tuning clamp/default behavior and that generated file URLs are unchanged by speed/pitch changes.
- Unit test storage inventory sorting, rename metadata, orphan cleanup rules, and delete behavior.
- Build and test with:

```bash
xcodebuild -project AlkiSpeak.xcodeproj -scheme Woadie -destination 'platform=macOS' test