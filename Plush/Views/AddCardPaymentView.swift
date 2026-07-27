//
//  AddCardPaymentView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct AddCardPaymentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Pre-set from the menu choice; not editable here.
    let type: CardPaymentType
    /// The credit card this payment applies to.
    let card: Account

    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var amount: Double?
    @State private var feeAmount: Double?
    @State private var sourceAccount: Account?
    @State private var date: Date = .now
    @State private var note = ""

    private var sourceCandidates: [Account] {
        accounts.filter { $0 !== card }
    }

    private var canSave: Bool {
        guard let amount else { return false }
        return amount > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Type", value: type.rawValue)
                    LabeledContent("Card", value: card.name)
                }

                Section {
                    TextField("Amount", value: $amount, format: .number)
                        .keyboardType(.decimalPad)

                    if type == .cashAdvance {
                        TextField("Fee (optional)", value: $feeAmount, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section {
                    Picker(type == .billPayment ? "Pay From" : "Cash Lands In",
                           selection: $sourceAccount) {
                        Text("None").tag(nil as Account?)
                        ForEach(sourceCandidates) { account in
                            Text(account.name).tag(account as Account?)
                        }
                    }

                    DatePicker("Date", selection: $date, displayedComponents: .date)

                    TextField("Note (optional)", text: $note)
                }
            }
            .navigationTitle(type.rawValue)
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
        guard let amount, amount > 0 else { return }

        let payment = CardPayment(
            type: type,
            amount: amount,
            feeAmount: type == .cashAdvance ? feeAmount : nil,
            date: date,
            note: note,
            card: card,
            sourceAccount: sourceAccount
        )
        modelContext.insert(payment)
        payment.record(context: modelContext)
        dismiss()
    }
}

#Preview {
    AddCardPaymentView(
        type: .billPayment,
        card: Account(name: "Preview Card", type: .creditCard, balance: 12_500,
                      creditLimit: 100_000)
    )
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self, CardPayment.self],
        inMemory: true
    )
}
