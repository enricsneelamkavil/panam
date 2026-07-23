//
//  AddLendingEntryView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct AddLendingEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the entry is for this person and the picker is hidden.
    var person: Person?

    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var kind: LendingKind = .lent
    @State private var amount: Double?
    @State private var selectedPerson: Person?
    @State private var newPersonName = ""
    @State private var selectedAccount: Account?
    @State private var date: Date = .now
    @State private var note = ""

    private var canSave: Bool {
        guard let amount, amount > 0, selectedAccount != nil else { return false }
        if person != nil || selectedPerson != nil { return true }
        return !newPersonName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(LendingKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }

                    TextField("Amount", value: $amount, format: .number)
                        .keyboardType(.decimalPad)
                }

                Section {
                    if let person {
                        LabeledContent("Person", value: person.name)
                    } else {
                        Picker("Person", selection: $selectedPerson) {
                            Text("New Person").tag(nil as Person?)
                            ForEach(people) { person in
                                Text(person.name).tag(person as Person?)
                            }
                        }

                        if selectedPerson == nil {
                            TextField("Name", text: $newPersonName)
                        }
                    }

                    Picker("Account", selection: $selectedAccount) {
                        Text("Select Account").tag(nil as Account?)
                        ForEach(accounts) { account in
                            Text(account.name).tag(account as Account?)
                        }
                    }
                }

                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)

                    TextField("Note (optional)", text: $note)
                }
            }
            .navigationTitle("New Lending Entry")
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
        }
    }

    /// The preset category used for all lending money movements.
    private func lentMoneyCategory() -> Category? {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == "Lent Money" }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func save() {
        guard let amount, amount > 0, let selectedAccount else { return }

        let entryPerson: Person
        if let person {
            entryPerson = person
        } else if let selectedPerson {
            entryPerson = selectedPerson
        } else {
            let trimmedName = newPersonName.trimmingCharacters(in: .whitespaces)
            guard !trimmedName.isEmpty else { return }
            let newPerson = Person(name: trimmedName)
            modelContext.insert(newPerson)
            entryPerson = newPerson
        }

        let entry = LendingEntry(amount: amount, date: date, note: note,
                                 kind: kind, person: entryPerson)
        modelContext.insert(entry)

        // Record the actual money movement against the account.
        let transactionNote = "\(kind.displayName) – \(entryPerson.name)"
        let transaction = Transaction(
            amount: amount,
            date: date,
            note: note.isEmpty ? transactionNote : "\(transactionNote): \(note)",
            type: kind.transactionType,
            account: selectedAccount,
            category: lentMoneyCategory()
        )
        modelContext.insert(transaction)
        entry.linkedTransaction = transaction
        selectedAccount.applyTransaction(amount: amount, type: kind.transactionType)

        dismiss()
    }
}

#Preview {
    AddLendingEntryView()
        .modelContainer(
            for: [Account.self, Category.self, Transaction.self,
                  RecurringPayment.self, RecurringOccurrence.self,
                  Person.self, LendingEntry.self],
            inMemory: true
        )
}
