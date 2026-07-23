import Foundation
import SwiftData

@Model
final class Transaction {
    var amount: Double
    var date: Date
    var note: String
    var type: TransactionType
    var account: Account?
    /// The destination account for .selfTransfer transactions. `account` is the source.
    var toAccount: Account?
    var category: Category?
    var paymentMethod: PaymentMethod?
    var upiApp: String?
    var isSplit: Bool = false
    /// The user's own share when `isSplit == true`. `amount` always holds the full total paid.
    var myPortionAmount: Double?

    @Relationship(deleteRule: .cascade, inverse: \SplitAllocation.transaction)
    var splitAllocations: [SplitAllocation] = []

    init(amount: Double, date: Date = .now, note: String = "",
         type: TransactionType, account: Account? = nil, category: Category? = nil) {
        self.amount = amount
        self.date = date
        self.note = note
        self.type = type
        self.account = account
        self.category = category
    }
}

extension Transaction {
    /// Amount to count towards personal spend/income aggregations.
    /// For split transactions this is the user's own share; otherwise the full amount.
    nonisolated var effectiveAmount: Double {
        isSplit ? (myPortionAmount ?? amount) : amount
    }
}

enum TransactionType: String, Codable, CaseIterable {
    case income, expense
    case selfTransfer = "Self Transfer"
}

enum PaymentMethod: String, Codable, CaseIterable {
    case cash = "Cash", upi = "UPI", card = "Card", netBanking = "Net Banking", wallet = "Wallet", other = "Other"
}
