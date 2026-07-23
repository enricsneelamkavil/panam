import Foundation
import SwiftData

@Model
final class CreditCardEMI {
    var name: String              // e.g. "iPhone 16 Pro Max"
    var account: Account?         // the credit card this EMI is on
    var principalAmount: Double   // original purchase/loan amount, informational
    var monthlyAmount: Double
    var tenureMonths: Int
    var startDate: Date
    var isActive: Bool

    @Relationship(deleteRule: .cascade, inverse: \EMIInstallment.parent)
    var installments: [EMIInstallment] = []

    init(name: String, account: Account? = nil, principalAmount: Double, monthlyAmount: Double,
         tenureMonths: Int, startDate: Date = .now, isActive: Bool = true) {
        self.name = name
        self.account = account
        self.principalAmount = principalAmount
        self.monthlyAmount = monthlyAmount
        self.tenureMonths = tenureMonths
        self.startDate = startDate
        self.isActive = isActive
    }
}

extension CreditCardEMI {
    var paidCount: Int {
        installments.filter(\.isPaid).count
    }

    var remainingAmount: Double {
        Double(tenureMonths - paidCount) * monthlyAmount
    }
}
