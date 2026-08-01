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
}
