import Foundation
import FoundationModels

enum VoiceParsingError: LocalizedError {
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): reason
        }
    }
}

enum VoiceTransactionParser {
    /// Parses a spoken transaction description into structured fields using
    /// the on-device foundation model, constrained to the app's real
    /// category and account names.
    static func parse(transcript: String,
                      categories: [Category],
                      accounts: [Account]) async throws -> ParsedTransaction {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw VoiceParsingError.modelUnavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw VoiceParsingError.modelUnavailable("Turn on Apple Intelligence in Settings to use voice entry.")
        case .unavailable(.modelNotReady):
            throw VoiceParsingError.modelUnavailable("The on-device model isn't ready yet. Try again in a bit.")
        case .unavailable:
            throw VoiceParsingError.modelUnavailable("The on-device model is unavailable.")
        }

        let categoryNames = categories.map(\.name).joined(separator: ", ")
        let accountNames = accounts.map(\.name).joined(separator: ", ")

        let instructions = """
            Parse the user's spoken description of a financial transaction. \
            Amounts are in Indian rupees.

            For categoryName, choose the closest match from exactly these \
            category names, or leave it nil if none fits: \(categoryNames).

            For accountName, choose the closest match from exactly these \
            account names, or leave it nil if none fits: \(accountNames).

            Never invent a category or account name that is not in those \
            lists — return the chosen names exactly as written above.
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: transcript, generating: ParsedTransaction.self)
        return response.content
    }
}
