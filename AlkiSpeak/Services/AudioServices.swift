import AVFoundation
import Accelerate
import Foundation

/// Audio playback built on `AVAudioEngine` so listen-only speed/pitch tuning can
/// be applied live through an `AVAudioUnitTimePitch`. Generated clip files are
/// only ever read — tuning never re-encodes or rewrites them.
final class AVAudioPlaybackCoordinator: NSObject, PlaybackCoordinating {
    var onSnapshotChanged: ((PlaybackTransportSnapshot) -> Void)?
    var onFinished: (() -> Void)?
    private(set) var fftMagnitudes = Array(repeating: Float.zero, count: 128)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var graphReady = false

    private struct QueueEntry {
        let id: UUID
        let url: URL
        let index: Int
        let frameLength: AVAudioFramePosition
        let sampleRate: Double
    }

    private var entries: [QueueEntry] = []
    private var timeline = PlaybackTimeline(segmentCharacterCounts: [])
    private var expectedFormat: (sampleRate: Double, channels: AVAudioChannelCount)?
    private var allSegmentsEnqueued = false
    private var completedSegmentIDs: Set<UUID> = []
    /// Source-time offset for the current play/seek session. `player`'s sample
    /// time resets to 0 on each `play()` after a `stop()`, so this carries any
    /// seek target forward when computing elapsed time.
    private var baseOffsetSeconds: TimeInterval = 0
    private var scheduleGeneration: UInt64 = 0
    private var isPaused = false
    private var tuning: PlaybackTuning = .default

    /// URLs of every clip currently queued, in order. Used to assert that tuning
    /// changes never alter the underlying generated files.
    var queuedAudioURLs: [URL] { entries.map(\.url) }

    func prepare(characterCounts: [Int]) {
        stop()
        timeline = PlaybackTimeline(segmentCharacterCounts: characterCounts)
        allSegmentsEnqueued = false
        publish(state: .preparing)
    }

    func append(audioURL: URL, segmentID: UUID, index: Int) throws {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        if let expectedFormat,
           abs(expectedFormat.sampleRate - format.sampleRate) > 0.5 || expectedFormat.channels != format.channelCount {
            throw AlkiSpeakError.playback(
                code: "inconsistent-audio-format",
                title: "Audio Format Changed",
                message: "Kokoro returned segments with inconsistent sample rates or channel layouts.",
                recoverySuggestion: "Restart the engine and generate the speech again.",
                context: ["sampleRate": "\(format.sampleRate)", "channels": "\(format.channelCount)"]
            )
        }
        expectedFormat = (format.sampleRate, format.channelCount)
        setupGraphIfNeeded(format: format)

        let duration = Double(file.length) / format.sampleRate
        timeline.markReady(index: index, duration: duration)
        let entry = QueueEntry(
            id: segmentID,
            url: audioURL,
            index: index,
            frameLength: file.length,
            sampleRate: format.sampleRate
        )
        let wasEmpty = entries.isEmpty
        entries.append(entry)

        if wasEmpty {
            baseOffsetSeconds = 0
            isPaused = false
            startEngineIfNeeded()
            player.play()
        }
        scheduleFile(file, for: entry)
        publish(state: .playing)
    }

    func finishEnqueuing() {
        allSegmentsEnqueued = true
        if entries.isEmpty { complete() }
    }

    func seek(to globalTime: TimeInterval) -> Bool {
        guard let location = timeline.location(for: globalTime),
              entries.indices.contains(location.segmentIndex)
        else { return false }
        let wasPlaying = player.isPlaying && !isPaused

        scheduleGeneration &+= 1
        player.stop()
        baseOffsetSeconds = timeline.globalTime(segmentIndex: location.segmentIndex, localTime: location.localTime)
        completedSegmentIDs = Set(entries.prefix(location.segmentIndex).map(\.id))
        isPaused = !wasPlaying

        startEngineIfNeeded()
        if wasPlaying { player.play() }
        for offset in location.segmentIndex..<entries.count {
            let entry = entries[offset]
            guard let file = try? AVAudioFile(forReading: entry.url) else { continue }
            let startFrame = offset == location.segmentIndex
                ? AVAudioFramePosition(min(location.localTime * entry.sampleRate, Double(entry.frameLength)))
                : 0
            scheduleFile(file, for: entry, startingFrame: startFrame)
        }
        publish(state: wasPlaying ? .playing : .paused)
        return true
    }

    func togglePlayback() {
        if player.isPlaying && !isPaused {
            player.pause()
            isPaused = true
            publish(state: .paused)
            return
        }

        if entries.isEmpty { return }
        if isPaused {
            startEngineIfNeeded()
            player.play()
            isPaused = false
            publish(state: .playing)
            return
        }
        // Finished previously — replay from the start.
        _ = seek(to: 0)
        startEngineIfNeeded()
        player.play()
        isPaused = false
        publish(state: .playing)
    }

    func stop() {
        scheduleGeneration &+= 1
        player.stop()
        if engine.isRunning { engine.pause() }
        entries.removeAll()
        completedSegmentIDs.removeAll()
        expectedFormat = nil
        allSegmentsEnqueued = false
        isPaused = false
        baseOffsetSeconds = 0
        fftMagnitudes = Array(repeating: 0, count: 128)
    }

    func applyTuning(_ tuning: PlaybackTuning) {
        self.tuning = tuning
        // `rate` is the time-stretch factor (speed); `pitch` is in cents, so a
        // semitone is 100 cents. Both are applied live without touching clips.
        timePitch.rate = Float(tuning.speed)
        timePitch.pitch = Float(tuning.pitch * 100)
    }

    private func scheduleFile(_ file: AVAudioFile, for entry: QueueEntry, startingFrame: AVAudioFramePosition = 0) {
        let generation = scheduleGeneration
        let frames = AVAudioFrameCount(max(0, file.length - startingFrame))
        guard frames > 0 else {
            handleSegmentCompletion(entry.id, generation: generation)
            return
        }
        if startingFrame > 0 {
            player.scheduleSegment(
                file,
                startingFrame: startingFrame,
                frameCount: frames,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.handleSegmentCompletion(entry.id, generation: generation) }
            }
        } else {
            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.handleSegmentCompletion(entry.id, generation: generation) }
            }
        }
    }

    private func handleSegmentCompletion(_ segmentID: UUID, generation: UInt64) {
        guard generation == scheduleGeneration else { return }
        completedSegmentIDs.insert(segmentID)
        if allSegmentsEnqueued, completedSegmentIDs.count >= entries.count {
            complete()
        }
    }

    private func complete() {
        scheduleGeneration &+= 1
        player.stop()
        isPaused = false
        publish(state: .stopped)
        onFinished?()
    }

    private func currentElapsed() -> TimeInterval {
        guard player.isPlaying || isPaused,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0
        else { return min(baseOffsetSeconds, timeline.bufferedDuration) }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        return baseOffsetSeconds + max(0, played)
    }

    private func publish(state: PlaybackSnapshot.State? = nil) {
        let elapsed = min(currentElapsed(), timeline.bufferedDuration)
        let index = timeline.location(for: elapsed)?.segmentIndex ?? 0
        let resolvedState = state ?? (isPaused ? .paused : (player.isPlaying ? .playing : .stopped))
        onSnapshotChanged?(
            PlaybackTransportSnapshot(
                state: resolvedState,
                currentSegmentID: entries.indices.contains(index) ? entries[index].id : nil,
                elapsedTime: elapsed,
                bufferedDuration: timeline.bufferedDuration,
                totalDuration: timeline.totalDuration,
                fftMagnitudes: fftMagnitudes
            )
        )
    }

    private func startEngineIfNeeded() {
        guard graphReady, !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    private func setupGraphIfNeeded(format: AVAudioFormat) {
        guard !graphReady else { return }
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        applyTuning(tuning)
        installAnalysisTap()
        graphReady = true
        startEngineIfNeeded()
    }

    private func installAnalysisTap() {
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?.pointee else { return }
            let count = min(Int(buffer.frameLength), 1024)
            guard count >= 256 else { return }
            var samples = Array(UnsafeBufferPointer(start: channel, count: count))
            var window = [Float](repeating: 0, count: count)
            vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
            vDSP.multiply(samples, window, result: &samples)
            let log2n = vDSP_Length(log2(Float(count)))
            guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
            defer { vDSP_destroy_fftsetup(setup) }
            var real = [Float](repeating: 0, count: count / 2)
            var imag = [Float](repeating: 0, count: count / 2)
            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    samples.withUnsafeBytes {
                        $0.bindMemory(to: DSPComplex.self).baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: count / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(count / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    var magnitudes = [Float](repeating: 0, count: 128)
                    vDSP_zvmags(&split, 1, &magnitudes, 1, 128)
                    var scale = Float(1.0 / Float(count))
                    vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, 128)
                    DispatchQueue.main.async {
                        self.fftMagnitudes = zip(self.fftMagnitudes, magnitudes).map {
                            min(1, $0 * 0.72 + sqrt(max(0, $1)) * 5 * 0.28)
                        }
                        self.publish()
                    }
                }
            }
        }
    }
}

final class AppleSpeechService: NSObject, LocalSpeechSynthesizing, AVSpeechSynthesizerDelegate {
    var onFinished: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var voiceLookup: [String: AVSpeechSynthesisVoice] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
        refreshVoices()
    }

    var voiceOptions: [VoiceOption] {
        voiceLookup.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { voice in
                VoiceOption(
                    id: "apple:\(voice.identifier)",
                    label: "Apple - \(voice.name) [\(voice.language)]",
                    isLocal: true
                )
            }
    }

    func refreshVoices() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        voiceLookup = Dictionary(uniqueKeysWithValues: voices.map { ($0.identifier, $0) })
    }

    func speak(text: String, voiceID: String) throws {
        let identifier = voiceID.replacingOccurrences(of: "apple:", with: "")
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier) ?? voiceLookup[identifier] else {
            throw AlkiSpeakError.playback(
                code: "missing-local-voice",
                title: "Voice Unavailable",
                message: "The selected Apple voice is not available on this Mac.",
                recoverySuggestion: "Choose another Apple voice or refresh the voice list.",
                context: ["voiceID": voiceID]
            )
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.onFinished?()
        }
    }
}

final class ProcessTelemetryService: TelemetryCapturing {
    func capture(engineProcessID: Int32?) -> ResourceSnapshot {
        ResourceSnapshot(
            capturedAt: Date(),
            cpuPercent: nil,
            memoryBytes: nil,
            engineProcessID: engineProcessID,
            port: AppConfig.enginePort
        )
    }
}
