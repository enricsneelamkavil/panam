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
    /// Creates the linked pair of transactions for this payment and applies
    /// both balance adjustments. Call right after inserting a new CardPayment.
    func record(context: ModelContext) {
        switch type {
        case .billPayment: recordBillPayment(context: context)
        case .cashAdvance: recordCashAdvance(context: context)
        }
        MoneyEventSync.sync(cardPayment: self, context: context)
    }

    /// Reverses and deletes both linked transactions, for use when a
    /// CardPayment is deleted.
    func reverse(context: ModelContext) {
        if let cardTransaction {
            cardTransaction.account?.reverseTransaction(
                amount: cardTransaction.amount, type: cardTransaction.type
            )
            context.delete(cardTransaction)
            self.cardTransaction = nil
        }
        if let sourceTransaction {
            sourceTransaction.account?.reverseTransaction(
                amount: sourceTransaction.amount, type: sourceTransaction.type
            )
            context.delete(sourceTransaction)
            self.sourceTransaction = nil
        }
    }

    private func recordBillPayment(context: ModelContext) {
        let category = fetchCategory(named: "Credit Card Bill", context: context)

        // Income on a credit card account reduces outstanding debt.
        if let card {
            let transaction = Transaction(
                amount: amount,
                date: date,
                note: "Bill payment",
                type: .income,
                account: card,
                category: category
            )
            context.insert(transaction)
            cardTransaction = transaction
            card.applyTransaction(amount: amount, type: .income)
        }

        if let sourceAccount {
            let transaction = Transaction(
                amount: amount,
                date: date,
                note: "Payment to \(card?.name ?? "card")",
                type: .expense,
                account: sourceAccount,
                category: category
            )
            context.insert(transaction)
            sourceTransaction = transaction
            sourceAccount.applyTransaction(amount: amount, type: .expense)
        }
    }

    private func recordCashAdvance(context: ModelContext) {
        let category = findOrCreateCashAdvanceCategory(context: context)
        let fee = feeAmount ?? 0

        // The card owes the advance plus any fee.
        if let card {
            let cardNote = fee > 0
                ? "Cash advance (incl. \(fee.formatted(.currency(code: "INR").locale(Locale(identifier: "en_IN")))) fee)"
                : "Cash advance"
            let transaction = Transaction(
                amount: amount + fee,
                date: date,
                note: cardNote,
                type: .expense,
                account: card,
                category: category
            )
            context.insert(transaction)
            cardTransaction = transaction
            card.applyTransaction(amount: amount + fee, type: .expense)
        }

        // Only the advance itself lands as cash — the fee is card debt only.
        if let sourceAccount {
            let transaction = Transaction(
                amount: amount,
                date: date,
                note: "Cash advance from \(card?.name ?? "card")",
                type: .income,
                account: sourceAccount,
                category: category
            )
            context.insert(transaction)
            sourceTransaction = transaction
            sourceAccount.applyTransaction(amount: amount, type: .income)
        }
    }

    private func fetchCategory(named name: String, context: ModelContext) -> Category? {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == name }
        )
        return try? context.fetch(descriptor).first
    }

    /// The "Cash Advance" category isn't part of the seeded presets, so it's
    /// created on demand the first time it's needed.
    private func findOrCreateCashAdvanceCategory(context: ModelContext) -> Category {
        if let existing = fetchCategory(named: "Cash Advance", context: context) {
            return existing
        }
        let category = Category(name: "Cash Advance", icon: "banknote", isPreset: true)
        context.insert(category)
        return category
    }
}
