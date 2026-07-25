//
//  AddEditInvestmentView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct AddEditInvestmentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The investment being edited, or nil when creating a new one.
    var investment: Investment?

    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var instrumentType: InstrumentType = .mutualFund
    @State private var name = ""
    @State private var amount: Double?
    @State private var date: Date = .now
    @State private var note = ""
    @State private var selectedAccount: Account?

    @State private var isRecurring = true
    @State private var cadence: Cadence = .monthly
    @State private var autopayEnabled = false
    @State private var priorAmount: Double = 0

    private var isEditing: Bool { investment != nil }

    private var canSave: Bool {
        guard let amount, amount > 0 else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Instrument", selection: $instrumentType) {
                        ForEach(InstrumentType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    TextField("Name", text: $name)

                    TextField("Amount", value: $amount, format: .number)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Toggle("Recurring (SIP)", isOn: $isRecurring)
                        .disabled(isEditing)

                    if isRecurring {
                        Picker("Cadence", selection: $cadence) {
                            ForEach(Cadence.allCases, id: \.self) { cadence in
                                Text(cadence.displayName).tag(cadence)
                            }
                        }

                        Toggle("Autopay", isOn: $autopayEnabled)

                        if !isEditing {
                            TextField("Already Invested (before this)", value: $priorAmount, format: .number)
                                .keyboardType(.decimalPad)
                        }
                    }
                } footer: {
                    if isEditing {
                        Text("Recurring can't be toggled after creation.")
                    }
                }

                Section {
                    Picker("Account", selection: $selectedAccount) {
                        Text("None").tag(nil as Account?)
                        ForEach(accounts) { account in
                            Text(account.name).tag(account as Account?)
                        }
                    }

                    DatePicker("Date", selection: $date, displayedComponents: .date)

                    TextField("Note (optional)", text: $note)
                }
            }
            .navigationTitle(isEditing ? "Edit Investment" : "New Investment")
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
            .onAppear(perform: populateFromInvestment)
        }
    }

    private func populateFromInvestment() {
        guard let investment else { return }
        instrumentType = investment.instrumentType
        name = investment.name
        amount = investment.amount
        date = investment.date
        note = investment.note
        selectedAccount = investment.account
        isRecurring = investment.isRecurring
        cadence = investment.cadence ?? .monthly
        autopayEnabled = investment.autopayEnabled
    }

    /// The preset category used for investment money movements.
    private func investmentCategory() -> Category? {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == "Investment" }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func save() {
        guard let amount, amount > 0 else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let investment {
            let wasRecurring = investment.isRecurring
            let originalAmount = investment.amount
            let originalCadence = investment.cadence

            if !wasRecurring, let old = investment.linkedTransaction {
                // Simplest safe approach: reverse and drop the old linked
                // transaction, then create a fresh one below if needed.
                old.account?.reverseTransaction(amount: old.amount, type: old.type)
                modelContext.delete(old)
                investment.linkedTransaction = nil
            }

            investment.instrumentType = instrumentType
            investment.name = trimmedName
            investment.amount = amount
            investment.date = date
            investment.note = note
            investment.account = selectedAccount

            if wasRecurring {
                investment.autopayEnabled = autopayEnabled
                investment.cadence = cadence

                if amount != originalAmount || cadence != originalCadence {
                    InvestmentOccurrenceGenerator.regenerateFutureUncontributed(for: investment, context: modelContext)
                }
            } else {
                linkTransactionIfNeeded(to: investment, amount: amount, name: trimmedName)
            }
        } else {
            let newInvestment = Investment(
                instrumentType: instrumentType,
                name: trimmedName,
                amount: amount,
                date: date,
                note: note,
                account: selectedAccount,
                isRecurring: isRecurring,
                cadence: isRecurring ? cadence : nil,
                isActive: true,
                autopayEnabled: isRecurring ? autopayEnabled : false,
                priorAmount: isRecurring ? priorAmount : 0
            )
            modelContext.insert(newInvestment)

            if isRecurring {
                InvestmentOccurrenceGenerator.generateOccurrences(for: newInvestment, context: modelContext)
            } else {
                linkTransactionIfNeeded(to: newInvestment, amount: amount, name: trimmedName)
            }
        }
        dismiss()
    }

    private func linkTransactionIfNeeded(to investment: Investment, amount: Double, name: String) {
        guard let selectedAccount else { return }
        let transaction = Transaction(
            amount: amount,
            date: date,
            note: name,
            type: .expense,
            account: selectedAccount,
            category: investmentCategory()
        )
        modelContext.insert(transaction)
        investment.linkedTransaction = transaction
        selectedAccount.applyTransaction(amount: amount, type: .expense)
    }
}

#Preview {
    AddEditInvestmentView()
        .modelContainer(
            for: [Account.self, Category.self, Transaction.self,
                  RecurringPayment.self, RecurringOccurrence.self,
                  Person.self, LendingEntry.self, Investment.self, InvestmentOccurrence.self],
            inMemory: true
        )
}
