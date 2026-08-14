import Foundation
import FoundationModels

enum ReceiptParsingError: LocalizedError {
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): reason
        }
    }
}

enum ReceiptTransactionParser {
    /// Parses a photographed receipt's OCR'd text into a single financial
    /// transaction using the on-device foundation model — same
    /// LanguageModelSession/@Generable ParsedTransaction pattern as
    /// VoiceTransactionParser/EmailTransactionParser, fed the text Vision
    /// extracted from the receipt image instead of a speech transcript or
    /// email body.
    static func parse(receiptText: String,
                      categories: [Category],
                      accounts: [Account]) async throws -> ParsedTransaction {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw ReceiptParsingError.modelUnavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw ReceiptParsingError.modelUnavailable("Turn on Apple Intelligence in Settings to use receipt scanning.")
        case .unavailable(.modelNotReady):
            throw ReceiptParsingError.modelUnavailable("The on-device model isn't ready yet. Try again in a bit.")
        case .unavailable:
            throw ReceiptParsingError.modelUnavailable("The on-device model is unavailable.")
        }

        let categoryNames = categories.map(\.name).joined(separator: ", ")
        let accountNames = accounts.map(\.name).joined(separator: ", ")
        let paymentMethodNames = PaymentMethod.allCases.map(\.rawValue).joined(separator: ", ")

        let instructions = """
            Parse text OCR'd from a photographed receipt into a single \
            financial transaction. Amounts are in Indian rupees. The text \
            may contain OCR noise — misread characters, odd line breaks, \
            stray symbols — use your best judgment to recover the real \
            values from it.

            The transaction amount is the final total actually paid (look \
            for "Total", "Grand Total", or "Amount Paid"), not a subtotal, \
            a tax/service-charge line, or a single item's price.

            For categoryName, choose the closest match from exactly these \
            category names, or leave it nil if none fits: \(categoryNames).

            For accountName, choose the closest match from exactly these \
            account names, or leave it nil if none fits: \(accountNames). \
            Only set this if the receipt itself names a card or account \
            (e.g. "VISA ending 1234") — don't guess otherwise.

            For paymentMethodName, choose the closest match from exactly \
            these payment method names, or leave it nil if none fits: \
            \(paymentMethodNames).

            For lastFourDigits, extract the last 4 digits of a card number \
            only if one is visibly printed on the receipt (e.g. "XXXX1234" \
            or "ending 1234"), or leave it nil if none is shown.

            Never invent a category, account, or payment method name that \
            is not in those lists — return the chosen names exactly as \
            written above.

            Receipts are almost always a spend, so type is "expense" unless \
            the text clearly describes a refund or credit.
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: receiptText, generating: ParsedTransaction.self)
        return response.content
    }
}
