# AlkiSpeak Update Architecture

AlkiSpeak now has a SwiftUI-first shell with `AlkiSpeakApp` creating one `AppStore` and one `AppDependencies` graph. `AppModel` remains as a compatibility facade for the current views, but the single source of truth is `AppStore`.

## Data Flow

Views read and mutate through `AppModel`. `AppModel` forwards those changes into `AppStore`, which owns app mode, log mode, engine state, the active workspace, queued jobs, playback, telemetry, persistence status, saved packages, and saved log entries.

Current history is isolated as `[SavedLogEntry]` on `AppStore`. Later prompts can replace the storage implementation without changing the UI list.

## Services

Service protocols live in `Services/ServiceProtocols.swift` and `Persistence/PersistenceProtocols.swift`.

- `EngineSupervising` starts, stops, and inspects the local Kokoro process.
- `SpeechGenerating` checks health, fetches Kokoro voices, and sends synthesis requests.
- `LocalSpeechSynthesizing` wraps Apple speech fallback voices.
- `PlaybackCoordinating` owns AVAudio playback.
- `TelemetryCapturing` creates dashboard resource snapshots.
- Persistence protocols cover active workspace, saved logs, segmented clips, and package import/export.

Concrete live implementations are registered in `AppDependencies.live()`. Future prompts should add behavior by extending those protocols or swapping implementations in the dependency graph.

## UI Compatibility

`UI/VisualCompatibility.swift` exposes `woadieGlassPanel(...)`, which uses modern macOS glass effects when available and keeps the existing Woadie surface fallback on older systems.

## Extension Points

- Engine reliability work should extend `ProcessEngineSupervisor` and `KokoroSpeechGenerationService`.
- Long-text queueing should implement `SpeechQueueing` and update `AppStore.speechJobs`.
- Dashboard work should enrich `ResourceSnapshot` and `DashboardTelemetry`.
- Durable history and exports should replace the current in-memory stores behind the persistence protocols.
