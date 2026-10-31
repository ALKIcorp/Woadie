import Foundation

/// What the pipeline needs from the rest of the app: the selected voice,
/// waking the Python Kokoro engine, request bookkeeping for its idle timer,
/// and saving finished jobs to the log.
@MainActor
protocol SpeechPipelineHost: AnyObject {
    var selectedVoice: String { get }
    /// Starts the Python Kokoro engine if this voice needs it and it's asleep.
    func prepareEngine(forVoice voice: String) async throws
    func speechRequestStarted(jobID: UUID)
    func speechRequestFinished(jobID: UUID)
    /// A job finished generating every segment and is still the active one.
    func speechJobFinishedGenerating(_ job: SpeechJob)
}

/// Turns text into audio and plays it: splits it into segments, generates
/// them in order through the right voice service, queues each clip on the
/// player as it lands, and tracks the job and playback state in the store.
/// A new request always supersedes the one in flight.
@MainActor
final class SpeechPipeline {
    private let store: AppStore
    private let dependencies: AppDependencies
    private let diagnostics: SpeechDiagnostics
    private let requestPolicy = EngineRequestPolicy.live
    private let ttsQueue = TTSQueue()
    weak var host: SpeechPipelineHost?

    private var activeSpeechTask: Task<Void, Never>?
    private var savedLogsNeedPersisting = false
    private let playbackSnapshotMinimumInterval: TimeInterval = 1.0 / 30.0
    private var lastPlaybackSnapshotAppliedAt: TimeInterval = 0

    init(store: AppStore, dependencies: AppDependencies, diagnostics: SpeechDiagnostics) {
        self.store = store
        self.dependencies = dependencies
        self.diagnostics = diagnostics
        wirePlaybackCallbacks()
    }

    // MARK: Requests

    /// Starts speaking `text` (already trimmed and non-empty) with `voice`.
    /// `dialogueSpeakers` splits the text between turns for dialogue voices.
    func speak(text: String, voice: String, dialogueSpeakers: [String]?, addToHistory: Bool, targetLogEntryID: UUID?) {
        let segments: [SpeechSegment]
        if let dialogueSpeakers {
            // Split between turns so every request carries its speaker labels.
            segments = DialogueScript.segments(for: text, speakers: dialogueSpeakers)
                .enumerated()
                .map { SpeechSegment(index: $0.offset, text: $0.element) }
        } else {
            // mlx-audio models have a large fixed cost per request and run
            // near real time, so a short opening only moves the wait to a gap
            // after it. Every other engine starts sooner with one.
            let isMLXVoice = store.cloudSettings.voice(withID: voice)?.provider == .localMLX
            segments = requestPolicy.segments(for: text, leadIn: !isMLXVoice)
        }
        // A short lead-in alone is routine, not worth a message.
        if segments.count > 2 {
            store.userMessage = "Large text split into \(segments.count) segments. Sending smaller engine requests to avoid request timeouts."
        }
        let jobID = UUID()
        let logEntryID = addToHistory ? UUID() : (targetLogEntryID ?? UUID())
        let isAppleVoice = voice.hasPrefix("apple:")

        let job = SpeechJob(
            id: jobID,
            text: text,
            voiceID: voice,
            segments: segments,
            status: .generating,
            logEntryID: logEntryID
        )
        store.speechJobs.insert(job, at: 0)
        diagnostics.setPhase(
            isAppleVoice ? .localSpeech : .remoteGeneration,
            jobID: jobID,
            message: "Speech job started.",
            context: [
                "characterCount": "\(text.count)",
                "segmentCount": "\(segments.count)",
                "voiceSource": SpeechDiagnostics.voiceSource(for: voice)
            ]
        )
        diagnostics.startQuery()
        store.playback = PlaybackSnapshot(
            state: .preparing,
            activeJobID: job.id,
            activeLogEntryID: logEntryID,
            currentSegmentID: segments.first?.id,
            elapsedTime: 0,
            duration: TimeInterval(text.count) / 150.0,
            bufferedDuration: 0,
            statusMessage: nil
        )

        activeSpeechTask = Task {
            // Supersede any older in-flight generation before this request does
            // anything. Done here (in the same task, before branching) so it
            // covers both the remote queue and a remote→local switch, with
            // deterministic ordering relative to this request's own enqueue.
            await ttsQueue.cancel()
            if isAppleVoice {
                speakLocal(text: text, voice: voice, jobID: job.id, logEntryID: logEntryID)
                return
            }
            await speakRemote(segments: segments, voice: voice, jobID: job.id, logEntryID: logEntryID)
        }
    }

    /// Stops the current utterance so a freshly requested one can take over
    /// immediately. Safe to call when nothing is active. Unlike `stop()`
    /// this does not push the transport to `.idle` (the new request overwrites it
    /// a moment later, so we avoid a visible flash) and it does not fire a
    /// detached queue cancel — the new request cancels and re-seeds the queue in
    /// the same task, which keeps the override race-free.
    func interrupt() {
        activeSpeechTask?.cancel()
        activeSpeechTask = nil
        diagnostics.finishResourceSampling()
        diagnostics.finishJob(message: "Superseded by a new request.")
        dependencies.playbackCoordinator.stop()
        dependencies.localSpeechService.stop()
        markActiveJobsCompleted()
    }

    func stop() {
        activeSpeechTask?.cancel()
        activeSpeechTask = nil
        diagnostics.finishResourceSampling()
        diagnostics.finishJob(message: "Playback stopped.")
        dependencies.playbackCoordinator.stop()
        dependencies.localSpeechService.stop()
        Task { await ttsQueue.cancel() }
        store.playback = .idle
        markActiveJobsCompleted()
    }

    /// Quick mode keeps only the latest clip: removes the active job's files.
    func deleteActiveClips() {
        guard let jobID = store.playback.activeJobID,
              let job = store.speechJobs.first(where: { $0.id == jobID })
        else { return }
        for segment in job.segments {
            if let url = segment.audioURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func remoteService(for voice: String) -> SpeechGenerating {
        if voice.hasPrefix(EdgeSpeechGenerationService.idPrefix) { return dependencies.edgeSpeechService }
        if CloudSpeechGenerationService.isCloudVoice(voice) { return dependencies.cloudSpeechService }
        if NativeKokoroSpeechService.isNativeKokoroVoice(voice) { return dependencies.nativeKokoroService }
        return dependencies.generationService
    }

    private func speakRemote(segments: [SpeechSegment], voice: String, jobID: UUID, logEntryID: UUID) async {
        host?.speechRequestStarted(jobID: jobID)
        defer {
            persistSavedLogsIfNeeded()
            host?.speechRequestFinished(jobID: jobID)
        }

        do {
            guard !segments.isEmpty else { return }
            try await host?.prepareEngine(forVoice: voice)
            if segments.count > 1 {
                updateJob(jobID, status: .queued, error: nil)
            }
            if segments.count > 2 {
                store.userMessage = "Speaking \(segments.count) segments in order…"
            }

            await ttsQueue.enqueue(segments)
            dependencies.playbackCoordinator.prepare(characterCounts: segments.map { $0.text.count })
            // Network voices generate a segment ahead; engines on this Mac
            // go one at a time.
            let runsOnThisMac = store.cloudSettings.voice(withID: voice)?.provider == .localMLX
            let lookahead = EngineRequestPolicy.generationConcurrency(forVoice: voice, runsOnThisMac: runsOnThisMac)
            await ttsQueue.process(maxConcurrent: lookahead, canGenerate: {
                await SystemResourceMonitor.shared.canProceed()
            }, onWaiting: { waiting in
                await MainActor.run {
                    self.store.playback.statusMessage = waiting ? "Waiting for resources…" : nil
                    if waiting {
                        self.diagnostics.setPhase(
                            .resourceWait,
                            jobID: jobID,
                            message: "Generation paused while waiting for system resources.",
                            context: ["segmentCount": "\(segments.count)"]
                        )
                    }
                }
            }) { [generationService = remoteService(for: voice), clipStore = dependencies.clipStore, workspaceID = store.activeWorkspace.id] segment in
                await MainActor.run {
                    self.diagnostics.setPhase(
                        .remoteGeneration,
                        jobID: jobID,
                        message: "Generating segment.",
                        context: [
                            "segmentIndex": "\(segment.index)",
                            "segmentCharacterCount": "\(segment.text.count)"
                        ]
                    )
                }
                let result = try await generationService.synthesize(
                    text: segment.text,
                    voice: voice,
                    jobID: jobID
                )
                let url = try clipStore.writeClip(data: result.audioData, segmentID: segment.id, workspaceID: workspaceID)
                await MainActor.run {
                    self.store.dashboardTelemetry.lastLatencyMs = result.latencyMs
                    self.store.dashboardTelemetry.lastCharCount = result.charCount
                }
                // The player reads the duration when it opens the clip.
                return GeneratedSegment(audioURL: url, durationSeconds: nil)
            } onReady: { [playbackCoordinator = dependencies.playbackCoordinator] segment in
                await MainActor.run {
                    self.diagnostics.setPhase(
                        .playback,
                        jobID: jobID,
                        message: "Segment ready for playback.",
                        context: segment.index == 0
                            ? ["segmentIndex": "0", "timeToFirstAudioMs": "\(Int(self.diagnostics.generationSeconds * 1000))"]
                            : ["segmentIndex": "\(segment.index)"]
                    )
                    self.store.playback.currentSegmentID = segment.id
                    self.updateJobSegment(jobID, segmentID: segment.id, status: .ready, audioURL: segment.audioURL, error: nil)
                    self.updateSavedLogSegment(logEntryID, segmentID: segment.id, status: .ready, audioURL: segment.audioURL, error: nil)
                    self.updateJob(jobID, status: .playing, error: nil)
                    self.store.playback.state = .playing
                }
                guard let audioURL = segment.audioURL else { return }
                let duration = try playbackCoordinator.append(audioURL: audioURL, segmentID: segment.id, index: segment.index)
                await MainActor.run {
                    self.setJobSegmentDuration(jobID, segmentID: segment.id, duration: duration)
                }
            }

            let snapshot = await ttsQueue.snapshot()
            if let failed = snapshot.first(where: {
                if case .failed = $0.status { return true }
                return false
            }), case .failed(let error) = failed.status {
                throw error
            }

            // If a newer request superseded this job while we were generating,
            // do not finalize the transport or persist — the new job now owns
            // playback and finishing here would prematurely cut it off.
            guard store.playback.activeJobID == jobID else {
                diagnostics.finishResourceSampling()
                return
            }

            dependencies.playbackCoordinator.finishEnqueuing()
            diagnostics.finishResourceSampling()
            if let job = store.speechJobs.first(where: { $0.id == jobID }) {
                host?.speechJobFinishedGenerating(job)
            }
        } catch is CancellationError {
            diagnostics.finishResourceSampling()
            diagnostics.finishJob(message: "Speech request cancelled.")
            updateJob(jobID, status: .cancelled, error: nil)
            // A newer request that superseded this one owns playback now.
            if store.playback.activeJobID == jobID {
                store.playback = .idle
            }
        } catch {
            failPlayback(jobID: jobID, logEntryID: logEntryID, error: Self.normalizeGenerationError(error))
        }
    }

    private func speakLocal(text: String, voice: String, jobID: UUID, logEntryID: UUID) {
        do {
            diagnostics.setPhase(
                .localSpeech,
                jobID: jobID,
                message: "Local speech playback started.",
                context: ["characterCount": "\(text.count)"]
            )
            updateJob(jobID, status: .playing, error: nil)
            store.playback.state = .playing
            try dependencies.localSpeechService.speak(text: text, voiceID: voice)
        } catch {
            failPlayback(jobID: jobID, logEntryID: logEntryID, error: Self.normalizePlaybackError(error))
        }
    }

    // MARK: Playback callbacks

    private func wirePlaybackCallbacks() {
        dependencies.playbackCoordinator.onFinished = { [weak self] in self?.finishPlayback() }
        dependencies.playbackCoordinator.onSnapshotChanged = { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                guard self.shouldApplyPlaybackSnapshot(snapshot) else { return }
                var playback = self.store.playback
                playback.state = snapshot.state
                playback.currentSegmentID = snapshot.currentSegmentID
                playback.elapsedTime = snapshot.elapsedTime
                playback.bufferedDuration = snapshot.bufferedDuration
                playback.duration = snapshot.totalDuration
                self.store.playback = playback
            }
        }

        if let localSpeech = dependencies.localSpeechService as? AppleSpeechService {
            localSpeech.onFinished = { [weak self] in
                self?.finishPlayback()
            }
        }
    }

    private func shouldApplyPlaybackSnapshot(_ snapshot: PlaybackTransportSnapshot) -> Bool {
        let playback = store.playback
        let now = Date.timeIntervalSinceReferenceDate
        let structureChanged =
            snapshot.state != playback.state ||
            snapshot.currentSegmentID != playback.currentSegmentID ||
            abs(snapshot.bufferedDuration - playback.bufferedDuration) > 0.001 ||
            abs(snapshot.totalDuration - (playback.duration ?? 0)) > 0.001
        let elapsedChanged = abs(snapshot.elapsedTime - playback.elapsedTime) > 0.001

        // An identical snapshot would still republish the whole store, so drop it.
        guard structureChanged || elapsedChanged else { return false }
        let shouldApplyImmediately = structureChanged || snapshot.state != .playing

        guard shouldApplyImmediately || now - lastPlaybackSnapshotAppliedAt >= playbackSnapshotMinimumInterval else {
            return false
        }
        lastPlaybackSnapshotAppliedAt = now
        return true
    }

    private func finishPlayback() {
        diagnostics.finishResourceSampling()
        diagnostics.finishJob(message: "Playback finished.")
        markActiveJobsCompleted()
        store.playback.state = .stopped
        store.playback.elapsedTime = 0
        store.playback.currentSegmentID = nil
        store.dashboardTelemetry.generatedJobCount += 1
    }

    private func failPlayback(jobID: UUID, logEntryID: UUID, error: AlkiSpeakError) {
        diagnostics.finishResourceSampling()
        diagnostics.recordMarker(phase: .failure, message: "Playback failed.", jobID: jobID, context: [
            "errorCode": error.code,
            "errorTitle": error.title
        ])
        diagnostics.finishJob(message: "Playback failed.")
        updateJob(jobID, status: .failed, error: error)
        store.playback = PlaybackSnapshot(
            state: .failed,
            activeJobID: jobID,
            activeLogEntryID: logEntryID,
            currentSegmentID: nil,
            elapsedTime: 0,
            duration: nil,
            bufferedDuration: 0,
            statusMessage: nil
        )
        store.dashboardTelemetry.failedJobCount += 1
        store.record(error)
    }

    // MARK: Job state

    private func markActiveJobsCompleted() {
        guard let jobID = store.playback.activeJobID else { return }
        updateJob(jobID, status: .completed, error: nil)
    }

    private func updateJob(_ jobID: UUID, status: SpeechJob.Status, error: AlkiSpeakError?) {
        guard let index = store.speechJobs.firstIndex(where: { $0.id == jobID }) else { return }
        store.speechJobs[index].status = status
        store.speechJobs[index].updatedAt = Date()
        store.speechJobs[index].error = error
    }

    private func updateJobSegment(_ jobID: UUID, segmentID: UUID, status: SpeechSegment.Status, audioURL: URL?, error: AlkiSpeakError?) {
        guard let jobIndex = store.speechJobs.firstIndex(where: { $0.id == jobID }),
              let segmentIndex = store.speechJobs[jobIndex].segments.firstIndex(where: { $0.id == segmentID })
        else { return }
        store.speechJobs[jobIndex].segments[segmentIndex].status = status
        store.speechJobs[jobIndex].segments[segmentIndex].audioURL = audioURL
        store.speechJobs[jobIndex].segments[segmentIndex].error = error
        store.speechJobs[jobIndex].updatedAt = Date()
    }

    private func setJobSegmentDuration(_ jobID: UUID, segmentID: UUID, duration: TimeInterval) {
        guard let jobIndex = store.speechJobs.firstIndex(where: { $0.id == jobID }),
              let segmentIndex = store.speechJobs[jobIndex].segments.firstIndex(where: { $0.id == segmentID })
        else { return }
        store.speechJobs[jobIndex].segments[segmentIndex].durationSeconds = duration
    }

    private func updateSavedLogSegment(_ logEntryID: UUID, segmentID: UUID, status: SpeechSegment.Status, audioURL: URL?, error: AlkiSpeakError?) {
        guard let entryIndex = store.savedLogEntries.firstIndex(where: { $0.id == logEntryID }),
              let segmentIndex = store.savedLogEntries[entryIndex].segments.firstIndex(where: { $0.id == segmentID })
        else { return }
        store.savedLogEntries[entryIndex].segments[segmentIndex].status = status
        store.savedLogEntries[entryIndex].segments[segmentIndex].audioURL = audioURL
        store.savedLogEntries[entryIndex].segments[segmentIndex].error = error
        savedLogsNeedPersisting = true
    }

    /// Writes the saved logs once a job is over, instead of re-encoding all
    /// of them for every segment that becomes ready.
    private func persistSavedLogsIfNeeded() {
        guard savedLogsNeedPersisting else { return }
        savedLogsNeedPersisting = false
        try? dependencies.logStore.replaceLogs(store.savedLogEntries, workspaceID: store.activeWorkspace.id)
    }

    // MARK: Errors

    private static func normalizeGenerationError(_ error: Error) -> AlkiSpeakError {
        if let appError = error as? AlkiSpeakError { return appError }
        return .generation(
            code: "unknown",
            title: "Speech Failed",
            message: "Speak failed: \(error.localizedDescription)",
            recoverySuggestion: "Check the selected voice and try again.",
            underlyingError: error
        )
    }

    private static func normalizePlaybackError(_ error: Error) -> AlkiSpeakError {
        if let appError = error as? AlkiSpeakError { return appError }
        return .playback(
            code: "unknown",
            title: "Playback Failed",
            message: error.localizedDescription,
            recoverySuggestion: "Try generating the speech again.",
            underlyingError: error
        )
    }
}
