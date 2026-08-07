import Foundation
import SwiftData

@Model
final class CardPayment {
    var type: CardPaymentType
    var amount: Double
    var feeAmount: Double?
    /// Bill Payment only: the portion of this payment that's more than what
    /// was already tracked as purchases on the card — interest, fees, or an
    /// unlogged purchase. Unlike the principal, this is a genuinely new
    /// cost, not debt settlement — see record(context:).
    var extraUnloggedAmount: Double = 0
    /// User-picked category for extraUnloggedAmount, since it isn't always a
    /// bank charge. Left nil (shows as "Uncategorized") if skipped.
    var extraAmountCategory: Category?
    var date: Date
    var note: String
    var card: Account?
    var sourceAccount: Account?
    var cardTransaction: Transaction?
    var sourceTransaction: Transaction?
    var feeTransaction: Transaction?

    init(type: CardPaymentType, amount: Double, feeAmount: Double? = nil,
         extraUnloggedAmount: Double = 0, extraAmountCategory: Category? = nil, date: Date = .now,
         note: String = "", card: Account? = nil, sourceAccount: Account? = nil) {
        self.type = type
        self.amount = amount
        self.feeAmount = feeAmount
        self.extraUnloggedAmount = extraUnloggedAmount
        self.extraAmountCategory = extraAmountCategory
        self.date = date
        self.note = note
        self.card = card
        self.sourceAccount = sourceAccount
    }
}

enum CardPaymentType: String, Codable, CaseIterable {
    case billPayment = "Bill Payment"
    case cashAdvance = "Cash Advance"
}

extension CardPaymentType: Identifiable {
    var id: String { rawValue }
}

extension CardPayment {
    /// Creates the source-account transaction — plus a separate fee transaction
    /// if a fee applies — (if a source account is set) and directly reduces the
    /// card's balance. Call right after inserting a new CardPayment.
    func record(context: ModelContext) {
        let category = fetchCategory(named: "Credit Card Bill", context: context)

        if let sourceAccount {
            // Bill Payment with an extra, not-already-logged portion: settle
            // only the principal here, flagged as before; the extra leg
            // below is a genuinely new cost, so it's booked as a separate,
            // unflagged transaction that does count towards spend.
            let settlementAmount = type == .billPayment ? amount - extraUnloggedAmount : amount

            let transaction = Transaction(
                amount: settlementAmount,
                date: date,
                note: noteForSourceTransaction(),
                type: .expense,
                account: sourceAccount,
                category: category
            )
            // Settles card debt already counted as spend when the original purchase
            // happened — exclude from Income/Expense/spend totals so it isn't counted twice.
            transaction.isCardPaymentSettlement = true
            context.insert(transaction)
            sourceTransaction = transaction
            sourceAccount.applyTransaction(amount: settlementAmount, type: .expense)

            // The fee (Cash Advance) or extra unlogged amount (Bill Payment) is
            // its own small, clearly-noted line item — never folded into the
            // settlement amount or the card's balance. Both are real new
            // costs, so neither is flagged as a settlement.
            if type == .cashAdvance, let feeAmount, feeAmount > 0 {
                recordFeeLeg(amount: feeAmount, note: "Advance payment fee",
                             category: category, sourceAccount: sourceAccount, context: context)
            } else if type == .billPayment, extraUnloggedAmount > 0 {
                recordFeeLeg(amount: extraUnloggedAmount, note: "Extra amount not already logged",
                             category: extraAmountCategory, sourceAccount: sourceAccount, context: context)
            }
        }

        // Direct mutation, not Transaction-mediated: this is the card's own
        // ledger reflecting the payment, not a second visible transaction.
        card?.balance -= amount

        MoneyEventSync.sync(cardPayment: self, context: context)
    }

    private func recordFeeLeg(amount: Double, note: String, category: Category?,
                               sourceAccount: Account, context: ModelContext) {
        let feeTx = Transaction(
            amount: amount,
            date: date,
            note: note,
            type: .expense,
            account: sourceAccount,
            category: category
        )
        context.insert(feeTx)
        feeTransaction = feeTx
        sourceAccount.applyTransaction(amount: amount, type: .expense)
    }

    /// Reverses and deletes the linked source transaction and, when present,
    /// the fee/extra leg (Cash Advance fee or Bill Payment extra unlogged amount) —
    /// then undoes the direct card balance mutation. For use when a CardPayment is deleted.
    func reverse(context: ModelContext) {
        if let sourceTransaction {
            sourceTransaction.account?.reverseTransaction(
                amount: sourceTransaction.amount, type: sourceTransaction.type
            )
            context.delete(sourceTransaction)
            self.sourceTransaction = nil
        }
        if let feeTransaction {
            feeTransaction.account?.reverseTransaction(
                amount: feeTransaction.amount, type: feeTransaction.type
            )
            context.delete(feeTransaction)
            self.feeTransaction = nil
        }
        card?.balance += amount
    }

    private func noteForSourceTransaction() -> String {
        switch type {
        case .billPayment: return "Payment to \(card?.name ?? "card")"
        case .cashAdvance: return "Advance payment to \(card?.name ?? "card")"
        }
    }

    private func fetchCategory(named name: String, context: ModelContext) -> Category? {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == name }
        )
        return try? context.fetch(descriptor).first
    }
}
