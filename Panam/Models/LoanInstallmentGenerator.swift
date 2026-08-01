import Foundation
import SwiftData

enum LoanInstallmentGenerator {
    /// Creates all `tenureMonths` installments upfront, due monthly from the
    /// start date. Called once at loan creation — tenure is fixed and fully
    /// known, so there is no rolling regeneration.
    static func generateInstallments(for loan: Loan, context: ModelContext) {
        guard loan.tenureMonths >= 1 else { return }

        let calendar = Calendar.current
        for number in 1...loan.tenureMonths {
            guard let dueDate = calendar.date(byAdding: .month, value: number - 1, to: loan.startDate)
            else { continue }
            let installment = LoanInstallment(
                installmentNumber: number,
                dueDate: dueDate,
                amount: loan.emiAmount,
                parent: loan
            )
            context.insert(installment)
        }
    }
}
