import Foundation
import SwiftData

@Model
final class LoanInstallment {
    /// See Account.backupID.
    var backupID: UUID = UUID()
    var installmentNumber: Int
    var dueDate: Date
    var amount: Double
    var isPaid: Bool
    var paidDate: Date?
    var linkedTransaction: Transaction?
    var parent: Loan?

    init(installmentNumber: Int, dueDate: Date, amount: Double, parent: Loan? = nil) {
        self.installmentNumber = installmentNumber
        self.dueDate = dueDate
        self.amount = amount
        self.isPaid = false
        self.parent = parent
    }
}
