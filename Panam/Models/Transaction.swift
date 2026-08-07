import Foundation
import SwiftData

@Model
final class Transaction {
    var amount: Double
    var date: Date
    var note: String
    var type: TransactionType
    var merchantName: String?
    var account: Account?
    /// The destination account for transfer-like transactions. `account` is the source.
    var toAccount: Account?
    var category: Category?
    var paymentMethod: PaymentMethod?
    var upiApp: String?
    var isSplit: Bool = false
    /// The user's own share when `isSplit == true`. `amount` always holds the full total paid.
    var myPortionAmount: Double?
    /// True for the Transaction leg of a lending settlement (.repaymentReceived/.repaymentMade) —
    /// a debt settling, not real income/spend. Not set for .lent/.borrowed, which are real money movements.
    var isLendingRepayment: Bool = false
    /// True for the source-account transaction created by CardPayment.record(context:) for a
    /// Bill Payment or Cash Advance — settling card debt already counted as spend at purchase
    /// time, not new spending. Not set on the separate fee transaction, which is a genuine new cost.
    var isCardPaymentSettlement: Bool = false

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

    /// True for types that should not appear in Income or Expense aggregations —
    /// the type-level exclusions (transfers, adjustments) plus lending repayments,
    /// which settle a debt rather than representing real income/spend.
    nonisolated var isExcludedFromFlow: Bool {
        type.isExcludedFromFlow || isLendingRepayment || isCardPaymentSettlement
    }
}

enum TransactionType: String, Codable, CaseIterable {
    case income, expense
    case selfTransfer = "Self Transfer"
    case refund
    case cashWithdrawal = "Cash Withdrawal"
    case interest, dividend
    case taxAndFee = "Tax and Fee"
    case adjustment
}

extension TransactionType {
    /// True for types that increase account balance (income-direction).
    /// Used by balance adjustment and 7-day change calculation.
    /// Note: adjustment has a signed amount and bypasses this entirely.
    nonisolated var isIncomeLike: Bool {
        switch self {
        case .income, .interest, .dividend, .refund: true
        default: false
        }
    }

    /// True for types that count towards Expense totals directly (before refunds are netted out).
    nonisolated var isExpenseLike: Bool {
        switch self {
        case .expense, .taxAndFee: true
        default: false
        }
    }

    /// True for account-to-account transfers. Excluded from both Income and Expense totals.
    nonisolated var isTransferLike: Bool {
        switch self {
        case .selfTransfer, .cashWithdrawal: true
        default: false
        }
    }

    /// True for types that should not appear in Income or Expense aggregations.
    /// Includes transfers (no net flow) and adjustments (balance corrections, not real transactions).
    nonisolated var isExcludedFromFlow: Bool {
        isTransferLike || self == .adjustment
    }

    nonisolated var displayName: String {
        switch self {
        case .income: "Income"
        case .expense: "Expense"
        case .selfTransfer: "Transfer"
        case .refund: "Refund"
        case .cashWithdrawal: "Cash Withdrawal"
        case .interest: "Interest"
        case .dividend: "Dividend"
        case .taxAndFee: "Tax & Fee"
        case .adjustment: "Adjustment"
        }
    }
}

enum PaymentMethod: String, Codable, CaseIterable {
    case cash = "Cash", upi = "UPI", card = "Card", netBanking = "Net Banking", wallet = "Wallet", other = "Other"
}
