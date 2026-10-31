import AVFoundation
import CryptoKit
import Foundation

/// One chapter of an imported book.
struct BookChapter: Codable, Hashable {
    var title: String
    var text: String
}

/// A long document split into chapters, listened to one chapter at a time.
struct Book: Codable, Equatable, Identifiable {
    /// Stable for the same document, so its place is remembered.
    var id: String
    var title: String
    var source: String
    var chapters: [BookChapter]

    init(title: String, source: String, chapters: [BookChapter]) {
        self.title = title
        self.source = source
        self.chapters = chapters
        let material = ([source, title] + chapters.map { "\($0.title)\u{1F}\($0.text.count)" }).joined(separator: "\u{1E}")
        id = SHA256.hash(data: Data(material.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    var wordCount: Int { chapters.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }

    // MARK: Saving

    static var directory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Woadie/Books", isDirectory: true)
    }

    /// Where this book's text and rendered chapter audio live.
    var folder: URL { Self.directory.appendingPathComponent(id, isDirectory: true) }

    func save() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent("book.json"), options: .atomic)
    }

    static func load(id: String) -> Book? {
        let url = directory.appendingPathComponent(id).appendingPathComponent("book.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Book.self, from: $0) }
    }
}

/// Where the listener left off in a book: a chapter and a character offset
/// into that chapter's spoken (cleaned-up) text.
struct BookProgress: Codable, Equatable {
    static let defaultsKey = "AlkiSpeak.bookProgress"
    static let lastBookKey = "AlkiSpeak.lastBook"

    var chapter: Int
    var offset: Int
    var updatedAt = Date()

    static func all(in defaults: UserDefaults = .standard) -> [String: BookProgress] {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([String: BookProgress].self, from: $0) } ?? [:]
    }

    static func save(_ progress: BookProgress, for bookID: String, in defaults: UserDefaults = .standard) {
        var all = all(in: defaults)
        all[bookID] = progress
        defaults.set(try? JSONEncoder().encode(all), forKey: defaultsKey)
    }
}

/// Progress of rendering a whole book's audio ahead of time.
struct BookRenderState: Equatable {
    var done: Int
    var total: Int
    var isRunning: Bool
    /// "Waiting for the Mac to be less busy…", errors, or completion.
    var message: String?

    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var isComplete: Bool { total > 0 && done >= total }
}

enum SleepTimer: Equatable {
    case off
    case endOfChapter
    case at(Date)
}

/// Finds chapters in plain or Markdown text: `#`/`##` headings, or lines like
/// "Chapter 3", "CHAPTER IV: The Storm", "Part Two".
enum ChapterSplitter {
    static func chapters(in text: String, fallbackTitle: String) -> [BookChapter] {
        let lines = text.components(separatedBy: "\n")
        let markdown = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,2}\s+(\S.*?)\s*#*\s*$"#)
        let named = try! NSRegularExpression(
            pattern: #"^\s*((chapter|part|book)\s+([0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[a-z]+teen|twenty[- a-z]*|thirty[- a-z]*)\b.*)$"#,
            options: .caseInsensitive
        )
        func heading(_ line: String) -> String? {
            let range = NSRange(line.startIndex..., in: line)
            for regex in [markdown, named] {
                if let match = regex.firstMatch(in: line, range: range), line.count <= 90,
                   let title = Range(match.range(at: 1), in: line) {
                    return String(line[title]).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }

        var chapters: [BookChapter] = []
        var title: String?
        var body: [String] = []
        func close() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let title {
                chapters.append(BookChapter(title: title, text: text.isEmpty ? title : "\(title).\n\n\(text)"))
            } else if text.count > 200 {
                // Anything worth hearing before the first heading.
                chapters.append(BookChapter(title: "Opening", text: text))
            } else if !text.isEmpty {
                body = [text]
                return
            }
            body = []
        }
        for line in lines {
            if let found = heading(line) {
                close()
                title = found
            } else {
                body.append(line)
            }
        }
        close()
        if chapters.count < 2 {
            return [BookChapter(title: fallbackTitle, text: text.trimmingCharacters(in: .whitespacesAndNewlines))]
        }
        return chapters
    }
}

/// Builds audiobook files from generated clips.
enum AudiobookExporter {
    enum ExportError: LocalizedError {
        case noAudio
        case ffmpegFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "There's no audio to export yet."
            case .ffmpegFailed(let detail): return "The audiobook couldn't be written: \(detail)"
            }
        }
    }

    static let sampleRate: Double = 24_000

    static var ffmpegURL: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Decodes each clip (WAV, MP3 or AAC) and appends it to one 24 kHz mono
    /// CAF file. Returns the chapter's length in seconds.
    @discardableResult
    static func writeChapter(clips: [Data], to url: URL) throws -> TimeInterval {
        guard !clips.isEmpty else { throw ExportError.noAudio }
        try? FileManager.default.removeItem(at: url)
        let output = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let target = output.processingFormat
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("alkispeak-clip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        for clip in clips {
            let file = scratch.appendingPathExtension(fileExtension(for: clip))
            try clip.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let input = try AVAudioFile(forReading: file)
            let source = input.processingFormat
            guard let converter = AVAudioConverter(from: source, to: target) else { continue }
            let chunk: AVAudioFrameCount = 8192
            var finished = false
            while !finished {
                let capacity = AVAudioFrameCount(Double(chunk) * target.sampleRate / source.sampleRate) + 1024
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
                var error: NSError?
                let status = converter.convert(to: out, error: &error) { _, inputStatus in
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk),
                          (try? input.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0
                    else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return buffer
                }
                if let error { throw error }
                if out.frameLength > 0 { try output.write(from: out) }
                finished = status == .endOfStream || status == .error
            }
        }
        return Double(output.length) / sampleRate
    }

    /// A single .m4b with chapter markers and the book's title.
    static func exportM4B(chapters: [(title: String, file: URL, duration: TimeInterval)], title: String, to output: URL) async throws {
        guard let ffmpeg = ffmpegURL else {
            throw ExportError.ffmpegFailed("ffmpeg isn't installed (brew install ffmpeg).")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("alkispeak-m4b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let list = work.appendingPathComponent("list.txt")
        try chapters.map { "file '\($0.file.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let metadata = work.appendingPathComponent("chapters.txt")
        try ffmetadata(title: title, chapters: chapters.map { ($0.title, $0.duration) }).write(to: metadata, atomically: true, encoding: .utf8)
        try await run(ffmpeg, [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "concat", "-safe", "0", "-i", list.path,
            "-i", metadata.path, "-map", "0:a", "-map_metadata", "1",
            "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart",
            output.path
        ])
    }

    /// One MP3 per chapter in `folder`, numbered in order.
    static func exportChapterFiles(chapters: [(title: String, file: URL, duration: TimeInterval)], to folder: URL) async throws {
        guard let ffmpeg = ffmpegURL else {
            throw ExportError.ffmpegFailed("ffmpeg isn't installed (brew install ffmpeg).")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, chapter) in chapters.enumerated() {
            let safe = chapter.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            let name = String(format: "%02d %@.mp3", index + 1, String(safe.prefix(60)))
            try await run(ffmpeg, [
                "-y", "-hide_banner", "-loglevel", "error", "-i", chapter.file.path,
                "-c:a", "libmp3lame", "-b:a", "96k",
                "-metadata", "title=\(chapter.title)", "-metadata", "track=\(index + 1)",
                folder.appendingPathComponent(name).path
            ])
        }
    }

    /// ffmpeg's metadata file: the title plus one [CHAPTER] per chapter in ms.
    static func ffmetadata(title: String, chapters: [(title: String, duration: TimeInterval)]) -> String {
        func escape(_ value: String) -> String {
            var result = ""
            for character in value {
                if "=;#\\\n".contains(character) { result.append("\\") }
                result.append(character)
            }
            return result
        }
        var lines = [";FFMETADATA1", "title=\(escape(title))", "artist=AlkiSpeak", "genre=Audiobook"]
        var start = 0
        for chapter in chapters {
            let end = start + max(1, Int((chapter.duration * 1000).rounded()))
            lines += ["", "[CHAPTER]", "TIMEBASE=1/1000", "START=\(start)", "END=\(end)", "title=\(escape(chapter.title))"]
            start = end
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func fileExtension(for clip: Data) -> String {
        let head = [UInt8](clip.prefix(12))
        if head.starts(with: Array("RIFF".utf8)) { return "wav" }
        if head.starts(with: Array("ID3".utf8)) || (head.count > 1 && head[0] == 0xFF && head[1] & 0xE0 == 0xE0) { return "mp3" }
        if head.count >= 8, Array(head[4..<8]) == Array("ftyp".utf8) { return "m4a" }
        if head.starts(with: Array("caff".utf8)) { return "caf" }
        return "wav"
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let detail = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ExportError.ffmpegFailed(String(decoding: detail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }
}
