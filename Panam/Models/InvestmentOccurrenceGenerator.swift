import Foundation
import SwiftData

enum InvestmentOccurrenceGenerator {
    /// Creates any missing occurrences for a recurring investment, from its
    /// start date up to `monthsAhead` months from today. Existing occurrences
    /// (contributed or not) are never touched — mirrors RecurringOccurrenceGenerator.
    static func generateOccurrences(for investment: Investment,
                                    monthsAhead: Int = 12,
                                    context: ModelContext) {
        guard investment.isRecurring, investment.isActive,
              let cadence = investment.cadence
        else { return }

        let calendar = Calendar.current
        guard let horizon = calendar.date(byAdding: .month, value: monthsAhead, to: .now)
        else { return }

        // Compare by start-of-day so time-of-day differences don't cause duplicates.
        let existingDueDays = Set(investment.occurrences.map { calendar.startOfDay(for: $0.dueDate) })

        var dueDate = investment.date
        while dueDate <= horizon {
            if !existingDueDays.contains(calendar.startOfDay(for: dueDate)) {
                let occurrence = InvestmentOccurrence(
                    dueDate: dueDate,
                    expectedAmount: investment.amount,
                    parent: investment
                )
                context.insert(occurrence)
            }
            guard let next = calendar.date(byAdding: cadence.step, to: dueDate),
                  next > dueDate
            else { break }
            dueDate = next
        }
    }

    /// Deletes all uncontributed future occurrences and regenerates them from
    /// the template's current amount/cadence. Call after editing a recurring
    /// investment so projections update while history stays untouched.
    static func regenerateFutureUncontributed(for investment: Investment, context: ModelContext) {
        let now = Date.now
        for occurrence in investment.occurrences
        where !occurrence.isContributed && occurrence.dueDate > now {
            context.delete(occurrence)
        }
        generateOccurrences(for: investment, context: context)
    }
}
