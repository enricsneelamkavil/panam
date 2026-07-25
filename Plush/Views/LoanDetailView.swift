import SwiftUI
import SwiftData

struct LoanDetailView: View {
    let loan: Loan

    @Environment(\.modelContext) private var modelContext
    @State private var selectedInstallment: LoanInstallment?

    private var sortedInstallments: [LoanInstallment] {
        loan.installments.sorted { $0.installmentNumber < $1.installmentNumber }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("EMI Amount") {
                    Text(loan.emiAmount, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                }
                LabeledContent("Principal") {
                    Text(loan.principalAmount, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                }
                if let rate = loan.interestRate {
                    LabeledContent("Interest Rate", value: "\(rate.formatted(.number.precision(.fractionLength(1...2))))% p.a.")
                }
                if let accountName = loan.account?.name {
                    LabeledContent("Debit Account", value: accountName)
                }
                LabeledContent("Progress", value: "\(loan.paidCount) of \(loan.tenureMonths) paid")
                LabeledContent("Remaining") {
                    MaskableCurrencyText(amount: loan.remainingAmount)
                        .foregroundStyle(loan.paidCount == loan.tenureMonths ? .secondary : .primary)
                }
            }

            Section("Installments") {
                ForEach(sortedInstallments) { installment in
                    Button {
                        selectedInstallment = installment
                    } label: {
                        LoanInstallmentRow(installment: installment)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(loan.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedInstallment) { installment in
            if installment.isPaid {
                PaymentSummaryView(
                    title: "Installment #\(installment.installmentNumber)",
                    dueDate: installment.dueDate,
                    expectedAmount: installment.amount,
                    actualAmount: installment.amount,
                    completedDate: installment.paidDate
                )
                .presentationDetents([.medium])
            } else {
                PaymentConfirmationSheet(
                    title: "Mark as Paid",
                    dueDate: installment.dueDate,
                    expectedAmount: installment.amount
                ) { actual in
                    markInstallmentPaid(installment, actual: actual)
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func loanEMICategory() -> Category? {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == "Loan EMI" }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let category = Category(name: "Loan EMI", icon: "banknote", isPreset: true)
        modelContext.insert(category)
        return category
    }

    private func markInstallmentPaid(_ installment: LoanInstallment, actual: Double) {
        guard let loan = installment.parent else { return }

        installment.isPaid = true
        installment.paidDate = .now

        let note = "\(loan.name) — EMI \(installment.installmentNumber)/\(loan.tenureMonths)"
        let transaction = Transaction(
            amount: actual,
            date: Calendar.current.startOfDay(for: .now),
            note: note,
            type: .expense,
            account: loan.account,
            category: loanEMICategory()
        )
        modelContext.insert(transaction)
        installment.linkedTransaction = transaction
        loan.account?.applyTransaction(amount: actual, type: .expense)
        MoneyEventSync.sync(paidLoanInstallment: installment, context: modelContext)
    }
}

private struct LoanInstallmentRow: View {
    let installment: LoanInstallment

    var body: some View {
        HStack {
            Text("#\(installment.installmentNumber)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(installment.dueDate, format: .dateTime.day().month(.abbreviated).year())
                Text(installment.amount, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if installment.isPaid {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 4) {
                    Text("Due")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

