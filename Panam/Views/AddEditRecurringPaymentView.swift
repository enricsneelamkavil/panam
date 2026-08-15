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
    @State private var showingResumeSheet = false

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
                    // A Toggle labeled "Subscription" never made clear what
                    // being *off* meant — a menu Picker reads as picking a
                    // category (what this payment is), not flipping a
                    // switch. isSubscription itself is unchanged, still a
                    // plain Bool; this only changes how it's presented.
                    Picker("Type", selection: $isSubscription) {
                        Text("Regular Bill").tag(false)
                        Text("Subscription").tag(true)
                    }

                    if isSubscription {
                        Picker("Necessary?", selection: $isNecessary) {
                            Text("Yes").tag(true as Bool?)
                            Text("No").tag(false as Bool?)
                            Text("Not set").tag(nil as Bool?)
                        }
                        .pickerStyle(.segmented)
                    }

                    // isActive itself stays true while paused (see
                    // RecurringPayment.isPaused's doc comment) — Active
                    // here is shown off and locked instead of just binding
                    // straight to isActive, since flipping a plain toggle
                    // isn't how a paused payment should come back; Resume
                    // Subscription below is the explicit, confirmed path
                    // for that.
                    if payment?.isPaused == true {
                        Toggle("Active", isOn: .constant(false))
                            .disabled(true)

                        if let pausedDate = payment?.pausedDate {
                            Text("Paused since \(pausedDate.formatted(date: .abbreviated, time: .omitted)). Resume to pick it back up.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("This payment is paused. Resume to pick it back up.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            showingResumeSheet = true
                        } label: {
                            Label("Resume Subscription", systemImage: "play.circle")
                        }
                        .tint(.green)
                    } else {
                        Toggle("Active", isOn: $isActive)
                    }

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
            .sheet(isPresented: $showingResumeSheet) {
                ResumeSubscriptionSheet { restartDate in
                    resume(restartDate: restartDate)
                }
                .presentationDetents([.medium])
            }
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

    /// Confirmed resume action, replacing the old bare toggle-flip: clears
    /// the paused state, moves the payment's effective start point forward
    /// to the chosen restart date (generateOccurrences always walks forward
    /// from `startDate`, so this is what makes it the actual anchor for
    /// what gets scheduled next), and generates from there. Mutates
    /// `payment` directly — same as SubscriptionsView's restartSubscription
    /// — so the resume takes effect immediately without waiting on Save;
    /// the local @State mirrors are updated too so the rest of this form
    /// reflects it right away.
    private func resume(restartDate: Date) {
        guard let payment else { return }
        payment.isPaused = false
        payment.pausedDate = nil
        payment.startDate = restartDate
        RecurringOccurrenceGenerator.generateOccurrences(for: payment, context: modelContext)

        startDate = restartDate
        isActive = payment.isActive
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

/// Confirmation for resuming a paused payment — same "explicit, confirmed
/// action, not a bare toggle" shape as PaymentConfirmationSheet's Mark as
/// Paid flow, with a restart-date DatePicker in place of an amount field.
/// A DatePicker doesn't render reliably inside a plain SwiftUI .alert, so
/// this reuses the sheet-based confirmation pattern already established
/// elsewhere in the app instead.
private struct ResumeSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onConfirm: (Date) -> Void

    @State private var restartDate: Date = .now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Restart Date", selection: $restartDate, displayedComponents: .date)
                } footer: {
                    Text("Resuming clears the paused state and schedules new occurrences starting from this date.")
                }

                Button {
                    onConfirm(restartDate)
                    dismiss()
                } label: {
                    Text("Resume Subscription")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationTitle("Resume Subscription")
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
