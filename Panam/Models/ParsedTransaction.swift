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

    @Guide(description: "The transaction date as yyyy-MM-dd (ISO 8601), resolved from any spoken reference (e.g. 'yesterday', 'last Friday'); nil or omitted means today")
    var resolvedDateString: String?

    @Guide(description: "The payment method mentioned (e.g. 'cash', 'UPI', 'card'), or nil if not stated")
    var paymentMethodName: String?
}

extension ParsedTransaction {
    var resolvedDate: Date {
        guard let str = resolvedDateString else { return .now }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: str) ?? .now
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
