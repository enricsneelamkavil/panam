//
//  AddEditAccountView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct AddEditAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The account being edited, or nil when creating a new one.
    var account: Account?

    @State private var name = ""
    @State private var type: AccountType = .bank
    @State private var balance: Double?
    @State private var creditLimit: Double?
    @State private var statementDay: Int?
    @State private var dueDay: Int?

    private var isEditing: Bool { account != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && balance != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)

                    Picker("Type", selection: $type) {
                        Text("Bank").tag(AccountType.bank)
                        Text("Cash").tag(AccountType.cash)
                        Text("Credit Card").tag(AccountType.creditCard)
                    }
                    .pickerStyle(.segmented)

                    TextField(
                        type == .creditCard ? "Current Outstanding" : "Balance",
                        value: $balance,
                        format: .number
                    )
                    .keyboardType(.decimalPad)
                }

                if type == .creditCard {
                    Section("Credit Card Details") {
                        TextField("Credit Limit", value: $creditLimit, format: .number)
                            .keyboardType(.decimalPad)

                        TextField("Statement Day (1–31)", value: $statementDay, format: .number)
                            .keyboardType(.numberPad)

                        TextField("Due Day (1–31)", value: $dueDay, format: .number)
                            .keyboardType(.numberPad)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Account" : "New Account")
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
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: populateFromAccount)
        }
    }

    private func populateFromAccount() {
        guard let account else { return }
        name = account.name
        type = account.type
        balance = account.balance
        creditLimit = account.creditLimit
        statementDay = account.statementDay
        dueDay = account.dueDay
    }

    private func save() {
        guard let balance else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        // Clamp credit card day fields to 1–31; drop them for non-credit-card types.
        let clampedStatementDay = type == .creditCard ? statementDay.map { min(max($0, 1), 31) } : nil
        let clampedDueDay = type == .creditCard ? dueDay.map { min(max($0, 1), 31) } : nil
        let limit = type == .creditCard ? creditLimit : nil

        if let account {
            account.name = trimmedName
            account.type = type
            account.balance = balance
            account.creditLimit = limit
            account.statementDay = clampedStatementDay
            account.dueDay = clampedDueDay
        } else {
            let newAccount = Account(
                name: trimmedName,
                type: type,
                balance: balance,
                creditLimit: limit,
                statementDay: clampedStatementDay,
                dueDay: clampedDueDay
            )
            modelContext.insert(newAccount)
        }
        dismiss()
    }
}

#Preview {
    AddEditAccountView()
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
