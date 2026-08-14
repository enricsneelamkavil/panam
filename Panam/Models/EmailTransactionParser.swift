import Foundation
import FoundationModels
import SwiftData

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

// MARK: - Refund matching

extension EmailTransactionParser {
    /// A window generous enough to cover slow bank/merchant refund
    /// processing (a week or two is typical) without reaching back so far
    /// it starts matching unrelated purchases.
    private static let refundWindowDays = 30

    /// After the model parses a candidate as a credit ("income"), checks
    /// whether it's actually a refund for a specific earlier expense on
    /// file — same/similar merchant, within refundWindowDays, amount no
    /// larger than the original debit, and not already claimed by another
    /// refund — and if one is found, reclassifies the candidate as
    /// .refund with that expense's category defaulted in (still editable
    /// before import, like any other field). Returns the unmatched
    /// original `parsed` and `nil` if nothing qualifies.
    ///
    /// Deterministic Swift-side post-processing, not part of the model's
    /// own instructions: matching requires searching existing Transaction
    /// records the model is never shown, so this always runs as a separate
    /// step after parse(_:), never in place of it.
    static func matchRefund(
        for parsed: ParsedTransaction, against transactions: [Transaction]
    ) -> (parsed: ParsedTransaction, matchedTransaction: Transaction?) {
        guard parsed.type.lowercased() == "income" else { return (parsed, nil) }

        // A debit that's already the refundedTransaction of some existing
        // refund has already been "claimed" — don't offer it again for a
        // second, unrelated credit that happens to fit the same window.
        let alreadyMatchedDebitIDs = Set(transactions.compactMap { $0.refundedTransaction?.persistentModelID })
        let creditDate = parsed.resolvedDate

        let candidates = transactions.filter { debit in
            debit.type.isExpenseLike
                && !debit.isExcludedFromFlow
                && !alreadyMatchedDebitIDs.contains(debit.persistentModelID)
                && parsed.amount <= debit.amount + 0.01
                && withinRefundWindow(debitDate: debit.date, creditDate: creditDate)
                && merchantMatches(parsed.merchantName, debit)
        }

        // Prefer the closest amount (a partial refund's fee gap should
        // still favor the debit it actually came from over a coincidentally
        // similar one), then the most recent debit as a final tiebreaker.
        guard let matched = candidates.min(by: { lhs, rhs in
            let lhsGap = lhs.amount - parsed.amount
            let rhsGap = rhs.amount - parsed.amount
            if abs(lhsGap - rhsGap) > 0.01 { return lhsGap < rhsGap }
            return lhs.date > rhs.date
        }) else {
            return (parsed, nil)
        }

        var reclassified = parsed
        reclassified.type = "refund"
        reclassified.categoryName = matched.category?.name
        return (reclassified, matched)
    }

    private static func withinRefundWindow(debitDate: Date, creditDate: Date) -> Bool {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: debitDate),
            to: calendar.startOfDay(for: creditDate)
        ).day ?? Int.max
        // A refund can't predate its own purchase, but a same-day pair
        // (days == 0) is common enough (instant/near-instant refunds) to allow.
        return days >= 0 && days <= refundWindowDays
    }

    /// Checks the credit's merchant guess against the debit's merchant name
    /// first, falling back to the debit's note — bank alert merchant names
    /// rarely match character-for-character ("AMAZON PAY INDIA" vs.
    /// "Amazon"), so this is deliberately a loose either-direction
    /// substring check rather than an exact-match comparison.
    private static func merchantMatches(_ creditMerchant: String?, _ debit: Transaction) -> Bool {
        guard let creditMerchant = normalized(creditMerchant) else { return false }
        if let debitMerchant = normalized(debit.merchantName), namesAreSimilar(creditMerchant, debitMerchant) {
            return true
        }
        guard let debitNote = normalized(debit.note) else { return false }
        return namesAreSimilar(creditMerchant, debitNote)
    }

    private static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func namesAreSimilar(_ a: String, _ b: String) -> Bool {
        a.contains(b) || b.contains(a)
    }
}
