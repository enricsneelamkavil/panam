//
//  EMIDetailView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct EMIDetailView: View {
    let emi: CreditCardEMI

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
                PaidInstallmentSummaryView(installment: installment)
                    .presentationDetents([.medium])
            } else {
                MarkInstallmentPaidView(installment: installment)
                    .presentationDetents([.medium])
            }
        }
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

/// Confirmation sheet for paying an installment: creates the linked card
/// transaction and adds the amount to the card's outstanding balance.
private struct MarkInstallmentPaidView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let installment: EMIInstallment

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Due Date") {
                        Text(installment.dueDate, format: .dateTime.day().month(.abbreviated).year())
                    }
                    LabeledContent("Amount") {
                        Text(installment.amount,
                             format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                    }
                }

                Section {
                    Button("Mark Installment \(installment.installmentNumber) as Paid") {
                        markPaid()
                    }
                }
            }
            .navigationTitle("Mark as Paid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    /// The preset category for credit card bill payments.
    private func creditCardBillCategory() -> Category? {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == "Credit Card Bill" }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func markPaid() {
        guard let emi = installment.parent else { return }

        installment.isPaid = true
        installment.paidDate = .now

        let transaction = Transaction(
            amount: installment.amount,
            date: .now,
            note: "\(emi.name) — EMI \(installment.installmentNumber)/\(emi.tenureMonths)",
            type: .expense,
            account: emi.account,
            category: creditCardBillCategory()
        )
        modelContext.insert(transaction)
        installment.linkedTransaction = transaction
        emi.account?.applyTransaction(amount: installment.amount, type: .expense)

        dismiss()
    }
}

/// Read-only summary for an installment that has already been paid.
private struct PaidInstallmentSummaryView: View {
    @Environment(\.dismiss) private var dismiss

    let installment: EMIInstallment

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Installment", value: "#\(installment.installmentNumber)")
                LabeledContent("Due Date") {
                    Text(installment.dueDate, format: .dateTime.day().month(.abbreviated).year())
                }
                LabeledContent("Amount") {
                    Text(installment.amount,
                         format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                }
                if let paidDate = installment.paidDate {
                    LabeledContent("Paid On") {
                        Text(paidDate, format: .dateTime.day().month(.abbreviated).year())
                    }
                }
            }
            .navigationTitle("Installment Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
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
