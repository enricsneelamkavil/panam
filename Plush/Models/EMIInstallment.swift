import Foundation
import SwiftData

@Model
final class EMIInstallment {
    var installmentNumber: Int
    var dueDate: Date
    var amount: Double
    var isPaid: Bool
    var paidDate: Date?
    var linkedTransaction: Transaction?
    var parent: CreditCardEMI?

    init(installmentNumber: Int, dueDate: Date, amount: Double, parent: CreditCardEMI? = nil) {
        self.installmentNumber = installmentNumber
        self.dueDate = dueDate
        self.amount = amount
        self.isPaid = false
        self.parent = parent
    }
}
