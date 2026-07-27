//
//  EMIDetailView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct EMIDetailView: View {
    let emi: CreditCardEMI

    @Environment(\.modelContext) private var modelContext
    @State private var selectedInstallment: EMIInstallment?

    private static let currencyFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    private var sortedInstallments: [EMIInstallment] {
        emi.installments.sorted { $0.installmentNumber < $1.installmentNumber }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Monthly Amount") {
                    Text(emi.monthlyAmount, format: Self.currencyFormat)
                }
                LabeledContent("Principal") {
                    Text(emi.principalAmount, format: Self.currencyFormat)
                }
                LabeledContent("Progress", value: "\(emi.paidCount) of \(emi.tenureMonths) paid")
                LabeledContent("Remaining") {
                    Text(emi.remainingAmount, format: Self.currencyFormat)
                }
            }

            Section("Installments") {
                ForEach(sortedInstallments) { installment in
                    Button {
                        selectedInstallment = installment
                    } label: {
                        InstallmentRow(installment: installment)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(emi.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedInstallment) { installment in
            if installment.isPaid {
                PaymentSummaryView(
                    title: "Installment #\(installment.installmentNumber)",
                    dueDate: installment.dueDate,
                    expectedAmount: installment.amount,
                    actualAmount: installment.amount,
                    completedDate: installment.paidDate,
                    onMarkUnpaid: { markUnpaid(installment) }
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

    private func creditCardBillCategory() -> Category? {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == "Credit Card Bill" }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func markInstallmentPaid(_ installment: EMIInstallment, actual: Double) {
        guard let emi = installment.parent else { return }

        installment.isPaid = true
        installment.paidDate = .now

        let transaction = Transaction(
            amount: actual,
            date: Calendar.current.startOfDay(for: .now),
            note: "\(emi.name) — EMI \(installment.installmentNumber)/\(emi.tenureMonths)",
            type: .expense,
            account: emi.account,
            category: creditCardBillCategory()
        )
        modelContext.insert(transaction)
        installment.linkedTransaction = transaction
        emi.account?.applyTransaction(amount: actual, type: .expense)
        MoneyEventSync.sync(paidEMIInstallment: installment, context: modelContext)
    }

    private func markUnpaid(_ installment: EMIInstallment) {
        if let transaction = installment.linkedTransaction {
            transaction.account?.reverseTransaction(amount: transaction.amount, type: transaction.type)
            modelContext.delete(transaction)
            installment.linkedTransaction = nil
        }
        installment.isPaid = false
        installment.paidDate = nil
    }
}

private struct InstallmentRow: View {
    let installment: EMIInstallment

    var body: some View {
        HStack {
            Text("#\(installment.installmentNumber)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(installment.dueDate, format: .dateTime.day().month(.abbreviated).year())
                Text(installment.amount,
                     format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
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

#Preview {
    NavigationStack {
        EMIDetailView(
            emi: CreditCardEMI(name: "Preview Phone", principalAmount: 120_000,
                               monthlyAmount: 10_000, tenureMonths: 12)
        )
    }
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              CreditCardEMI.self, EMIInstallment.self],
        inMemory: true
    )
}
