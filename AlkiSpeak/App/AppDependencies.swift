import Foundation

@MainActor
struct AppDependencies {
    let engineSupervisor: EngineSupervising
    let generationService: SpeechGenerating
    let edgeSpeechService: SpeechGenerating
    let cloudSpeechService: SpeechGenerating
    let cloudSpeechSettings: CloudSpeechSettingsStoring
    let secretStore: SecretStoring
    let localVoiceServer: LocalVoiceServerEnsuring
    let elevenLabsCatalog: ElevenLabsCatalogFetching
    let cartesiaVoices: CartesiaVoiceFetching
    let nativeKokoroService: NativeKokoroSpeechService
    let playbackCoordinator: PlaybackCoordinating
    let localSpeechService: LocalSpeechSynthesizing
    let selectedTextReader: SelectedTextReading
    let telemetryService: TelemetryCapturing
    let performanceDiagnostics: PerformanceDiagnosticRecording
    let workspaceStore: ActiveWorkspacePersisting
    let logStore: SavedLogPersisting
    let clipStore: SegmentedClipStoring
    let packageStore: SpeechPackageImportExporting
    let speechEntryStore: SpeechEntryStore
    let speechEntryArchiveService: SpeechEntryArchiveService

    static func live() -> AppDependencies {
        let cloudSettings = UserDefaultsCloudSpeechSettingsStore()
        let secrets = KeychainSecretStore()
        return AppDependencies(
            engineSupervisor: EngineManager.shared,
            generationService: KokoroSpeechGenerationService(),
            edgeSpeechService: EdgeSpeechGenerationService(),
            cloudSpeechService: CloudSpeechGenerationService(settings: cloudSettings, secrets: secrets, localServer: MLXAudioServerManager.shared),
            cloudSpeechSettings: cloudSettings,
            secretStore: secrets,
            localVoiceServer: MLXAudioServerManager.shared,
            elevenLabsCatalog: ElevenLabsCatalogService(secrets: secrets),
            cartesiaVoices: CartesiaVoiceService(secrets: secrets),
            nativeKokoroService: NativeKokoroSpeechService(),
            playbackCoordinator: AVAudioPlaybackCoordinator(),
            localSpeechService: AppleSpeechService(),
            selectedTextReader: SelectedTextReader(),
            telemetryService: ProcessTelemetryService(),
            performanceDiagnostics: FilePerformanceDiagnosticRecorder.live(),
            workspaceStore: UserDefaultsWorkspaceStore(),
            logStore: UserDefaultsSavedLogStore(),
            clipStore: FileSegmentedClipStore(),
            packageStore: FileSpeechPackageStore(),
            speechEntryStore: try! SpeechEntryStore(),
            speechEntryArchiveService: SpeechEntryArchiveService()
        )
    }
}
