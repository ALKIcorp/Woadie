import AVFoundation
import Accelerate
import Darwin
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
    private var pausedTime: TimeInterval? = nil
    private var tuning: PlaybackTuning = .default
    private let spectrumAnalyzer = PlaybackSpectrumAnalyzer(sampleCount: 2048, outputBinCount: 128)
    // Each analysis publish hops to the main thread to update the waveform and
    // transport snapshot. 30 Hz keeps the visuals fluid (the waveform smooths
    // between frames itself) while halving main-thread wake-ups during playback,
    // which keeps controls and the voice picker snappy.
    private let analysisPublishInterval: TimeInterval = 1.0 / 30.0
    private var lastAnalysisPublishTime: TimeInterval = 0
    /// The tap runs on the audio render thread while `stop()` resets the
    /// analyzer on the main thread; both go through this lock.
    private let analysisLock = NSLock()

    /// URLs of every clip currently queued, in order. Used to assert that tuning
    /// changes never alter the underlying generated files.
    var queuedAudioURLs: [URL] { entries.map(\.url) }

    func prepare(characterCounts: [Int]) {
        stop()
        timeline = PlaybackTimeline(segmentCharacterCounts: characterCounts)
        allSegmentsEnqueued = false
        publish(state: .preparing)
    }

    @discardableResult
    func append(audioURL: URL, segmentID: UUID, index: Int) throws -> TimeInterval {
        var file = try AVAudioFile(forReading: audioURL)
        var playableURL = audioURL
        if let expectedFormat,
           abs(expectedFormat.sampleRate - file.processingFormat.sampleRate) > 0.5
            || expectedFormat.channels != file.processingFormat.channelCount {
            // A fallback voice can answer at a different sample rate or channel
            // count than the rest of the job; convert it to match.
            playableURL = try Self.convert(file, toSampleRate: expectedFormat.sampleRate, channels: expectedFormat.channels)
            file = try AVAudioFile(forReading: playableURL)
        }
        let format = file.processingFormat
        expectedFormat = (format.sampleRate, format.channelCount)
        setupGraphIfNeeded(format: format)

        let duration = Double(file.length) / format.sampleRate
        timeline.markReady(index: index, duration: duration)
        let entry = QueueEntry(
            id: segmentID,
            url: playableURL,
            index: index,
            frameLength: file.length,
            sampleRate: format.sampleRate
        )
        let wasEmpty = entries.isEmpty
        entries.append(entry)

        if wasEmpty {
            baseOffsetSeconds = 0
            isPaused = false
            pausedTime = nil
            startEngineIfNeeded()
            player.play()
        }
        scheduleFile(file, for: entry)
        publish(state: .playing)
        return duration
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
        pausedTime = isPaused ? baseOffsetSeconds : nil

        // Scheduling works on a paused engine; only run it when audio will
        // actually play, so a seek while paused doesn't restart the tap.
        if wasPlaying {
            startEngineIfNeeded()
            player.play()
        }
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
            pausedTime = currentElapsed()
            player.pause()
            pauseEngine()
            isPaused = true
            publish(state: .paused)
            return
        }

        if entries.isEmpty { return }
        if isPaused {
            startEngineIfNeeded()
            player.play()
            isPaused = false
            pausedTime = nil
            publish(state: .playing)
            return
        }
        // Finished previously — replay from the start.
        _ = seek(to: 0)
        startEngineIfNeeded()
        player.play()
        isPaused = false
        pausedTime = nil
        publish(state: .playing)
    }

    func stop() {
        scheduleGeneration &+= 1
        player.stop()
        pauseEngine()
        entries.removeAll()
        completedSegmentIDs.removeAll()
        expectedFormat = nil
        allSegmentsEnqueued = false
        isPaused = false
        pausedTime = nil
        baseOffsetSeconds = 0
        fftMagnitudes = Array(repeating: 0, count: 128)
        analysisLock.withLock {
            spectrumAnalyzer.reset()
            lastAnalysisPublishTime = 0
        }
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
        pauseEngine()
        isPaused = false
        pausedTime = nil
        publish(state: .stopped)
        onFinished?()
    }

    private func currentElapsed() -> TimeInterval {
        if let pausedTime {
            return pausedTime
        }
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

    /// A running engine renders silence and keeps the analysis tap firing,
    /// which republishes the transport 30 times a second, so it only runs
    /// while audio is actually playing.
    private func pauseEngine() {
        if engine.isRunning { engine.pause() }
    }

    /// Rewrites `file` at `sampleRate` and `channels` into a temporary file
    /// and returns its URL.
    static func convert(_ file: AVAudioFile, toSampleRate sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
        let failure = { (reason: String) in
            AlkiSpeakError.playback(
                code: "audio-conversion-failed",
                title: "Audio Conversion Failed",
                message: "A clip couldn't be converted to match the rest of the speech: \(reason).",
                recoverySuggestion: "Generate the speech again."
            )
        }
        guard let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw failure("unsupported format") }
        try file.read(into: input)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlkiSpeakConverted", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let out = try AVAudioFile(forWriting: url, settings: target.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        // Hand the converter exactly as many frames as it asks for (it drops
        // the rest of a bigger buffer), and keep pulling after the input runs
        // out: the resampler holds its last frames until end of stream.
        let sourceFormat = file.processingFormat
        var offset: AVAudioFrameCount = 0
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else { throw failure("out of memory") }
            var conversionError: NSError?
            let status = converter.convert(to: chunk, error: &conversionError) { requested, inputStatus in
                let count = min(requested, input.frameLength - offset)
                guard count > 0,
                      let slice = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: count),
                      let from = input.floatChannelData,
                      let to = slice.floatChannelData
                else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                for channel in 0..<Int(sourceFormat.channelCount) {
                    (to[channel]).update(from: from[channel] + Int(offset), count: Int(count))
                }
                slice.frameLength = count
                offset += count
                inputStatus.pointee = .haveData
                return slice
            }
            if status == .error { throw failure(conversionError?.localizedDescription ?? "converter error") }
            if chunk.frameLength > 0 { try out.write(from: chunk) }
            if status == .endOfStream { break }
        }
        return url
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
            bufferSize: AVAudioFrameCount(spectrumAnalyzer.sampleCount),
            format: nil
        ) { [weak self] buffer, time in
            guard let self, let channel = buffer.floatChannelData?.pointee else { return }
            let now = time.hostTime == 0
                ? Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                : AVAudioTime.seconds(forHostTime: time.hostTime)
            let magnitudes: [Float]? = self.analysisLock.withLock {
                guard self.shouldPublishAnalysis(at: now) else { return nil }
                return self.spectrumAnalyzer.analyze(
                    channel: channel,
                    frameLength: Int(buffer.frameLength)
                )
            }
            guard let magnitudes else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fftMagnitudes = magnitudes
                self.publish()
            }
        }
    }

    private func shouldPublishAnalysis(at time: TimeInterval) -> Bool {
        guard lastAnalysisPublishTime > 0 else {
            lastAnalysisPublishTime = time
            return true
        }
        guard time - lastAnalysisPublishTime >= analysisPublishInterval else { return false }
        lastAnalysisPublishTime = time
        return true
    }
}

final class PlaybackSpectrumAnalyzer {
    let sampleCount: Int
    let outputBinCount: Int

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var samples: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var powerMagnitudes: [Float]
    private var smoothedMagnitudes: [Float]

    init(sampleCount: Int, outputBinCount: Int) {
        precondition(sampleCount > 0 && sampleCount.nonzeroBitCount == 1)
        precondition(outputBinCount > 0 && outputBinCount <= sampleCount / 2)

        self.sampleCount = sampleCount
        self.outputBinCount = outputBinCount
        log2n = vDSP_Length(log2(Double(sampleCount)))
        window = Array(repeating: 0, count: sampleCount)
        samples = Array(repeating: 0, count: sampleCount)
        real = Array(repeating: 0, count: sampleCount / 2)
        imag = Array(repeating: 0, count: sampleCount / 2)
        powerMagnitudes = Array(repeating: 0, count: outputBinCount)
        smoothedMagnitudes = Array(repeating: 0, count: outputBinCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("Unable to create FFT setup.")
        }
        fftSetup = setup
        vDSP_hann_window(&window, vDSP_Length(sampleCount), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func reset() {
        for index in smoothedMagnitudes.indices {
            smoothedMagnitudes[index] = 0
        }
    }

    func analyze(channel: UnsafePointer<Float>, frameLength: Int) -> [Float] {
        let copyCount = min(max(frameLength, 0), sampleCount)
        for index in samples.indices {
            samples[index] = 0
        }
        if copyCount > 0 {
            samples.withUnsafeMutableBufferPointer { pointer in
                pointer.baseAddress!.update(from: channel, count: copyCount)
            }
        }
        vDSP.multiply(samples, window, result: &samples)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                samples.withUnsafeBufferPointer { samplePtr in
                    samplePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: sampleCount / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(sampleCount / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                powerMagnitudes.withUnsafeMutableBufferPointer { magnitudePtr in
                    vDSP_zvmags(&split, 1, magnitudePtr.baseAddress!, 1, vDSP_Length(outputBinCount))
                }
            }
        }

        var scale = Float(1.0 / Float(sampleCount))
        vDSP_vsmul(powerMagnitudes, 1, &scale, &powerMagnitudes, 1, vDSP_Length(outputBinCount))
        for index in smoothedMagnitudes.indices {
            let target = min(1, max(0, powerMagnitudes[index]).squareRoot() * 5)
            // Light smoothing only — the view handles its own time-based interpolation.
            let attack: Float = target > smoothedMagnitudes[index] ? 0.82 : 0.55
            smoothedMagnitudes[index] = smoothedMagnitudes[index] * (1 - attack) + target * attack
        }
        return smoothedMagnitudes
    }
}

// MARK: - Voice cloning

/// Reference recordings for cloned local voices. Each is converted to a 24 kHz
/// mono 16-bit WAV (what Qwen3 reads) and kept in Application Support, so the
/// original file can move or be deleted.
enum VoiceCloneReference {
    /// Qwen3 needs a few seconds to pick up a voice; long clips make every
    /// request slower because the reference is processed each time.
    static let minimumSeconds: Double = 3
    static let maximumSeconds: Double = 30
    static let sampleRate: Double = 24_000

    static var directory: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let directory = base.appendingPathComponent("Woadie/VoiceClones", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        return directory
    }

    /// Converts `source` (any format AVFoundation reads) and stores it as
    /// `<id>.wav`. Throws a readable error for clips that are too short, too
    /// long or unreadable.
    static func store(from source: URL, id: UUID, in directory: URL? = VoiceCloneReference.directory) throws -> URL {
        guard let directory else {
            throw failure("Couldn't create the folder for voice recordings.")
        }
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw failure("Couldn't read that audio file. Use a WAV, M4A, MP3 or AIFF recording.")
        }
        let inputFormat = input.processingFormat
        let seconds = Double(input.length) / inputFormat.sampleRate
        guard seconds >= minimumSeconds else {
            throw failure(String(format: "The recording is %.1f s long. Record at least %.0f seconds.", seconds, minimumSeconds))
        }
        guard seconds <= maximumSeconds else {
            throw failure(String(format: "The recording is %.0f s long. Use a clip under %.0f seconds.", seconds, maximumSeconds))
        }

        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(input.length)),
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(seconds * sampleRate) + 4_096
              )
        else {
            throw failure("Couldn't convert that recording.")
        }
        try input.read(into: inputBuffer)

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let conversionError {
            throw failure("Couldn't convert that recording: \(conversionError.localizedDescription)")
        }

        let destination = directory.appendingPathComponent("\(id.uuidString).wav")
        try? FileManager.default.removeItem(at: destination)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try output.write(from: outputBuffer)
        return destination
    }

    /// Silence between the recording and the previous segment in a
    /// continuation reference, so the two don't run together.
    static let continuationGap: TimeInterval = 0.3

    /// A temporary WAV of `reference`, a short gap, then `previous`, for a
    /// cloned voice to continue from. The caller deletes it after the
    /// request. Nil when `previous` runs longer than `maximumAddedSeconds`.
    static func continuation(of reference: URL, then previous: URL, maximumAddedSeconds: Double) throws -> URL? {
        let recording = try AudioPCM.readMono(reference, sampleRate: sampleRate)
        let previousClip = try AudioPCM.readMono(previous, sampleRate: sampleRate)
        guard !previousClip.samples.isEmpty,
              Double(previousClip.samples.count) / sampleRate <= maximumAddedSeconds
        else { return nil }
        let gap = [Float](repeating: 0, count: Int(continuationGap * sampleRate))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlkiSpeakContinuations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try AudioPCM.wav(recording.samples + gap + previousClip.samples, sampleRate: sampleRate).write(to: url)
        return url
    }

    /// Deletes a stored reference, but only inside the voice-clone folder.
    static func remove(atPath path: String, in directory: URL? = VoiceCloneReference.directory) {
        guard let directory else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == directory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func failure(_ message: String) -> AlkiSpeakError {
        .generation(
            code: "clone.reference",
            title: "Voice Recording Problem",
            message: message,
            recoverySuggestion: "Record or choose a clear 5–20 second clip of one person speaking."
        )
    }
}

// MARK: - Clip audio

/// Mono float samples read from clip files and written back as WAV.
enum AudioPCM {
    /// Reads `url` (any format AVFoundation reads) as mono samples, at
    /// `sampleRate` when given, else at the file's own rate.
    static func readMono(_ url: URL, sampleRate: Double? = nil) throws -> (samples: [Float], sampleRate: Double) {
        var file = try AVAudioFile(forReading: url)
        var converted: URL?
        defer { converted.map { try? FileManager.default.removeItem(at: $0) } }
        if let sampleRate, abs(file.processingFormat.sampleRate - sampleRate) > 0.5 {
            converted = try AVAudioPlaybackCoordinator.convert(file, toSampleRate: sampleRate, channels: 1)
            file = try AVAudioFile(forReading: converted!)
        }
        let format = file.processingFormat
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let channels = chunk.floatChannelData
        else { throw failure("unsupported format") }
        let channelCount = Int(format.channelCount)
        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length))
        // One read can return fewer frames than asked for, so keep reading.
        while file.framePosition < file.length {
            try file.read(into: chunk)
            let count = Int(chunk.frameLength)
            guard count > 0 else { break }
            var mixed = Array(UnsafeBufferPointer(start: channels[0], count: count))
            if channelCount > 1 {
                for channel in 1..<channelCount {
                    vDSP_vadd(mixed, 1, channels[channel], 1, &mixed, 1, vDSP_Length(count))
                }
                var scale = 1 / Float(channelCount)
                vDSP_vsmul(mixed, 1, &scale, &mixed, 1, vDSP_Length(count))
            }
            mono.append(contentsOf: mixed)
        }
        return (mono, format.sampleRate)
    }

    /// Reads clip bytes (WAV or MP3) as mono samples.
    static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Double) {
        // AVAudioFile sniffs the format, but needs a plausible extension.
        let isWAV = data.prefix(4) == Data("RIFF".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alkispeak-decode-\(UUID().uuidString)")
            .appendingPathExtension(isWAV ? "wav" : "mp3")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try readMono(url)
    }

    /// A 16-bit mono WAV of `samples`, clamped to full scale.
    static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            pcm[index] = Int16(max(-1, min(1, sample)) * Float(Int16.max))
        }
        let rate = UInt32(sampleRate.rounded())
        let dataSize = UInt32(pcm.count * 2)
        var wav = Data(capacity: 44 + pcm.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(dataSize)
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }
        return wav
    }

    private static func failure(_ reason: String) -> AlkiSpeakError {
        .playback(
            code: "audio-read-failed",
            title: "Audio Read Failed",
            message: "A clip couldn't be read: \(reason).",
            recoverySuggestion: "Generate the speech again."
        )
    }
}

/// Evens out each clip before it's queued so the seams between a text's
/// segments don't stand out: trims the silence each request leaves at its
/// ends, brings the speech to one loudness, fades the edges so nothing
/// clicks, and ends on a pause that fits where the text was split. The
/// pause stands in for a crossfade: segments meet at a break in the speech,
/// so there's no sound to blend across.
enum ClipConditioner {
    /// Speech level every clip is brought to: about -21 dBFS RMS.
    static let targetLevel: Float = 0.09
    /// Peaks stay under -1 dBFS; a clip that would pass it gets less gain.
    static let peakCeiling: Float = 0.89
    /// At most ±20 dB, so a near-silent clip isn't blown up into noise.
    static let gainRange: ClosedRange<Float> = 0.1...10
    /// Kept around the speech so soft onsets and breath tails survive the trim.
    static let edgeMargin: TimeInterval = 0.04
    static let fadeDuration: TimeInterval = 0.012
    private static let window: TimeInterval = 0.01

    static let sentencePause: TimeInterval = 0.25
    static let clausePause: TimeInterval = 0.12
    static let wordPause: TimeInterval = 0.04

    /// `data` conditioned as a 16-bit mono WAV, or unchanged if it can't be read.
    static func condition(_ data: Data, trailingPause: TimeInterval) -> Data {
        guard let clip = try? AudioPCM.decode(data), !clip.samples.isEmpty else { return data }
        return AudioPCM.wav(condition(clip.samples, sampleRate: clip.sampleRate, trailingPause: trailingPause), sampleRate: clip.sampleRate)
    }

    static func condition(_ samples: [Float], sampleRate: Double, trailingPause: TimeInterval) -> [Float] {
        let pause = [Float](repeating: 0, count: Int(trailingPause * sampleRate))
        let windowLength = max(1, Int(sampleRate * window))
        let windowCount = samples.count / windowLength
        guard windowCount > 0 else { return samples + pause }

        var levels = [Float](repeating: 0, count: windowCount)
        samples.withUnsafeBufferPointer { pointer in
            for index in 0..<windowCount {
                vDSP_rmsqv(pointer.baseAddress! + index * windowLength, 1, &levels[index], vDSP_Length(windowLength))
            }
        }
        let loudest = levels.max() ?? 0
        // Silence (or near it) is left alone rather than amplified.
        guard loudest > 0.001,
              let first = levels.firstIndex(where: { $0 > loudest * 0.01 }),
              let last = levels.lastIndex(where: { $0 > loudest * 0.01 })
        else { return samples + pause }

        let margin = Int(sampleRate * edgeMargin)
        let start = max(0, first * windowLength - margin)
        let end = min(samples.count, (last + 1) * windowLength + margin)
        var output = Array(samples[start..<end])

        // Loudness of the speech itself, not the pauses inside it.
        let speech = levels.filter { $0 > loudest * 0.05 }
        let speechLevel = (speech.reduce(0) { $0 + $1 * $1 } / Float(speech.count)).squareRoot()
        var gain = min(gainRange.upperBound, max(gainRange.lowerBound, targetLevel / speechLevel))
        var peak: Float = 0
        vDSP_maxmgv(output, 1, &peak, vDSP_Length(output.count))
        if peak * gain > peakCeiling { gain = peakCeiling / peak }
        vDSP_vsmul(output, 1, &gain, &output, 1, vDSP_Length(output.count))

        let fade = min(Int(sampleRate * fadeDuration), output.count / 2)
        for index in 0..<fade {
            let ramp = Float(index) / Float(fade)
            output[index] *= ramp
            output[output.count - 1 - index] *= ramp
        }
        return output + pause
    }

    /// The pause after a segment: a sentence's worth at a sentence end, a
    /// short one at a clause break, a breath at a word break, none at the end.
    static func pause(after text: String, isLast: Bool) -> TimeInterval {
        guard !isLast else { return 0 }
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "»"]
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).last(where: { !closers.contains($0) }) {
        case ".", "!", "?", "…": return sentencePause
        case ",", ";", ":", "—", "–": return clausePause
        default: return wordPause
        }
    }
}

/// Records a short microphone clip for voice cloning to a temporary WAV.
@MainActor
final class VoiceCloneRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    /// Asks for microphone access (once) and starts recording.
    func start() async throws {
        guard !isRecording else { return }
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            granted = false
        }
        guard granted else {
            throw AlkiSpeakError.generation(
                code: "clone.microphone",
                title: "Microphone Access Needed",
                message: "Woadie isn't allowed to use the microphone.",
                recoverySuggestion: "Allow it in System Settings → Privacy & Security → Microphone, or choose an existing recording instead."
            )
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("woadie-clone-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record(forDuration: VoiceCloneReference.maximumSeconds) else {
            throw AlkiSpeakError.generation(
                code: "clone.record",
                title: "Recording Failed",
                message: "The microphone recording couldn't start.",
                recoverySuggestion: "Check the input device in System Settings → Sound, then try again."
            )
        }
        self.recorder = recorder
        elapsed = 0
        isRecording = true
        // A ticking label only while recording; nothing runs otherwise.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
                if !recorder.isRecording { _ = self.stop() }
            }
        }
    }

    /// Stops recording and returns the clip.
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        guard let recorder else { return nil }
        if recorder.isRecording { recorder.stop() }
        self.recorder = nil
        isRecording = false
        return recorder.url
    }
}

final class AppleSpeechService: NSObject, LocalSpeechSynthesizing, AVSpeechSynthesizerDelegate {
    var onFinished: (() -> Void)?
    /// The range of the utterance about to be spoken, for read-along.
    var onWillSpeakRange: ((NSRange) -> Void)?
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
                let quality: AppleVoiceQuality
                switch voice.quality {
                case .premium:
                    quality = .highest
                case .enhanced:
                    quality = .medium
                default:
                    quality = .low
                }
                return VoiceOption(
                    id: "apple:\(voice.identifier)",
                    label: "Apple - \(voice.name) [\(voice.language)]",
                    source: .apple,
                    isAvailable: true,
                    appleQuality: quality
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

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.onWillSpeakRange?(characterRange)
        }
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
            memoryBytes: currentResidentMemoryBytes(),
            engineProcessID: engineProcessID,
            port: AppConfig.enginePort
        )
    }

    private func currentResidentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}
