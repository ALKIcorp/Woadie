import Foundation

/// Which cleanup rules run before speaking. Each can be turned off in Settings.
struct TextCleanupOptions: Codable, Equatable {
    static let defaultsKey = "AlkiSpeak.textCleanup"

    var isEnabled = true
    /// Headings, bold/italic markers, bullets, links, images, code blocks, HTML tags.
    var formatting = true
    /// Web addresses and email addresses read as "link to github dot com".
    var links = true
    /// Citation markers like [12] and [citation needed].
    var citations = true
    /// Version numbers like v1.2.3 read as "version 1 point 2 point 3".
    var versions = true
    /// Lines a PDF broke mid-sentence are joined back up.
    var lineWraps = true

    static func load(from defaults: UserDefaults = .standard) -> TextCleanupOptions {
        guard let data = defaults.data(forKey: defaultsKey),
              let options = try? JSONDecoder().decode(TextCleanupOptions.self, from: data)
        else { return TextCleanupOptions() }
        return options
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// A word and how to say it. A spoken form between slashes ("/ˈælki/") is
/// phonemes, which Kokoro voices read directly; other voices skip those entries.
struct PronunciationEntry: Codable, Identifiable, Hashable {
    static let defaultsKey = "AlkiSpeak.pronunciations"

    var id = UUID()
    var word: String
    var sayAs: String

    var isPhonemes: Bool {
        let trimmed = sayAs.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 2 && trimmed.hasPrefix("/") && trimmed.hasSuffix("/")
    }

    static func load(from defaults: UserDefaults = .standard) -> [PronunciationEntry] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PronunciationEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [PronunciationEntry], to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: defaultsKey)
    }

    /// The import/export file: a list of `{"word": …, "sayAs": …}`.
    static func exportJSON(_ entries: [PronunciationEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries.map { ["word": $0.word, "sayAs": $0.sayAs] })
    }

    static func importJSON(_ data: Data) throws -> [PronunciationEntry] {
        try JSONDecoder().decode([[String: String]].self, from: data).compactMap { row in
            guard let word = row["word"], !word.isEmpty, let sayAs = row["sayAs"] else { return nil }
            return PronunciationEntry(word: word, sayAs: sayAs)
        }
    }
}

/// Turns written text into what should be spoken. Pure and unit-tested.
/// Expression tags (`[Laughter]`) and dialogue labels (`Joe:`) pass through.
enum TextNormalizer {
    static func clean(_ text: String, options: TextCleanupOptions = TextCleanupOptions()) -> String {
        guard options.isEnabled else { return text }
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        if options.formatting { result = stripFormatting(result) }
        if options.citations { result = stripCitations(result) }
        if options.links { result = speakLinks(result) }
        if options.versions { result = speakVersions(result) }
        if options.lineWraps { result = joinWrappedLines(result) }
        return tidyWhitespace(result)
    }

    /// Applies the pronunciation list as whole-word, case-insensitive swaps.
    /// Phoneme entries become Kokoro's `[word](/phonemes/)` markup on Kokoro
    /// voices and are skipped elsewhere.
    static func applyPronunciations(_ text: String, entries: [PronunciationEntry], phonemesSupported: Bool) -> String {
        var result = text
        for entry in entries {
            let word = entry.word.trimmingCharacters(in: .whitespaces)
            let sayAs = entry.sayAs.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !sayAs.isEmpty else { continue }
            if entry.isPhonemes && !phonemesSupported { continue }
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            if entry.isPhonemes {
                // Keep the word as written; the phonemes say how to read it.
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[$0](" + NSRegularExpression.escapedTemplate(for: sayAs) + ")")
            } else {
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: sayAs))
            }
        }
        return result
    }

    // MARK: Rules

    static func stripFormatting(_ text: String) -> String {
        var t = text
        // Code blocks are noise when read aloud.
        t = replace(#"```[\s\S]*?```"#, in: t, with: "(code omitted)")
        // Images and links keep their visible words.
        t = replace(#"!\[([^\]]*)\]\([^)]*\)"#, in: t, with: "$1")
        t = replace(#"\[([^\]]+)\]\((?:https?:|mailto:|/|#|www\.)[^)]*\)"#, in: t, with: "$1")
        t = replace(#"`([^`\n]+)`"#, in: t, with: "$1")
        // HTML tags (a letter right after "<", so "a < b" is left alone).
        t = replace(#"</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>"#, in: t, with: " ")
        // Line-start markers: headings, quotes, bullets, rules, table pipes.
        t = replace(#"(?m)^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$"#, in: t, with: "$1.")
        t = replace(#"(?m)^\s{0,3}>\s?"#, in: t, with: "")
        t = replace(#"(?m)^\s*[-*+•]\s+"#, in: t, with: "")
        t = replace(#"(?m)^\s*([-*_]\s*){3,}$"#, in: t, with: "")
        t = replace(#"(?m)^\s*\|?(\s*:?-+:?\s*\|)+\s*:?-*:?\s*$"#, in: t, with: "")
        t = replace(#"\s*\|\s*"#, in: t, with: ", ")
        // Emphasis markers around words.
        t = replace(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, in: t, with: "$2")
        t = replace(#"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, in: t, with: "$1")
        t = replace(#"(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])"#, in: t, with: "$1")
        t = replace(#"~~(.+?)~~"#, in: t, with: "$1")
        // A heading that already ended in punctuation doesn't need the added period.
        t = replace(#"([.!?:])\.(?=\s|$)"#, in: t, with: "$1")
        return t
    }

    static func stripCitations(_ text: String) -> String {
        var t = replace(#"\[\s*\d+(\s*[,–-]\s*\d+)*\s*\]"#, in: text, with: "")
        t = replace(#"\[\s*(citation needed|clarification needed|when\?|who\?|according to whom\?)\s*\]"#, in: t, with: "", options: .caseInsensitive)
        return t
    }

    static func speakLinks(_ text: String) -> String {
        var t = text
        // Emails first, so their domain isn't read as a web link.
        t = replaceMatches(#"\b([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)\b"#, in: t) { groups in
            "\(groups[1]) at \(spokenDomain(groups[2]))"
        }
        t = replaceMatches(#"\b(?:https?://|www\.)[^\s<>()\[\]]+"#, in: t) { groups in
            var link = groups[0]
            // Keep sentence punctuation that followed the link.
            var trailing = ""
            while let last = link.last, ".,;:!?'\"".contains(last) {
                trailing = String(last) + trailing
                link.removeLast()
            }
            let withScheme = link.lowercased().hasPrefix("www.") ? "https://" + link : link
            guard let host = URL(string: withScheme)?.host() else { return groups[0] }
            let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return "link to \(spokenDomain(domain))" + trailing
        }
        return t
    }

    static func speakVersions(_ text: String) -> String {
        replaceMatches(#"(?<![\w.])(?:[vV](\d+(?:\.\d+)+)|(\d+\.\d+\.\d+(?:\.\d+)*))(?![\w.]*\d)"#, in: text) { groups in
            let number = groups[1].isEmpty ? groups[2] : groups[1]
            return "version " + number.split(separator: ".").joined(separator: " point ")
        }
    }

    /// Joins a line to the next when the sentence clearly continues: no end
    /// punctuation before the break and a lowercase letter after it.
    static func joinWrappedLines(_ text: String) -> String {
        replace(#"(?<=[\p{L}\p{N},;])[ \t]*\n(?=[ \t]*\p{Ll})"#, in: text, with: " ")
    }

    static func tidyWhitespace(_ text: String) -> String {
        var t = replace(#"[ \t]{2,}"#, in: text, with: " ")
        t = replace(#"[ \t]+([.,;:!?])"#, in: t, with: "$1")
        t = replace(#"(?m)[ \t]+$"#, in: t, with: "")
        t = replace(#"\n{3,}"#, in: t, with: "\n\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func spokenDomain(_ domain: String) -> String {
        domain.lowercased().split(separator: ".").joined(separator: " dot ")
    }

    // MARK: Regex helpers

    private static func replace(_ pattern: String, in text: String, with template: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Replaces each match with `transform(groups)`, where groups[0] is the whole match.
    private static func replaceMatches(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result) else { continue }
            let groups = (0..<match.numberOfRanges).map { index -> String in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            result.replaceSubrange(whole, with: transform(groups))
        }
        return result
    }
}
