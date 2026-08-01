import Foundation
import SwiftData

enum RecurringOccurrenceGenerator {
    /// Creates any missing occurrences for the payment, from its start date up to
    /// `monthsAhead` months from today. Existing occurrences (paid or unpaid) are
    /// never touched — only missing due dates get new records.
    static func generateOccurrences(for payment: RecurringPayment,
                                    monthsAhead: Int = 12,
                                    context: ModelContext) {
        guard payment.isActive else { return }

        let calendar = Calendar.current
        guard let horizon = calendar.date(byAdding: .month, value: monthsAhead, to: .now)
        else { return }

        // Compare by start-of-day so time-of-day differences don't cause duplicates.
        let existingDueDays = Set(payment.occurrences.map { calendar.startOfDay(for: $0.dueDate) })

        var dueDate = payment.startDate
        while dueDate <= horizon {
            if !existingDueDays.contains(calendar.startOfDay(for: dueDate)) {
                let occurrence = RecurringOccurrence(
                    dueDate: dueDate,
                    expectedAmount: payment.expectedAmount,
                    parent: payment
                )
                context.insert(occurrence)
            }
            guard let next = calendar.date(byAdding: payment.cadence.step, to: dueDate),
                  next > dueDate
            else { break }
            dueDate = next
        }
    }

    /// Deletes all unpaid future occurrences and regenerates them from the template's
    /// current amount/cadence. Call after editing a template so future projections
    /// reflect the change while past/paid occurrences stay untouched.
    static func regenerateFutureUnpaid(for payment: RecurringPayment, context: ModelContext) {
        let now = Date.now
        for occurrence in payment.occurrences where !occurrence.isPaid && occurrence.dueDate > now {
            context.delete(occurrence)
        }
        generateOccurrences(for: payment, context: context)
    }
}

extension Cadence {
    /// Calendar step between consecutive occurrences.
    var step: DateComponents {
        switch self {
        case .daily: DateComponents(day: 1)
        case .monthly: DateComponents(month: 1)
        case .quarterly: DateComponents(month: 3)
        case .halfYearly: DateComponents(month: 6)
        case .yearly: DateComponents(month: 12)
        }
    }
}
