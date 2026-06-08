import Foundation
import os

enum EngineError: Error, Equatable, LocalizedError {
    case exitCode(Int)
    case portConflict
    case venvMissing
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .exitCode(let code):
            return "Kokoro exited unexpectedly with code \(code)."
        case .portConflict:
            return "Port \(AppConfig.enginePort) is already in use by another process."
        case .venvMissing:
            return "The Kokoro Python virtual environment is missing."
        case .unknown(let message):
            return message
        }
    }
}

enum EngineState: Equatable {
    case starting
    case ready
    case degraded(reason: String)
    case stopped(error: EngineError)
    case unreachable

    var statusText: String {
        switch self {
        case .starting:
            return "Starting Engine…"
        case .ready:
            return "Engine Ready"
        case .degraded(let reason):
            return "Degraded — \(reason)"
        case .stopped(let error):
            return "Engine Stopped — \(error.localizedDescription)"
        case .unreachable:
            return "Cannot reach localhost:\(AppConfig.enginePort)"
        }
    }
}

enum TextBatcher {
    private static let targetCharacters = 200
    private static let hardCutCharacters = 250
    private static let boundarySearchLimit = 300
    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.",
        "e.g.", "i.e.", "etc.", "vs."
    ]

    static func segments(for input: String) -> [String] {
        var remaining = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remaining.isEmpty else { return [] }

        var result: [String] = []
        while remaining.count > hardCutCharacters {
            let characters = Array(remaining)
            let searchEnd = min(boundarySearchLimit, characters.count)
            var boundary: Int?

            if targetCharacters < searchEnd {
                for index in targetCharacters..<searchEnd where isSentenceBoundary(characters, at: index) {
                    boundary = index + 1
                    break
                }
            }

            let cut = boundary ?? min(hardCutCharacters, characters.count)
            let segment = String(characters[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                result.append(segment)
            }
            remaining = String(characters[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !remaining.isEmpty {
            result.append(remaining)
        }
        return result
    }

    private static func isSentenceBoundary(_ characters: [Character], at index: Int) -> Bool {
        let mark = characters[index]
        guard mark == "." || mark == "!" || mark == "?" else { return false }
        guard index + 1 == characters.count || characters[index + 1].isWhitespace else { return false }

        if mark == "." {
            if isEllipsis(characters, at: index) || isDecimalPoint(characters, at: index) {
                return false
            }
            let token = tokenEnding(at: index, in: characters).lowercased()
            if abbreviations.contains(token) {
                return false
            }
        }
        return true
    }

    private static func isEllipsis(_ characters: [Character], at index: Int) -> Bool {
        (index > 0 && characters[index - 1] == ".")
            || (index + 1 < characters.count && characters[index + 1] == ".")
    }

    private static func isDecimalPoint(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0, index + 1 < characters.count else { return false }
        return characters[index - 1].isNumber && characters[index + 1].isNumber
    }

    private static func tokenEnding(at index: Int, in characters: [Character]) -> String {
        var start = index
        while start > 0 && !characters[start - 1].isWhitespace {
            start -= 1
        }
        return String(characters[start...index])
    }
}

struct GeneratedSegment {
    let audioURL: URL
    let durationSeconds: Double?
}

struct TTSSegment: Identifiable {
    let id: UUID
    let text: String
    let index: Int
    var status: SegmentStatus
    var audioURL: URL?
    var durationSeconds: Double?

    init(
        id: UUID = UUID(),
        text: String,
        index: Int,
        status: SegmentStatus = .pending,
        audioURL: URL? = nil,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.index = index
        self.status = status
        self.audioURL = audioURL
        self.durationSeconds = durationSeconds
    }
}

enum SegmentStatus {
    case pending
    case generating
    case ready(URL)
    case failed(Error)
}

actor TTSQueue {
    private let logger = Logger(subsystem: "com.alki.Woadie", category: "TTSQueue")
    var segments: [TTSSegment] = []
    var isProcessing = false

    var processing: Bool { isProcessing }

    func enqueue(_ texts: [String]) {
        segments = texts.enumerated().map { index, text in
            TTSSegment(text: text, index: index)
        }
        logger.debug("Queue prepared with \(self.segments.count) segments")
    }

    func enqueue(_ speechSegments: [SpeechSegment]) {
        segments = speechSegments.map { segment in
            TTSSegment(id: segment.id, text: segment.text, index: segment.index)
        }
        logger.debug("Queue prepared with \(self.segments.count) speech segments")
    }

    func snapshot() -> [TTSSegment] {
        segments
    }

    func cancel() {
        isProcessing = false
        logger.debug("Queue cancellation requested")
    }

    func process(
        generate: @escaping (TTSSegment) async throws -> GeneratedSegment,
        onReady: @escaping (TTSSegment) async throws -> Void
    ) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        logger.info("Queue processing started segments=\(self.segments.count)")

        for index in segments.indices {
            guard isProcessing, !Task.isCancelled else { return }
            segments[index].status = .generating
            let segment = segments[index]
            logger.debug("Generating segment index=\(segment.index) chars=\(segment.text.count)")

            do {
                let generated = try await generate(segment)
                guard isProcessing, !Task.isCancelled, segments.indices.contains(index) else { return }
                segments[index].audioURL = generated.audioURL
                segments[index].durationSeconds = generated.durationSeconds
                segments[index].status = .ready(generated.audioURL)
                try await onReady(segments[index])
            } catch {
                segments[index].status = .failed(error)
                logger.error("Segment failed index=\(segment.index) error=\(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }
}
