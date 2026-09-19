import Foundation
import SwiftData

@Model
final class InvestmentOccurrence {
    /// See Account.backupID.
    var backupID: UUID = UUID()
    var dueDate: Date
    var expectedAmount: Double
    var actualAmount: Double?
    var isContributed: Bool
    var contributedDate: Date?
    var isBounced: Bool = false
    var bouncedDate: Date?
    var linkedTransaction: Transaction?
    var parent: Investment?

    init(dueDate: Date, expectedAmount: Double, parent: Investment? = nil) {
        self.dueDate = dueDate
        self.expectedAmount = expectedAmount
        self.isContributed = false
        self.parent = parent
    }
}

extension InvestmentOccurrence {
    /// Marks this occurrence contributed: records the actual amount, creates
    /// the linked expense Transaction against the parent investment's account
    /// with the preset "Investment" category, and applies the balance
    /// adjustment. Same pattern as RecurringOccurrence.markPaid.
    func markContributed(actualAmount: Double, context: ModelContext) {
        guard let investment = parent else { return }

        isContributed = true
        contributedDate = .now
        self.actualAmount = actualAmount

        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == "Investment" }
        )
        let category = try? context.fetch(descriptor).first

        let transaction = Transaction(
            amount: actualAmount,
            date: .now,
            note: investment.name,
            type: .expense,
            account: investment.account,
            category: category
        )
        context.insert(transaction)
        linkedTransaction = transaction
        investment.account?.applyTransaction(amount: actualAmount, type: .expense)
        MoneyEventSync.sync(contributedInvestmentOccurrence: self, context: context)
    }
}
