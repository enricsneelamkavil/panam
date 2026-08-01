import Foundation
import SwiftData

extension RecurringOccurrence {
    /// Marks this occurrence paid: records the actual amount, creates the
    /// linked expense Transaction from the template's account/category, and
    /// applies the balance adjustment. Shared by manual mark-as-paid and autopay.
    func markPaid(actualAmount: Double, context: ModelContext) {
        guard let payment = parent else { return }

        isPaid = true
        paidDate = .now
        self.actualAmount = actualAmount

        let transaction = Transaction(
            amount: actualAmount,
            date: .now,
            note: payment.name,
            type: .expense,
            account: payment.account,
            category: payment.category
        )
        context.insert(transaction)
        linkedTransaction = transaction
        payment.account?.applyTransaction(amount: actualAmount, type: .expense)
        MoneyEventSync.sync(paidRecurringOccurrence: self, context: context)
    }
}

enum AutopayProcessor {
    /// Pays every due-or-overdue unpaid occurrence whose template has autopay
    /// enabled, at the expected amount. Called once on app launch.
    static func processAutopays(context: ModelContext) {
        let now = Date.now
        let descriptor = FetchDescriptor<RecurringOccurrence>(
            predicate: #Predicate { !$0.isPaid && $0.dueDate <= now }
        )
        guard let dueOccurrences = try? context.fetch(descriptor) else { return }

        for occurrence in dueOccurrences where occurrence.parent?.autopayEnabled == true {
            occurrence.markPaid(actualAmount: occurrence.expectedAmount, context: context)
        }

        let investmentDescriptor = FetchDescriptor<InvestmentOccurrence>(
            predicate: #Predicate { !$0.isContributed && $0.dueDate <= now }
        )
        guard let dueInvestmentOccurrences = try? context.fetch(investmentDescriptor) else { return }

        for occurrence in dueInvestmentOccurrences where occurrence.parent?.autopayEnabled == true {
            occurrence.markContributed(actualAmount: occurrence.expectedAmount, context: context)
        }

        try? context.save()
    }
}
