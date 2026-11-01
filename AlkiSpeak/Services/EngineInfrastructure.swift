import CryptoKit
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
    /// How big a text's requests are.
    struct Sizing: Hashable {
        /// What each segment aims for; a text's segments are evened out around it.
        let target: Int
        /// The most a segment of several sentences may hold.
        let limit: Int
        /// One sentence up to this long stays whole instead of being split.
        let sentenceLimit: Int

        static let standard = Sizing(target: 200, limit: 250, sentenceLimit: 300)
        /// mlx-audio voices pay a large fixed cost per request and run faster
        /// than real time, so after the opening they read paragraph-sized
        /// requests: fewer seams where the delivery can change.
        static let long = Sizing(target: 400, limit: 550, sentenceLimit: 650)
    }

    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.",
        "e.g.", "i.e.", "etc.", "vs."
    ]

    /// Splits `input` into requests that end at sentence ends where they can,
    /// else at a clause break, else between words; a word is cut only when
    /// there is no space to cut at. Segments come out about the same size:
    /// very short and very long requests get noticeably different delivery.
    /// The first segment uses `opening` when given, so sound starts as soon
    /// as it did with `.standard` requests.
    static func segments(for input: String, sizing: Sizing = .standard, opening: Sizing? = nil) -> [String] {
        let characters = Array(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !characters.isEmpty else { return [] }
        let strictest = opening.map { min($0.sentenceLimit, sizing.sentenceLimit) } ?? sizing.sentenceLimit
        let pieceLimit = opening.map { min($0.limit, sizing.limit) } ?? sizing.limit
        let units = sentenceRanges(characters).flatMap { range in
            range.count > strictest ? splitLongSentence(characters, range, limit: pieceLimit) : [range]
        }

        var chunks: [Range<Int>] = []
        var next = 0
        while next < units.count {
            let chunkSizing = chunks.isEmpty ? (opening ?? sizing) : sizing
            let remaining = units[units.count - 1].upperBound - units[next].lowerBound
            // Rounded to nearest, so a tail just over the target stays whole.
            let pieces = max(1, Int((Double(remaining) / Double(chunkSizing.target)).rounded()))
            let desired = remaining / pieces
            var range = units[next]
            next += 1
            while next < units.count {
                let grown = range.lowerBound..<units[next].upperBound
                guard grown.count <= chunkSizing.limit,
                      abs(grown.count - desired) < abs(range.count - desired)
                else { break }
                range = grown
                next += 1
            }
            chunks.append(range)
        }
        // A scrap at the end sounds clipped; fold it into the segment before.
        if chunks.count > 1, let last = chunks.last,
           last.count < sizing.target / 3,
           last.upperBound - chunks[chunks.count - 2].lowerBound <= sizing.limit {
            chunks.removeLast()
            chunks[chunks.count - 1] = chunks[chunks.count - 1].lowerBound..<last.upperBound
        }
        return chunks.compactMap { range in
            let text = String(characters[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// Each sentence's characters, including the space before the next one.
    private static func sentenceRanges(_ characters: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for index in characters.indices where isSentenceBoundary(characters, at: index) {
            ranges.append(start..<index + 1)
            start = index + 1
        }
        if start < characters.count { ranges.append(start..<characters.count) }
        return ranges
    }

    /// Cuts a sentence too long for one request into even pieces of at most
    /// `limit`, preferring clause breaks, then spaces. Never inside a `[tag]`.
    private static func splitLongSentence(_ characters: [Character], _ sentence: Range<Int>, limit: Int) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = sentence.lowerBound
        while sentence.upperBound - start > limit {
            let remaining = sentence.upperBound - start
            let count = Int((Double(remaining) / Double(limit)).rounded(.up))
            let ideal = start + remaining / count
            let window = (start + max(1, limit / 3))...(start + limit)
            let cut = nearestCut(characters, in: window, to: ideal) { isClauseBoundary(characters, at: $0 - 1) }
                ?? nearestCut(characters, in: window, to: ideal) { characters[$0].isWhitespace }
                ?? max(start + 1, tagSafeCut(characters, at: ideal))
            pieces.append(start..<cut)
            start = cut
        }
        pieces.append(start..<sentence.upperBound)
        return pieces
    }

    /// The cut position in `window` closest to `ideal` that passes `isCut`
    /// and doesn't fall inside an open `[tag]`.
    private static func nearestCut(_ characters: [Character], in window: ClosedRange<Int>, to ideal: Int, where isCut: (Int) -> Bool) -> Int? {
        let upper = min(window.upperBound, characters.count - 1)
        guard window.lowerBound <= upper else { return nil }
        return (window.lowerBound...upper)
            .filter { isCut($0) && tagSafeCut(characters, at: $0) == $0 }
            .min { abs($0 - ideal) < abs($1 - ideal) }
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

/// Generated audio kept on disk by what was said and how, so replaying the
/// same text with the same voice is instant, free on paid voices and works
/// offline. Least recently used clips are dropped past `capacityBytes`.
actor AudioClipCache {
    static let shared = AudioClipCache()
    static let defaultCapacityBytes: Int64 = 1 << 30
    /// Bumped when the cache's contents change meaning, so old entries miss.
    private static let formatVersion = "1"

    private let directory: URL
    private let capacityBytes: Int64
    private let fileManager = FileManager.default

    init(directory: URL? = nil, capacityBytes: Int64 = AudioClipCache.defaultCapacityBytes) {
        self.directory = directory ?? Self.defaultDirectory
        self.capacityBytes = capacityBytes
    }

    private static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Woadie", isDirectory: true)
            .appendingPathComponent("AudioCache", isDirectory: true)
    }

    /// `voiceConfiguration` is everything besides the text that shapes the
    /// audio: the voice ID, plus a cloud or local voice's model and settings.
    nonisolated static func key(text: String, voiceConfiguration: String) -> String {
        let material = [formatVersion, voiceConfiguration, text].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func url(forKey key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("audio")
    }

    /// The cached audio for `key`, marking it as recently used.
    func audio(forKey key: String) -> Data? {
        let url = url(forKey: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    func store(_ data: Data, forKey key: String) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(forKey: key), options: .atomic)
        } catch {
            return
        }
        trimToCapacity()
    }

    func totalBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    func removeAll() {
        for entry in entries() {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    private func trimToCapacity() {
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > capacityBytes else { return }
        all.sort { $0.lastUsed < $1.lastUsed }
        for entry in all where total > capacityBytes {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func entries() -> [(url: URL, size: Int64, lastUsed: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return urls.filter { $0.pathExtension == "audio" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }
}
