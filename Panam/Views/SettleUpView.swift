//
//  SettleUpView.swift
//  Panam
//

import SwiftUI
import SwiftData

struct SettleUpView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let person: Person

    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var amount: Double?
    @State private var selectedAccount: Account?
    @State private var date: Date = .now
    @State private var note = ""

    private var isTheyOweYou: Bool { person.netBalance > 0 }
    private var outstandingAmount: Double { abs(person.netBalance) }

    // .repaymentReceived cancels a "lent" balance; .repaymentMade cancels a "borrowed" one.
    private var settlementKind: LendingKind {
        isTheyOweYou ? .repaymentReceived : .repaymentMade
    }

    private var canConfirm: Bool {
        guard let amount, amount > 0 else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 4) {
                        Text(isTheyOweYou ? "They owe you" : "You owe them")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        MaskableCurrencyText(amount: outstandingAmount)
                            .font(.title.bold().monospacedDigit())
                            .foregroundStyle(isTheyOweYou ? .green : .red)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                Section("Settlement Amount") {
                    TextField("Amount", value: $amount, format: .number)
                        .keyboardType(.decimalPad)
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
            .navigationTitle("Settle Up — \(person.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(.appPrimary)
                        .disabled(!canConfirm)
                }
            }
            .onAppear {
                // Pre-fill with the full outstanding so the user only needs
                // to edit for a partial settlement.
                amount = outstandingAmount
            }
        }
    }

    private func lentMoneyCategory() -> Category? {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == "Lent Money" }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func save() {
        guard let amount, amount > 0 else { return }

        let entry = LendingEntry(
            amount: amount,
            date: date,
            note: note,
            kind: settlementKind,
            person: person
        )
        modelContext.insert(entry)
        MoneyEventSync.sync(lendingEntry: entry, context: modelContext)

        if let selectedAccount {
            let directionNote = isTheyOweYou
                ? "Repayment from \(person.name)"
                : "Repayment to \(person.name)"
            let transaction = Transaction(
                amount: amount,
                date: Calendar.current.startOfDay(for: date),
                note: note.isEmpty ? directionNote : "\(directionNote): \(note)",
                type: settlementKind.transactionType,
                account: selectedAccount,
                category: lentMoneyCategory()
            )
            // A settlement (.repaymentReceived/.repaymentMade) cancels a debt —
            // it's not real income/spend, so it's excluded from flow totals.
            transaction.isLendingRepayment = true
            // No payment method for a settlement — it's not shown on repayment rows.
            transaction.paymentMethod = nil
            modelContext.insert(transaction)
            entry.linkedTransaction = transaction
            selectedAccount.applyTransaction(amount: amount, type: settlementKind.transactionType)
        }

        dismiss()
    }
}

#Preview {
    let person = Person(name: "Preview Friend")
    return SettleUpView(person: person)
        .modelContainer(
            for: [Account.self, Category.self, Transaction.self,
                  Person.self, LendingEntry.self],
            inMemory: true
        )
}
