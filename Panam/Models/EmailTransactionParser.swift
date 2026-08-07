import Foundation
import FoundationModels

enum EmailParsingError: LocalizedError {
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): reason
        }
    }
}

enum EmailTransactionParser {
    /// Parses a bank/card transaction-alert email into structured fields
    /// using the on-device foundation model — same pattern as
    /// VoiceTransactionParser, fed email text instead of a speech transcript.
    static func parse(emailBody: String,
                      subject: String,
                      categories: [Category],
                      accounts: [Account]) async throws -> ParsedTransaction {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw EmailParsingError.modelUnavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw EmailParsingError.modelUnavailable("Turn on Apple Intelligence in Settings to use email import.")
        case .unavailable(.modelNotReady):
            throw EmailParsingError.modelUnavailable("The on-device model isn't ready yet. Try again in a bit.")
        case .unavailable:
            throw EmailParsingError.modelUnavailable("The on-device model is unavailable.")
        }

        let categoryNames = categories.map(\.name).joined(separator: ", ")
        let accountNames = accounts.map(\.name).joined(separator: ", ")

        let instructions = """
            Parse a bank or card transaction alert email into a single \
            financial transaction. Amounts are in Indian rupees. The \
            email's subject line is: "\(subject)".

            For categoryName, choose the closest match from exactly these \
            category names, or leave it nil if none fits: \(categoryNames).

            For accountName, choose the closest match from exactly these \
            account names, or leave it nil if none fits: \(accountNames). \
            Bank/card alert emails usually name the account (e.g. "HDFC Bank \
            Card ending 1234") — match it to the closest account name above.

            Never invent a category or account name that is not in those \
            lists — return the chosen names exactly as written above.

            If the email is a debit/spend/payment alert, type is "expense". \
            If it's a credit/refund/salary alert, type is "income".
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: emailBody, generating: ParsedTransaction.self)
        return response.content
    }
}
