import Foundation

struct AlkiSpeakError: Error, Identifiable, Codable, Hashable, LocalizedError {
    var id: UUID
    var code: String
    var title: String
    var message: String
    var recoverySuggestion: String
    var timestamp: Date
    var underlyingDescription: String?
    var context: [String: String]

    init(
        id: UUID = UUID(),
        code: String,
        title: String,
        message: String,
        recoverySuggestion: String,
        timestamp: Date = Date(),
        underlyingError: Error? = nil,
        context: [String: String] = [:]
    ) {
        self.id = id
        self.code = code
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.timestamp = timestamp
        self.underlyingDescription = underlyingError?.localizedDescription
        self.context = context
    }

    var errorDescription: String? { message }
    var failureReason: String? { title }

    static func engine(
        code: String,
        title: String,
        message: String,
        recoverySuggestion: String,
        underlyingError: Error? = nil,
        context: [String: String] = [:]
    ) -> AlkiSpeakError {
        AlkiSpeakError(
            code: "engine.\(code)",
            title: title,
            message: message,
            recoverySuggestion: recoverySuggestion,
            underlyingError: underlyingError,
            context: context
        )
    }

    static func generation(
        code: String,
        title: String,
        message: String,
        recoverySuggestion: String,
        underlyingError: Error? = nil,
        context: [String: String] = [:]
    ) -> AlkiSpeakError {
        AlkiSpeakError(
            code: "generation.\(code)",
            title: title,
            message: message,
            recoverySuggestion: recoverySuggestion,
            underlyingError: underlyingError,
            context: context
        )
    }

    static func playback(
        code: String,
        title: String,
        message: String,
        recoverySuggestion: String,
        underlyingError: Error? = nil,
        context: [String: String] = [:]
    ) -> AlkiSpeakError {
        AlkiSpeakError(
            code: "playback.\(code)",
            title: title,
            message: message,
            recoverySuggestion: recoverySuggestion,
            underlyingError: underlyingError,
            context: context
        )
    }
}
