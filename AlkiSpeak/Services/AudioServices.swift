import AVFoundation
import Accelerate
import Foundation

final class AVAudioPlaybackCoordinator: NSObject, PlaybackCoordinating {
    var onSnapshotChanged: ((PlaybackTransportSnapshot) -> Void)?
    var onFinished: (() -> Void)?
    private(set) var fftMagnitudes = Array(repeating: Float.zero, count: 128)
    private let player = AVQueuePlayer()
    private var analysisEngine: AVAudioEngine?
    private var analysisNode: AVAudioPlayerNode?
    private var timeline = PlaybackTimeline(segmentCharacterCounts: [])
    private struct QueueEntry {
        let id: UUID
        let url: URL
        var item: AVPlayerItem
    }

    private var entries: [QueueEntry] = []
    private var expectedFormat: (sampleRate: Double, channels: AVAudioChannelCount)?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var allSegmentsEnqueued = false
    private var analysisFile: AVAudioFile?

    override init() {
        super.init()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in self?.publish() }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in self?.itemEnded(note.object as? AVPlayerItem) }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func prepare(characterCounts: [Int]) {
        stop()
        timeline = PlaybackTimeline(segmentCharacterCounts: characterCounts)
        allSegmentsEnqueued = false
        publish(state: .preparing)
    }

    func append(audioURL: URL, segmentID: UUID, index: Int) throws {
        setupAnalysisIfNeeded()
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
        let duration = Double(file.length) / format.sampleRate
        timeline.markReady(index: index, duration: duration)
        let item = AVPlayerItem(url: audioURL)
        entries.append(QueueEntry(id: segmentID, url: audioURL, item: item))
        let queueWasEmpty = player.currentItem == nil
        player.insert(item, after: nil)
        if entries.count == 1 || queueWasEmpty {
            startAnalysis(url: audioURL)
            player.play()
        }
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
        let wasPlaying = player.rate != 0
        player.removeAllItems()
        for index in location.segmentIndex..<entries.count {
            let item = AVPlayerItem(url: entries[index].url)
            entries[index].item = item
            player.insert(item, after: nil)
        }
        player.seek(to: CMTime(seconds: location.localTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        startAnalysis(url: entries[location.segmentIndex].url, at: location.localTime)
        if wasPlaying { player.play() }
        publish(state: wasPlaying ? .playing : .paused)
        return true
    }

    func stop() {
        player.pause()
        player.removeAllItems()
        analysisNode?.stop()
        entries.removeAll()
        expectedFormat = nil
        fftMagnitudes = Array(repeating: 0, count: 128)
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard let item, let index = entries.firstIndex(where: { $0.item === item }) else { return }
        if entries.indices.contains(index + 1) {
            startAnalysis(url: entries[index + 1].url)
        } else if allSegmentsEnqueued {
            complete()
        }
    }

    private func complete() {
        publish(state: .idle)
        onFinished?()
    }

    private func publish(state: PlaybackSnapshot.State? = nil) {
        let currentItem = player.currentItem
        let index = currentItem.flatMap { item in entries.firstIndex(where: { $0.item === item }) } ?? 0
        let local = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
        let elapsed = timeline.globalTime(segmentIndex: index, localTime: local)
        onSnapshotChanged?(
            PlaybackTransportSnapshot(
                state: state ?? (player.rate == 0 ? .paused : .playing),
                currentSegmentID: entries.indices.contains(index) ? entries[index].id : nil,
                elapsedTime: min(elapsed, timeline.bufferedDuration),
                bufferedDuration: timeline.bufferedDuration,
                totalDuration: timeline.totalDuration,
                fftMagnitudes: fftMagnitudes
            )
        )
    }

    private func startAnalysis(url: URL, at seconds: TimeInterval = 0) {
        guard let analysisNode else { return }
        analysisNode.stop()
        guard let file = try? AVAudioFile(forReading: url) else { return }
        analysisFile = file
        file.framePosition = min(AVAudioFramePosition(seconds * file.processingFormat.sampleRate), file.length)
        analysisNode.scheduleFile(file, at: nil)
        analysisNode.play()
    }

    private func installAnalysisTap() {
        guard let analysisEngine else { return }
        analysisEngine.mainMixerNode.installTap(
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

    private func setupAnalysisIfNeeded() {
        guard analysisEngine == nil else { return }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        analysisEngine = engine
        analysisNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0
        installAnalysisTap()
        try? engine.start()
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
