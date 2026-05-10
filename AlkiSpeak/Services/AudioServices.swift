import AVFoundation
import Foundation

final class AVAudioPlaybackCoordinator: NSObject, PlaybackCoordinating, AVAudioPlayerDelegate {
    var onFinished: (() -> Void)?
    private var audioPlayer: AVAudioPlayer?
    private let completionLock = NSLock()
    private var completionContinuation: CheckedContinuation<Void, Error>?

    func play(audioData: Data) throws {
        completionLock.lock()
        completionContinuation = nil
        completionLock.unlock()
        audioPlayer = try AVAudioPlayer(data: audioData)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()
        audioPlayer?.play()
    }

    func playToCompletion(audioData: Data) async throws {
        stop()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            completionLock.lock()
            completionContinuation = continuation
            completionLock.unlock()
            do {
                let player = try AVAudioPlayer(data: audioData)
                audioPlayer = player
                player.delegate = self
                player.prepareToPlay()
                guard player.play() else {
                    completionLock.lock()
                    completionContinuation = nil
                    completionLock.unlock()
                    continuation.resume(
                        throwing: AlkiSpeakError.playback(
                            code: "play-failed",
                            title: "Audio Did Not Start",
                            message: "The audio engine could not begin playback.",
                            recoverySuggestion: "Try generating the speech again.",
                            context: [:]
                        )
                    )
                    return
                }
            } catch {
                completionLock.lock()
                completionContinuation = nil
                completionLock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() {
        completionLock.lock()
        if let cont = completionContinuation {
            completionContinuation = nil
            cont.resume(throwing: CancellationError())
        }
        completionLock.unlock()
        audioPlayer?.stop()
        audioPlayer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        completionLock.lock()
        let cont = completionContinuation
        completionContinuation = nil
        completionLock.unlock()

        Task { @MainActor in
            if let cont {
                if flag {
                    cont.resume()
                } else {
                    cont.resume(
                        throwing: AlkiSpeakError.playback(
                            code: "play-incomplete",
                            title: "Playback Interrupted",
                            message: "Audio playback did not finish successfully.",
                            recoverySuggestion: "Try generating the speech again.",
                            context: [:]
                        )
                    )
                }
                return
            }
            self.onFinished?()
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
