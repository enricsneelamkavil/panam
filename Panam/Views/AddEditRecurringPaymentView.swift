//
//  AddEditRecurringPaymentView.swift
//  Panam
//

import SwiftUI
import SwiftData

struct AddEditRecurringPaymentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The payment being edited, or nil when creating a new one.
    var payment: RecurringPayment?

    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Person.name) private var people: [Person]

    @State private var name = ""
    @State private var expectedAmount: Double?
    @State private var cadence: Cadence = .monthly
    @State private var startDate: Date = .now
    @State private var selectedCategory: Category?
    @State private var selectedAccount: Account?
    @State private var isSubscription = false
    @State private var isNecessary: Bool?
    @State private var isActive = true
    @State private var autopayEnabled = false
    @State private var hasPerson = false
    @State private var selectedPerson: Person?
    @State private var newPersonName = ""

    private var isEditing: Bool { payment != nil }

    private var canSave: Bool {
        guard let expectedAmount, expectedAmount > 0 else { return false }
        if hasPerson && selectedPerson == nil
            && newPersonName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedCategory != nil
            && selectedAccount != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)

                    TextField("Expected Amount", value: $expectedAmount, format: .number)
                        .keyboardType(.decimalPad)

                    Picker("Cadence", selection: $cadence) {
                        ForEach(Cadence.allCases, id: \.self) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }

                    DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                }

                Section {
                    Picker("Category", selection: $selectedCategory) {
                        Text("Select Category").tag(nil as Category?)
                        ForEach(categories) { category in
                            Label(category.name, systemImage: category.icon)
                                .tag(category as Category?)
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
                    Toggle("Subscription", isOn: $isSubscription)

                    if isSubscription {
                        Picker("Necessary?", selection: $isNecessary) {
                            Text("Yes").tag(true as Bool?)
                            Text("No").tag(false as Bool?)
                            Text("Not set").tag(nil as Bool?)
                        }
                        .pickerStyle(.segmented)
                    }

                    Toggle("Active", isOn: $isActive)

                    Toggle("Autopay", isOn: $autopayEnabled)
                }

                Section {
                    Toggle("Linked to a Person", isOn: $hasPerson.animation())

                    if hasPerson {
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
                } footer: {
                    Text("For payments made to someone, like a chit fund. This is a reference link only — it doesn't create or affect any lending balance.")
                }
            }
            .navigationTitle(isEditing ? "Edit Recurring" : "New Recurring")
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
            .onAppear(perform: populateFromPayment)
        }
    }

    private func populateFromPayment() {
        guard let payment else { return }
        name = payment.name
        expectedAmount = payment.expectedAmount
        cadence = payment.cadence
        startDate = payment.startDate
        selectedCategory = payment.category
        selectedAccount = payment.account
        isSubscription = payment.isSubscription
        isNecessary = payment.isNecessary
        isActive = payment.isActive
        autopayEnabled = payment.autopayEnabled
        if let person = payment.person {
            hasPerson = true
            selectedPerson = person
        }
    }

    /// Resolves the person section's state into a Person, creating and
    /// inserting a new one if the user typed a fresh name. Returns nil when
    /// the payment isn't linked to anyone.
    private func resolvePerson() -> Person? {
        guard hasPerson else { return nil }
        if let selectedPerson { return selectedPerson }
        let trimmedName = newPersonName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return nil }
        let newPerson = Person(name: trimmedName)
        modelContext.insert(newPerson)
        return newPerson
    }

    private func save() {
        guard let expectedAmount, expectedAmount > 0 else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        // Necessary? only applies to subscriptions.
        let necessary = isSubscription ? isNecessary : nil

        if let payment {
            let needsRegeneration = payment.expectedAmount != expectedAmount
                || payment.cadence != cadence
                || payment.startDate != startDate

            payment.name = trimmedName
            payment.expectedAmount = expectedAmount
            payment.cadence = cadence
            payment.startDate = startDate
            payment.category = selectedCategory
            payment.account = selectedAccount
            payment.isSubscription = isSubscription
            payment.isNecessary = necessary
            payment.isActive = isActive
            payment.autopayEnabled = autopayEnabled
            payment.person = resolvePerson()

            if needsRegeneration {
                RecurringOccurrenceGenerator.regenerateFutureUnpaid(for: payment, context: modelContext)
            }
        } else {
            let newPayment = RecurringPayment(
                name: trimmedName,
                expectedAmount: expectedAmount,
                cadence: cadence,
                startDate: startDate,
                category: selectedCategory,
                account: selectedAccount,
                isSubscription: isSubscription,
                isNecessary: necessary,
                isActive: isActive,
                person: resolvePerson()
            )
            newPayment.autopayEnabled = autopayEnabled
            modelContext.insert(newPayment)
            RecurringOccurrenceGenerator.generateOccurrences(for: newPayment, context: modelContext)
        }
        dismiss()
    }
}

#Preview {
    AddEditRecurringPaymentView()
        .modelContainer(
            for: [Account.self, Category.self, Transaction.self,
                  RecurringPayment.self, RecurringOccurrence.self,
                  Person.self, LendingEntry.self],
            inMemory: true
        )
}
