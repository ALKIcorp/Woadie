import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// A document turned into plain text for speaking.
struct ImportedDocument: Equatable {
    var title: String
    var text: String
    /// Where it came from: a file name or a web site's host.
    var source: String
    /// The text was cut to `DocumentImporter.maxCharacters` to keep the editor responsive.
    var wasTruncated = false
    /// Two or more makes it a book, listened to a chapter at a time.
    var chapters: [BookChapter] = []

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

enum DocumentImportError: LocalizedError, Equatable {
    case scannedPDF
    case empty(String)
    case unsupported(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .scannedPDF:
            return "This PDF is scanned images with no text in it, so there's nothing to read aloud."
        case .empty(let name):
            return "\(name) has no readable text."
        case .unsupported(let name):
            return "AlkiSpeak can't read \(name). Try a PDF, EPUB, Word, RTF, HTML, Markdown or text file."
        case .unreadable(let reason):
            return reason
        }
    }
}

/// Reads PDFs, EPUBs, Word/RTF/HTML/Markdown/text files and web pages into
/// plain text. The text-shaping steps are pure functions so they can be tested
/// without files.
enum DocumentImporter {
    /// About 60,000 words. Longer books are cut so the editor stays responsive.
    static let maxCharacters = 400_000

    static let epubType = UTType(filenameExtension: "epub") ?? .data
    static let markdownType = UTType(filenameExtension: "md") ?? .plainText
    static let docxType = UTType("org.openxmlformats.wordprocessingml.document") ?? .data

    /// What the Open panel and drag-and-drop accept.
    static var readableTypes: [UTType] {
        [.pdf, epubType, docxType, .rtf, .rtfd, .html, markdownType, .plainText]
    }

    // MARK: Files

    static func importDocument(at url: URL) async throws -> ImportedDocument {
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let result: (title: String?, text: String)
        var chapters: [BookChapter]?
        if type?.conforms(to: .pdf) == true {
            result = try pdf(at: url)
        } else if url.pathExtension.lowercased() == "epub" {
            let book = try epub(at: url)
            result = (book.title, book.chapters.map(\.text).joined(separator: "\n\n"))
            chapters = book.chapters
        } else if type?.conforms(to: .html) == true {
            let html = try readString(url)
            result = article(fromHTML: html)
        } else if type?.conforms(to: .rtf) == true || type?.conforms(to: .rtfd) == true
                    || type?.conforms(to: docxType) == true || url.pathExtension.lowercased() == "doc" {
            result = (nil, try attributedText(url))
        } else if type?.conforms(to: .text) == true || url.pathExtension.lowercased() == "md" {
            result = (nil, try readString(url))
        } else {
            throw DocumentImportError.unsupported(name)
        }
        let title = result.title ?? fallbackTitle
        return try finish(
            title: title,
            text: result.text,
            source: name,
            chapters: chapters ?? ChapterSplitter.chapters(in: result.text, fallbackTitle: title)
        )
    }

    // MARK: Web pages

    static func importWebPage(_ url: URL, session: URLSession = .shared) async throws -> ImportedDocument {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Some sites serve a stripped page to unknown clients.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DocumentImportError.unreadable("\(url.host() ?? "The site") answered with error \(http.statusCode).")
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let page = article(fromHTML: html)
        return try finish(title: page.title ?? url.host() ?? "Web page", text: page.text, source: url.host() ?? url.absoluteString)
    }

    /// A lone http(s) link in `text`, e.g. a pasted or dropped URL.
    static func webURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil
        else { return nil }
        return url
    }

    // MARK: PDF

    private static func pdf(at url: URL) throws -> (title: String?, text: String) {
        guard let document = PDFDocument(url: url) else {
            throw DocumentImportError.unreadable("\(url.lastPathComponent) couldn't be opened as a PDF.")
        }
        if document.isLocked {
            throw DocumentImportError.unreadable("\(url.lastPathComponent) is password-protected.")
        }
        let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        let text = pdfText(pages: pages)
        // Scanned pages yield little or no text.
        if text.count < max(40, pages.count * 20) {
            throw DocumentImportError.scannedPDF
        }
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false ? title : nil, text)
    }

    /// Joins PDF pages, dropping running headers and footers (lines repeated at
    /// the top or bottom of most pages), bare page numbers, and hyphens that
    /// only split a word across a line break.
    static func pdfText(pages: [String]) -> String {
        let split = pages.map { page in
            page.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        // A short header like "Chapter 3 · Page 12" differs only in its
        // digits; longer lines must repeat exactly to count.
        func shape(_ line: String) -> String {
            let lower = line.lowercased()
            return line.count <= 30
                ? lower.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
                : lower
        }
        // Short pages only have room for one header and one footer line.
        func edgeDepth(_ lines: [String]) -> Int { lines.count >= 6 ? 2 : 1 }
        var edgeCounts: [String: Int] = [:]
        for lines in split {
            let depth = edgeDepth(lines)
            let edges = Set(lines.prefix(depth).map(shape) + lines.suffix(depth).map(shape))
            for edge in edges { edgeCounts[edge, default: 0] += 1 }
        }
        let repeated = split.count >= 3
            ? Set(edgeCounts.filter { $0.value * 2 >= split.count }.keys)
            : []
        let pageNumber = try! NSRegularExpression(pattern: #"^(page\s*)?\d+(\s*(of|/)\s*\d+)?$"#, options: .caseInsensitive)

        let cleanedPages = split.map { lines -> String in
            var kept: [String] = []
            let depth = edgeDepth(lines)
            for (index, line) in lines.enumerated() {
                let atEdge = index < depth || index >= lines.count - depth
                if atEdge {
                    if repeated.contains(shape(line)) { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    if pageNumber.firstMatch(in: line, range: range) != nil { continue }
                }
                kept.append(line)
            }
            return kept.joined(separator: "\n")
        }
        let joined = cleanedPages.filter { !$0.isEmpty }.joined(separator: "\n\n")
        // "exam-\nple" → "example"
        return joined.replacingOccurrences(of: #"(\p{Ll})-\n(\p{Ll})"#, with: "$1$2", options: .regularExpression)
    }

    // MARK: EPUB

    private static func epub(at url: URL) throws -> (title: String?, chapters: [BookChapter]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("alkispeak-epub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", url.path, folder.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw DocumentImportError.unreadable("\(url.lastPathComponent) couldn't be unpacked as an EPUB.")
        }
        let container = try readString(folder.appendingPathComponent("META-INF/container.xml"))
        guard let opfPath = firstMatch(#"full-path\s*=\s*"([^"]+)""#, in: container) else {
            throw DocumentImportError.unreadable("\(url.lastPathComponent) has no table of contents.")
        }
        let opfURL = folder.appendingPathComponent(opfPath)
        let opf = try readString(opfURL)
        let chapters = epubChapterPaths(opf: opf)
        let base = opfURL.deletingLastPathComponent()
        var parts: [BookChapter] = []
        for path in chapters {
            let file = base.appendingPathComponent(path.removingPercentEncoding ?? path)
            guard let html = try? readString(file) else { continue }
            let text = plainText(fromHTML: html).trimmingCharacters(in: .whitespacesAndNewlines)
            // Cover pages are an image with a word or none.
            guard text.split(whereSeparator: \.isWhitespace).count >= 2 else { continue }
            let heading = firstMatch(#"<h[1-3][^>]*>([\s\S]*?)</h[1-3]>"#, in: html).map { plainText(fromHTML: $0) }
            let name = heading.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(parts.count + 1)"
            parts.append(BookChapter(title: String(name.prefix(80)), text: text))
        }
        let title = firstMatch(#"<dc:title[^>]*>([\s\S]*?)</dc:title>"#, in: opf).map(decodeEntities)
        return (title, parts)
    }

    /// The chapter files in reading (spine) order.
    static func epubChapterPaths(opf: String) -> [String] {
        var hrefs: [String: String] = [:]
        for item in matches(#"<item\b[^>]*>"#, in: opf) {
            if let id = firstMatch(#"\bid\s*=\s*"([^"]+)""#, in: item),
               let href = firstMatch(#"\bhref\s*=\s*"([^"]+)""#, in: item) {
                hrefs[id] = href
            }
        }
        return matches(#"<itemref\b[^>]*>"#, in: opf).compactMap { ref in
            firstMatch(#"\bidref\s*=\s*"([^"]+)""#, in: ref).flatMap { hrefs[$0] }
        }
    }

    // MARK: HTML

    /// The page title and its main text: the largest `<article>`, else
    /// `<main>`, else every paragraph, with navigation, menus and footers removed.
    static func article(fromHTML html: String) -> (title: String?, text: String) {
        let ogTitle = firstMatch(#"<meta[^>]+property\s*=\s*"og:title"[^>]+content\s*=\s*"([^"]*)""#, in: html)
        let pageTitle = firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html)
        let title = (ogTitle ?? pageTitle).map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var body = removingBlocks(["script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form", "button"], from: html)
        if let largest = matches(#"<article\b[\s\S]*?</article>"#, in: body).max(by: { $0.count < $1.count }) {
            body = largest
        } else if let main = matches(#"<main\b[\s\S]*?</main>"#, in: body).max(by: { $0.count < $1.count }) {
            body = main
        } else {
            let paragraphs = matches(#"<(p|h[1-6]|li|blockquote)\b[\s\S]*?</\1>"#, in: body)
                .map { plainText(fromHTML: $0) }
                .filter { $0.count > 40 || $0.split(separator: " ").count > 3 }
            if !paragraphs.isEmpty {
                return (title?.isEmpty == false ? title : nil, paragraphs.joined(separator: "\n\n"))
            }
        }
        return (title?.isEmpty == false ? title : nil, plainText(fromHTML: body))
    }

    /// Strips tags and decodes entities, keeping block elements as line breaks.
    static func plainText(fromHTML html: String) -> String {
        var text = removingBlocks(["script", "style", "noscript", "svg", "head"], from: html)
        text = text.replacingOccurrences(
            of: #"<\s*(br|/p|/div|/h[1-6]|/li|/tr|/section|/article|/blockquote|/title)\b[^>]*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        // Collapse runs of blank lines into one paragraph break.
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}",
                     "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}"]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        for match in numeric.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let hexRange = Range(match.range(at: 1), in: result),
                  let digitsRange = Range(match.range(at: 2), in: result),
                  let code = UInt32(result[digitsRange], radix: result[hexRange].isEmpty ? 10 : 16),
                  let scalar = Unicode.Scalar(code)
            else { continue }
            result.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return result
    }

    // MARK: Helpers

    private static func finish(title: String, text: String, source: String, chapters: [BookChapter] = []) throws -> ImportedDocument {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw DocumentImportError.empty(source) }
        if chapters.count >= 2 {
            // A book shows one chapter at a time, so it isn't cut short.
            return ImportedDocument(title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: body, source: source, chapters: chapters)
        }
        var truncated = false
        if body.count > maxCharacters {
            let cut = body.index(body.startIndex, offsetBy: maxCharacters)
            let paragraph = body[..<cut].range(of: "\n\n", options: .backwards)?.lowerBound ?? cut
            body = String(body[..<paragraph])
            truncated = true
        }
        return ImportedDocument(title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: body, source: source, wasTruncated: truncated)
    }

    private static func readString(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    private static func attributedText(_ url: URL) throws -> String {
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        } catch {
            throw DocumentImportError.unreadable("\(url.lastPathComponent) couldn't be read: \(error.localizedDescription)")
        }
    }

    private static func removingBlocks(_ tags: [String], from html: String) -> String {
        var result = html
        for tag in tags {
            result = result.replacingOccurrences(
                of: "<\(tag)\\b[\\s\\S]*?</\(tag)\\s*>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
