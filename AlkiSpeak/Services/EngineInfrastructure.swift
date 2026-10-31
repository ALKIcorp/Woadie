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

            let cut = boundary ?? tagSafeCut(characters, at: min(hardCutCharacters, characters.count))
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

    /// Longest opening chunk `leadIn` aims for. Synthesis time grows with
    /// length, so a short first request is what makes speech start quickly;
    /// later chunks are generated while it plays.
    static let leadInLimit = 100
    /// Openings shorter than these sound clipped, so they aren't used.
    private static let minimumLeadInSentence = 20
    private static let minimumLeadInClause = 25

    /// Splits a short opening off `text` so the first request finishes fast:
    /// the first sentence of at least 20 characters ending within
    /// `leadInLimit`, else the first clause break (`,` `;` `:` or a dash) of
    /// at least 25. Returns nil when `text` is already short or has no break
    /// that early.
    static func leadIn(of text: String) -> (lead: String, rest: String)? {
        let characters = Array(text)
        guard characters.count > leadInLimit else { return nil }
        let window = min(leadInLimit, characters.count - 1)

        var sentenceCut: Int?
        var clauseCut: Int?
        for index in 0..<window {
            if isSentenceBoundary(characters, at: index), index + 1 >= minimumLeadInSentence {
                sentenceCut = index + 1
                break
            } else if clauseCut == nil, isClauseBoundary(characters, at: index), index + 1 >= minimumLeadInClause {
                clauseCut = index + 1
            }
        }
        guard let cut = sentenceCut ?? clauseCut, tagSafeCut(characters, at: cut) == cut else { return nil }
        let lead = String(characters[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(characters[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lead.isEmpty, !rest.isEmpty else { return nil }
        return (lead, rest)
    }

    private static func isClauseBoundary(_ characters: [Character], at index: Int) -> Bool {
        let mark = characters[index]
        guard mark == "," || mark == ";" || mark == ":" || mark == "—" || mark == "–" else { return false }
        guard index + 1 < characters.count, characters[index + 1].isWhitespace else { return false }
        // "1,000" and "3:30" are numbers, not pauses.
        return !(index > 0 && characters[index - 1].isNumber && characters[index + 1].isNumber)
    }

    /// Longest inline expression cue a hard cut steps back over, e.g. `[Dissatisfaction-hnn]`.
    private static let maxTagLength = 32

    /// Moves a hard cut back to just before an unclosed `[` so inline cues
    /// like `[Laughter]` never get split across two requests.
    static func tagSafeCut(_ characters: [Character], at cut: Int) -> Int {
        let floor = max(0, cut - maxTagLength)
        guard let open = characters[floor..<cut].lastIndex(of: "["), open > 0 else { return cut }
        let isClosed = characters[open..<cut].contains("]")
        return isClosed ? cut : open
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

    /// Monotonic token identifying the current run. Bumped whenever the queue is
    /// cancelled or a new `process` claims ownership. A suspended `process` loop
    /// compares its captured token against this to detect that a newer request
    /// has superseded it — this is what makes "override the current speech"
    /// safe even while an old generation is mid-flight on a network `await`.
    private var generation: UInt64 = 0

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
        generation &+= 1
        segments = []
        logger.debug("Queue cancellation requested generation=\(self.generation)")
    }

    /// Generates every queued segment and hands each to `onReady` strictly in
    /// order. Up to `maxConcurrent` segments generate at once, so later ones
    /// are ready by the time playback reaches them; 1 generates one at a time.
    /// A failure stops the run after the segments before it are delivered.
    func process(
        maxConcurrent: Int = 1,
        canGenerate: @escaping () async -> Bool = { true },
        onWaiting: @escaping (Bool) async -> Void = { _ in },
        generate: @escaping (TTSSegment) async throws -> GeneratedSegment,
        onReady: @escaping (TTSSegment) async throws -> Void
    ) async {
        // Claim ownership of the queue. Any previously running `process` loop now
        // holds a stale `generation` and will bail at its next checkpoint, so we
        // never need the old early-return guard that could silently drop a
        // superseding request while the previous one was suspended.
        generation &+= 1
        let myGeneration = generation
        isProcessing = true
        defer { if myGeneration == generation { isProcessing = false } }
        let limit = max(1, maxConcurrent)
        logger.info("Queue processing started segments=\(self.segments.count) generation=\(myGeneration) maxConcurrent=\(limit)")

        let count = segments.count
        await withTaskGroup(of: (Int, Result<GeneratedSegment, Error>).self) { group in
            var nextToStart = 0
            var nextToDeliver = 0
            var finished: [Int: Result<GeneratedSegment, Error>] = [:]

            while nextToDeliver < count {
                // Keep up to `limit` segments generating ahead of playback.
                while nextToStart < count, nextToStart - nextToDeliver < limit {
                    guard myGeneration == generation, !Task.isCancelled else { group.cancelAll(); return }
                    while !(await canGenerate()) {
                        guard myGeneration == generation, !Task.isCancelled else { group.cancelAll(); return }
                        await onWaiting(true)
                        try? await Task.sleep(for: .seconds(2))
                    }
                    await onWaiting(false)
                    guard myGeneration == generation, segments.indices.contains(nextToStart) else { group.cancelAll(); return }
                    segments[nextToStart].status = .generating
                    let segment = segments[nextToStart]
                    logger.debug("Generating segment index=\(segment.index) chars=\(segment.text.count)")
                    group.addTask {
                        do {
                            return (segment.index, .success(try await generate(segment)))
                        } catch {
                            return (segment.index, .failure(error))
                        }
                    }
                    nextToStart += 1
                }

                guard let (index, result) = await group.next() else { return }
                guard myGeneration == generation, !Task.isCancelled else { group.cancelAll(); return }
                finished[index] = result

                // Deliver whatever is now ready in order.
                while let result = finished.removeValue(forKey: nextToDeliver) {
                    guard segments.indices.contains(nextToDeliver) else { group.cancelAll(); return }
                    switch result {
                    case .success(let generated):
                        segments[nextToDeliver].audioURL = generated.audioURL
                        segments[nextToDeliver].durationSeconds = generated.durationSeconds
                        segments[nextToDeliver].status = .ready(generated.audioURL)
                        do {
                            try await onReady(segments[nextToDeliver])
                        } catch {
                            guard myGeneration == generation, segments.indices.contains(nextToDeliver) else { group.cancelAll(); return }
                            segments[nextToDeliver].status = .failed(error)
                            logger.error("Segment failed index=\(nextToDeliver) error=\(error.localizedDescription, privacy: .public)")
                            group.cancelAll()
                            return
                        }
                        guard myGeneration == generation, !Task.isCancelled else { group.cancelAll(); return }
                    case .failure(let error):
                        segments[nextToDeliver].status = .failed(error)
                        logger.error("Segment failed index=\(nextToDeliver) error=\(error.localizedDescription, privacy: .public)")
                        group.cancelAll()
                        return
                    }
                    nextToDeliver += 1
                }
            }
        }
    }
}
