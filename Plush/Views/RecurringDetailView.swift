//
//  RecurringDetailView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct RecurringDetailView: View {
    let payment: RecurringPayment

    @State private var showingEditSheet = false
    @State private var selectedOccurrence: RecurringOccurrence?

    private static let currencyFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    private var sortedOccurrences: [RecurringOccurrence] {
        payment.occurrences.sorted { $0.dueDate < $1.dueDate }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Cadence", value: payment.cadence.displayName)
                LabeledContent("Expected Amount") {
                    Text(payment.expectedAmount, format: Self.currencyFormat)
                }
                if let category = payment.category {
                    LabeledContent("Category") {
                        Label(category.name, systemImage: category.icon)
                    }
                }
                if let account = payment.account {
                    LabeledContent("Account", value: account.name)
                }
                if payment.isSubscription {
                    LabeledContent("Subscription") {
                        Text(subscriptionLabel)
                    }
                }
                if !payment.isActive {
                    Text("Paused")
                        .foregroundStyle(.orange)
                }
            }

            Section("Occurrences") {
                ForEach(sortedOccurrences) { occurrence in
                    Button {
                        selectedOccurrence = occurrence
                    } label: {
                        OccurrenceRow(occurrence: occurrence)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(payment.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    showingEditSheet = true
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            AddEditRecurringPaymentView(payment: payment)
        }
        .sheet(item: $selectedOccurrence) { occurrence in
            if occurrence.isPaid {
                PaidOccurrenceSummaryView(occurrence: occurrence)
                    .presentationDetents([.medium])
            } else {
                MarkPaidView(occurrence: occurrence)
                    .presentationDetents([.medium])
            }
        }
    }

    private var subscriptionLabel: String {
        switch payment.isNecessary {
        case true: "Necessary"
        case false: "Not necessary"
        case nil: "Yes"
        }
    }
}

private struct OccurrenceRow: View {
    let occurrence: RecurringOccurrence

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.dueDate, format: .dateTime.day().month(.abbreviated).year())
                Text(occurrence.expectedAmount,
                     format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if occurrence.isPaid {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let actualAmount = occurrence.actualAmount {
                        Text(actualAmount,
                             format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.green)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Text("Due")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Sheet for marking an unpaid occurrence as paid, allowing the actual
/// amount to differ from the expected one.
private struct MarkPaidView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let occurrence: RecurringOccurrence

    @State private var actualAmount: Double?

    private var canMarkPaid: Bool {
        guard let actualAmount else { return false }
        return actualAmount > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Due Date") {
                        Text(occurrence.dueDate, format: .dateTime.day().month(.abbreviated).year())
                    }
                    LabeledContent("Expected") {
                        Text(occurrence.expectedAmount,
                             format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                    }
                }

                Section {
                    TextField("Actual Amount Paid", value: $actualAmount, format: .number)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Button("Mark as Paid") {
                        markPaid()
                    }
                    .disabled(!canMarkPaid)
                }
            }
            .navigationTitle("Mark as Paid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                actualAmount = occurrence.expectedAmount
            }
        }
    }

    private func markPaid() {
        guard let actualAmount, actualAmount > 0, let payment = occurrence.parent else { return }

        occurrence.isPaid = true
        occurrence.paidDate = .now
        occurrence.actualAmount = actualAmount

        let transaction = Transaction(
            amount: actualAmount,
            date: .now,
            note: payment.name,
            type: .expense,
            account: payment.account,
            category: payment.category
        )
        modelContext.insert(transaction)
        occurrence.linkedTransaction = transaction
        payment.account?.applyTransaction(amount: actualAmount, type: .expense)

        dismiss()
    }
}

/// Read-only summary for an occurrence that has already been paid.
private struct PaidOccurrenceSummaryView: View {
    @Environment(\.dismiss) private var dismiss

    let occurrence: RecurringOccurrence

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Due Date") {
                    Text(occurrence.dueDate, format: .dateTime.day().month(.abbreviated).year())
                }
                LabeledContent("Expected") {
                    Text(occurrence.expectedAmount,
                         format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                }
                if let actualAmount = occurrence.actualAmount {
                    LabeledContent("Paid") {
                        Text(actualAmount,
                             format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                            .foregroundStyle(.green)
                    }
                }
                if let paidDate = occurrence.paidDate {
                    LabeledContent("Paid On") {
                        Text(paidDate, format: .dateTime.day().month(.abbreviated).year())
                    }
                }
            }
            .navigationTitle("Payment Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RecurringDetailView(
            payment: RecurringPayment(name: "Preview Chit Fund", expectedAmount: 5000,
                                      cadence: .monthly, startDate: .now)
        )
    }
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              RecurringPayment.self, RecurringOccurrence.self],
        inMemory: true
    )
}
