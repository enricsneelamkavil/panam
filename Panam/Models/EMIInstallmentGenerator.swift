import Foundation
import SwiftData

enum EMIInstallmentGenerator {
    /// Creates all `tenureMonths` installments upfront, due monthly from the
    /// start date. Called once at EMI creation — tenure is fixed and fully
    /// known, so there is no rolling regeneration.
    static func generateInstallments(for emi: CreditCardEMI, context: ModelContext) {
        guard emi.tenureMonths >= 1 else { return }

        let calendar = Calendar.current
        for number in 1...emi.tenureMonths {
            guard let dueDate = calendar.date(byAdding: .month, value: number - 1, to: emi.startDate)
            else { continue }
            let installment = EMIInstallment(
                installmentNumber: number,
                dueDate: dueDate,
                amount: emi.monthlyAmount,
                parent: emi
            )
            context.insert(installment)
        }
    }
}
