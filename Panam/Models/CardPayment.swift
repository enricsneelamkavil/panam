import Foundation
import SwiftData

@Model
final class CardPayment {
    var type: CardPaymentType
    var amount: Double
    var feeAmount: Double?
    var date: Date
    var note: String
    var card: Account?
    var sourceAccount: Account?
    var cardTransaction: Transaction?
    var sourceTransaction: Transaction?
    var feeTransaction: Transaction?

    init(type: CardPaymentType, amount: Double, feeAmount: Double? = nil, date: Date = .now,
         note: String = "", card: Account? = nil, sourceAccount: Account? = nil) {
        self.type = type
        self.amount = amount
        self.feeAmount = feeAmount
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
            let transaction = Transaction(
                amount: amount,
                date: date,
                note: noteForSourceTransaction(),
                type: .expense,
                account: sourceAccount,
                category: category
            )
            context.insert(transaction)
            sourceTransaction = transaction
            sourceAccount.applyTransaction(amount: amount, type: .expense)

            // The fee is its own small, clearly-noted line item — never folded
            // into the main amount or the card's balance.
            if let feeAmount, feeAmount > 0 {
                let feeTx = Transaction(
                    amount: feeAmount,
                    date: date,
                    note: "Advance payment fee",
                    type: .expense,
                    account: sourceAccount,
                    category: category
                )
                context.insert(feeTx)
                feeTransaction = feeTx
                sourceAccount.applyTransaction(amount: feeAmount, type: .expense)
            }
        }

        // Direct mutation, not Transaction-mediated: this is the card's own
        // ledger reflecting the payment, not a second visible transaction.
        card?.balance -= amount

        MoneyEventSync.sync(cardPayment: self, context: context)
    }

    /// Reverses and deletes the linked source/fee transactions (if any) and
    /// undoes the direct card balance mutation, for use when a CardPayment is deleted.
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
