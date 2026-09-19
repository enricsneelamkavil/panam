import Foundation
import SwiftData

@Model
final class Transaction {
    /// See Account.backupID.
    var backupID: UUID = UUID()
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
    /// Newline-separated methods for the uncommon case where one transaction
    /// was paid using more than one method. `paymentMethod` remains the primary
    /// method for compatibility with existing data and account filtering.
    var paymentMethodsRaw: String = ""
    /// JSON-encoded allocation details for the non-primary payment methods.
    var additionalPaymentMethodDetailsRaw: String = ""
    var upiApp: String?
    /// Set when this expense was paid by someone else on your behalf — no
    /// account is involved (`account == nil`), but it still counts as your
    /// spend (category/monthly totals) since it's your own consumption.
    /// A linked LendingEntry(kind: .borrowed) records that you owe them.
    var paidByPerson: Person?
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
    /// Set only on a .refund transaction — the original expense this credit
    /// refunds (see EmailTransactionParser.matchRefund). Lets the review UI
    /// show which purchase a matched refund belongs to, is where the
    /// refund's category default comes from, and marks that expense as
    /// already-matched so a later refund search doesn't offer it again.
    var refundedTransaction: Transaction?

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
    var additionalPaymentMethods: [AdditionalPaymentMethod] {
        get {
            guard let data = additionalPaymentMethodDetailsRaw.data(using: .utf8),
                  let details = try? JSONDecoder().decode([AdditionalPaymentMethod].self, from: data)
            else { return [] }
            return details
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                additionalPaymentMethodDetailsRaw = ""
                return
            }
            additionalPaymentMethodDetailsRaw = String(decoding: data, as: UTF8.self)
        }
    }

    var paymentMethods: [PaymentMethod] {
        get {
            let stored = paymentMethodsRaw
                .split(separator: "\n")
                .compactMap { PaymentMethod(rawValue: String($0)) }
            if !stored.isEmpty { return stored }
            return paymentMethod.map { [$0] } ?? []
        }
        set {
            let unique = newValue.reduce(into: [PaymentMethod]()) { methods, method in
                if !methods.contains(method) { methods.append(method) }
            }
            paymentMethodsRaw = unique.map(\.rawValue).joined(separator: "\n")
            paymentMethod = unique.first
        }
    }

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

struct AdditionalPaymentMethod: Identifiable, Codable, Hashable {
    var id = UUID()
    var method: PaymentMethod
    var detail: String = ""
    var amount: Double?
    var upiApp: String = ""
    var accountBackupID: UUID?
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

extension PaymentMethod {
    static func inferred(fromEmailValue value: String) -> PaymentMethod? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("upi") || normalized.contains("vpa") { return .upi }
        if normalized.contains("card") { return .card }
        if normalized.contains("bank") || normalized.contains("neft") || normalized.contains("imps") || normalized.contains("rtgs") { return .netBanking }
        if normalized.contains("wallet") { return .wallet }
        if normalized.contains("cash") || normalized.contains("atm") { return .cash }
        return allCases.first { $0.rawValue.lowercased() == normalized }
    }
}
