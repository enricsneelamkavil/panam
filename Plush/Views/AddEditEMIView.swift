//
//  AddEditEMIView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct AddEditEMIView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The credit card this EMI belongs to — fixed, not user-selectable.
    let account: Account

    @State private var name = ""
    @State private var principalAmount: Double?
    @State private var monthlyAmount: Double?
    @State private var tenureMonths: Int?
    @State private var startDate: Date = .now

    private var canSave: Bool {
        guard let principalAmount, principalAmount > 0,
              let monthlyAmount, monthlyAmount > 0,
              let tenureMonths, tenureMonths >= 1
        else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Card", value: account.name)

                    TextField("Name (e.g. iPhone 16 Pro Max)", text: $name)
                }

                Section {
                    TextField("Principal Amount", value: $principalAmount, format: .number)
                        .keyboardType(.decimalPad)

                    TextField("Monthly Amount", value: $monthlyAmount, format: .number)
                        .keyboardType(.decimalPad)

                    TextField("Tenure (months)", value: $tenureMonths, format: .number)
                        .keyboardType(.numberPad)

                    DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                }
            }
            .navigationTitle("New EMI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                    .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard let principalAmount, principalAmount > 0,
              let monthlyAmount, monthlyAmount > 0,
              let tenureMonths, tenureMonths >= 1
        else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let emi = CreditCardEMI(
            name: trimmedName,
            account: account,
            principalAmount: principalAmount,
            monthlyAmount: monthlyAmount,
            tenureMonths: tenureMonths,
            startDate: startDate
        )
        modelContext.insert(emi)
        EMIInstallmentGenerator.generateInstallments(for: emi, context: modelContext)
        dismiss()
    }
}

#Preview {
    AddEditEMIView(
        account: Account(name: "Preview Card", type: .creditCard, creditLimit: 100_000)
    )
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              CreditCardEMI.self, EMIInstallment.self],
        inMemory: true
    )
}
