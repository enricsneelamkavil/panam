import Foundation
import SwiftData

@Model
final class Loan {
    var name: String              // e.g. "Personal Loan - HDFC", "Car Loan"
    var principalAmount: Double
    var interestRate: Double?     // annual %, optional/informational
    var emiAmount: Double
    var tenureMonths: Int
    var startDate: Date
    var account: Account?         // where EMIs get paid from
    var isActive: Bool

    @Relationship(deleteRule: .cascade, inverse: \LoanInstallment.parent)
    var installments: [LoanInstallment] = []

    init(name: String, principalAmount: Double, interestRate: Double? = nil, emiAmount: Double,
         tenureMonths: Int, startDate: Date = .now, account: Account? = nil, isActive: Bool = true) {
        self.name = name
        self.principalAmount = principalAmount
        self.interestRate = interestRate
        self.emiAmount = emiAmount
        self.tenureMonths = tenureMonths
        self.startDate = startDate
        self.account = account
        self.isActive = isActive
    }
}

extension Loan {
    var paidCount: Int {
        installments.filter(\.isPaid).count
    }

    var remainingAmount: Double {
        Double(tenureMonths - paidCount) * emiAmount
    }
}
