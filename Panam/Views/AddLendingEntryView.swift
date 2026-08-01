//
//  AddLendingEntryView.swift
//  Panam
//

import SwiftUI
import SwiftData

struct AddLendingEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the entry is for this person and the picker is hidden.
    var person: Person?

    /// The entry being edited, or nil when creating a new one.
    var entry: LendingEntry?

    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var kind: LendingKind = .lent
    @State private var amount: Double?
    @State private var selectedPerson: Person?
    @State private var newPersonName = ""
    @State private var selectedAccount: Account?
    @State private var date: Date = .now
    @State private var note = ""

    private var isEditing: Bool { entry != nil }

    /// True for entries auto-created from a split transaction — these have no
    /// account/type of their own (the money already moved via the parent
    /// transaction), so only amount/date/note are editable for them.
    private var isSplitDerived: Bool { entry?.sourceTransaction != nil }

    private var canSave: Bool {
        guard let amount, amount > 0 else { return false }
        if !isSplitDerived && selectedAccount == nil { return false }
        if person != nil || selectedPerson != nil { return true }
        return !newPersonName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isSplitDerived {
                        LabeledContent("Type", value: kind.displayName)
                    } else {
                        Picker("Type", selection: $kind) {
                            ForEach(LendingKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
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

                    if !isSplitDerived {
                        Picker("Account", selection: $selectedAccount) {
                            Text("Select Account").tag(nil as Account?)
                            ForEach(accounts) { account in
                                Text(account.name).tag(account as Account?)
                            }
                        }
                    }
                }

                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)

                    TextField("Note (optional)", text: $note)
                }
            }
            .navigationTitle(isEditing ? "Edit Lending Entry" : "New Lending Entry")
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
            .onAppear(perform: populateFromEntry)
        }
    }

    private func populateFromEntry() {
        guard let entry else { return }
        kind = entry.kind
        amount = entry.amount
        date = entry.date
        note = entry.note
        selectedAccount = entry.linkedTransaction?.account
    }

    /// The preset category used for all lending money movements.
    private func lentMoneyCategory() -> Category? {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == "Lent Money" }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func save() {
        guard let amount, amount > 0 else { return }
        if !isSplitDerived {
            guard selectedAccount != nil else { return }
        }

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

        if let entry {
            entry.amount = amount
            entry.date = date
            entry.note = note

            if !isSplitDerived {
                entry.kind = kind

                if let oldTransaction = entry.linkedTransaction {
                    oldTransaction.account?.reverseTransaction(amount: oldTransaction.amount, type: oldTransaction.type)
                    modelContext.delete(oldTransaction)
                    entry.linkedTransaction = nil
                }

                guard let selectedAccount else { return }
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
                MoneyEventSync.sync(lendingEntry: entry, context: modelContext)
            }

            dismiss()
            return
        }

        let newEntry = LendingEntry(amount: amount, date: date, note: note,
                                    kind: kind, person: entryPerson)
        modelContext.insert(newEntry)

        // Record the actual money movement against the account.
        guard let selectedAccount else { return }
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
        newEntry.linkedTransaction = transaction
        selectedAccount.applyTransaction(amount: amount, type: kind.transactionType)
        MoneyEventSync.sync(lendingEntry: newEntry, context: modelContext)

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
