import Foundation
import FoundationModels

@Generable
struct ParsedTransaction {
    @Guide(description: "The transaction amount as a positive number")
    var amount: Double

    @Guide(description: "Either 'expense' or 'income'")
    var type: String

    @Guide(description: "The closest matching category name from the provided list, or nil if unclear")
    var categoryName: String?

    @Guide(description: "The closest matching account name from the provided list, or nil if unclear")
    var accountName: String?

    @Guide(description: "A short note capturing any extra detail mentioned, or nil")
    var note: String?

    @Guide(description: "The merchant or payee name mentioned, or nil if unclear")
    var merchantName: String?

    @Guide(description: "The last 4 digits of the account/card number mentioned (e.g. from 'XX1234' or 'ending 1234'), or nil if not stated")
    var lastFourDigits: String?

    @Guide(description: "The transaction date, resolved from any spoken reference (e.g. 'yesterday', 'last Friday') and written in STRICT yyyy-MM-dd (ISO 8601) format only — 4-digit year, then 2-digit month, then 2-digit day, separated by hyphens (e.g. \"2026-07-14\" for 14 July 2026). Never day-first, never a slash-separated format, never a month name. nil or omitted means today.")
    var resolvedDateString: String?

    @Guide(description: "The payment method mentioned. Use one of: Cash, UPI, Card, Net Banking, Wallet, or Other. Return nil if not stated.")
    var paymentMethodName: String?

    @Guide(description: "Only true if this email reports a specific, single debit or credit that happened to a specific account — not a promotional offer, fee schedule, policy update, or general notice, even if it mentions rupee amounts.")
    var isGenuineTransaction: Bool
}

extension ParsedTransaction {
    var resolvedDate: Date {
        guard let str = resolvedDateString else { return .now }
        return Self.parseFlexibleDate(str) ?? .now
    }

    /// True only when resolvedDateString carries actual text that none of
    /// parseFlexibleDate's known formats could make sense of — a genuine
    /// parse failure, not the ordinary "no date given" case (a nil/blank
    /// resolvedDateString, which legitimately means "today" per this
    /// struct's own contract for voice/email entries — see
    /// resolvedDateString's @Guide). resolvedDate above still needs *some*
    /// concrete Date regardless (AddEditTransactionView and quick-import
    /// bind straight to it), so this exists purely so a review-list row can
    /// tell the difference and warn the user rather than quietly presenting
    /// today's date as if it were the statement's real one — see
    /// StatementCandidateRow.
    var dateNeedsReview: Bool {
        guard let str = resolvedDateString?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else {
            return false
        }
        return Self.parseFlexibleDate(str) == nil
    }

    /// Tries the format the model is instructed to emit first, then a
    /// handful of formats real-world sources actually print dates in.
    /// Necessary because the instruction alone isn't reliable: testing
    /// StatementReconciler against a real ICICI Amazon Pay statement showed
    /// the on-device model consistently echoing the statement's own printed
    /// dd/MM/yyyy dates verbatim (e.g. "14/07/2026") instead of converting
    /// to the requested yyyy-MM-dd, for every single line item — not an
    /// occasional slip.
    static func parseFlexibleDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in dateParsers {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    /// en_US_POSIX locale on every formatter so parsing doesn't depend on
    /// the device's own locale/calendar (the standard fix for DateFormatter
    /// silently misparsing fixed-format strings); isLenient left at its
    /// default false so e.g. "14/07/2026" is never accidentally accepted by
    /// the "dd-MM-yyyy" formatter or similar. Ordered with the requested
    /// ISO format first, then formats actually observed or plausible for
    /// bank-statement/email dates, roughly most- to least-likely.
    private static let dateParsers: [DateFormatter] = [
        "yyyy-MM-dd",
        "dd/MM/yyyy",
        "dd-MM-yyyy",
        "dd-MMM-yyyy",
        "d MMM yyyy",
        "MM/dd/yyyy",
        "yyyy/MM/dd",
    ].map { format in
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    /// Resolves the raw `type` string to a concrete TransactionType.
    /// "refund" is never something a parser's model instructions ask for
    /// directly on email import (see EmailTransactionParser) — it only
    /// appears there after EmailTransactionParser.matchRefund reclassifies
    /// an "income" candidate. ReceiptTransactionParser's model, on the
    /// other hand, can produce "refund" directly when a receipt itself
    /// reads as one. Either way, this is the one place that string gets
    /// turned into an actual TransactionType, so every call site —
    /// AddEditTransactionView.apply(_:), EmailManagementView's quick-import
    /// — treats "refund" consistently instead of each re-deriving its own
    /// (previously binary income/expense) mapping.
    var resolvedType: TransactionType {
        switch type.lowercased() {
        case "income": .income
        case "refund": .refund
        default: .expense
        }
    }
}
