import Foundation

@MainActor
struct AppDependencies {
    let engineSupervisor: EngineSupervising
    let generationService: SpeechGenerating
    let edgeSpeechService: SpeechGenerating
    let playbackCoordinator: PlaybackCoordinating
    let localSpeechService: LocalSpeechSynthesizing
    let telemetryService: TelemetryCapturing
    let workspaceStore: ActiveWorkspacePersisting
    let logStore: SavedLogPersisting
    let clipStore: SegmentedClipStoring
    let packageStore: SpeechPackageImportExporting
    let speechEntryStore: SpeechEntryStore
    let speechEntryArchiveService: SpeechEntryArchiveService

    static func live() -> AppDependencies {
        AppDependencies(
            engineSupervisor: EngineManager.shared,
            generationService: KokoroSpeechGenerationService(),
            edgeSpeechService: EdgeSpeechGenerationService(),
            playbackCoordinator: AVAudioPlaybackCoordinator(),
            localSpeechService: AppleSpeechService(),
            telemetryService: ProcessTelemetryService(),
            workspaceStore: UserDefaultsWorkspaceStore(),
            logStore: UserDefaultsSavedLogStore(),
            clipStore: FileSegmentedClipStore(),
            packageStore: FileSpeechPackageStore(),
            speechEntryStore: try! SpeechEntryStore(),
            speechEntryArchiveService: SpeechEntryArchiveService()
        )
    }
}
