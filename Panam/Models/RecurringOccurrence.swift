import Foundation
import SwiftData

@Model
final class RecurringOccurrence {
    /// See Account.backupID.
    var backupID: UUID = UUID()
    var dueDate: Date
    var expectedAmount: Double   // snapshot from template at generation time
    var actualAmount: Double?    // set when marked paid; nil = not yet paid
    var isPaid: Bool
    var paidDate: Date?
    var linkedTransaction: Transaction?   // the Transaction created when marked paid
    var parent: RecurringPayment?

    init(dueDate: Date, expectedAmount: Double, parent: RecurringPayment? = nil) {
        self.dueDate = dueDate
        self.expectedAmount = expectedAmount
        self.isPaid = false
        self.parent = parent
    }
}
