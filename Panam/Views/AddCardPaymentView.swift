//
//  AddCardPaymentView.swift
//  Panam
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
    @Query(sort: \Category.name) private var categories: [Category]

    @State private var amount: Double?
    @State private var feeAmount: Double?
    @State private var extraUnloggedAmount: Double?
    @State private var extraAmountCategory: Category?
    @State private var sourceAccount: Account?
    @State private var date: Date = .now
    @State private var note = ""

    private var sourceCandidates: [Account] {
        accounts.filter { $0 !== card }
    }

    private var canSave: Bool {
        guard let amount, amount > 0 else { return false }
        if type == .billPayment, let extraUnloggedAmount, extraUnloggedAmount >= amount {
            return false
        }
        return true
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

                    if type == .billPayment {
                        TextField("Extra Amount Not Already Logged", value: $extraUnloggedAmount, format: .number)
                            .keyboardType(.decimalPad)

                        if let extraUnloggedAmount, extraUnloggedAmount > 0 {
                            Picker("Category", selection: $extraAmountCategory) {
                                Text("Uncategorized").tag(nil as Category?)
                                ForEach(categories) { category in
                                    Label(category.name, systemImage: category.icon)
                                        .tag(category as Category?)
                                }
                            }
                        }
                    }
                } footer: {
                    if type == .billPayment {
                        Text("If you're paying more than what's already tracked as purchases on this card — interest, fees, or a purchase you didn't log separately — enter that extra amount here. It'll count as new spend; the rest just settles what's already been counted.")
                    }
                }

                Section {
                    Picker("Pay From", selection: $sourceAccount) {
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
            extraUnloggedAmount: type == .billPayment ? (extraUnloggedAmount ?? 0) : 0,
            extraAmountCategory: type == .billPayment ? extraAmountCategory : nil,
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
