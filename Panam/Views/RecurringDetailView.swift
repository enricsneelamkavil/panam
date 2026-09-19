//
//  RecurringDetailView.swift
//  Panam
//

import SwiftUI
import SwiftData

struct RecurringDetailView: View {
    @Environment(\.modelContext) private var modelContext

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
                if payment.autopayEnabled {
                    HStack {
                        Text("Autopay")
                        Spacer()
                        Image(systemName: "a.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                LabeledContent("Expected Amount") {
                    Text(payment.expectedAmount, format: Self.currencyFormat)
                }
                if let category = payment.category {
                    LabeledContent("Category", value: category.name)
                }
                if let account = payment.account {
                    LabeledContent("Account", value: account.name)
                }
                if let person = payment.person {
                    LabeledContent("Person", value: person.name)
                }
                if payment.isSubscription {
                    LabeledContent("Cost per Day") {
                        Text(payment.costPerDay, format: Self.currencyFormat)
                    }
                    LabeledContent("Monthly Equivalent") {
                        Text(payment.monthlyEquivalentCost, format: Self.currencyFormat)
                    }
                    LabeledContent("Necessary?") {
                        Button {
                            cycleNecessary()
                        } label: {
                            HStack(spacing: 6) {
                                Text(subscriptionLabel)
                                necessaryIcon
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if payment.isPaused {
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if !occurrence.isPaid && !occurrence.isBounced {
                            Button {
                                occurrence.isBounced = true
                                occurrence.bouncedDate = .now
                            } label: {
                                Label("Mark as Bounced", systemImage: "xmark.circle")
                            }
                            .tint(.orange)
                        } else if occurrence.isBounced {
                            Button {
                                occurrence.isBounced = false
                                occurrence.bouncedDate = nil
                            } label: {
                                Label("Mark as Not Bounced", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.blue)
                        }
                        Button(role: .destructive) {
                            deleteOccurrence(occurrence)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
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
                PaymentSummaryView(
                    title: "Payment Details",
                    dueDate: occurrence.dueDate,
                    expectedAmount: occurrence.expectedAmount,
                    actualAmount: occurrence.actualAmount,
                    completedDate: occurrence.paidDate,
                    onMarkUnpaid: { markUnpaid(occurrence) }
                )
                .presentationDetents([.medium])
            } else if occurrence.isBounced {
                PaymentSummaryView(
                    title: "Payment Details",
                    dueDate: occurrence.dueDate,
                    expectedAmount: occurrence.expectedAmount,
                    actualAmount: 0,
                    completedDate: occurrence.bouncedDate,
                    amountLabel: "Paid",
                    dateLabel: "Bounced On",
                    statusLabel: "Bounced",
                    actionButtonTitle: "Mark as Not Bounced",
                    onMarkUnpaid: {
                        occurrence.isBounced = false
                        occurrence.bouncedDate = nil
                    }
                )
                .presentationDetents([.medium])
            } else {
                PaymentConfirmationSheet(
                    title: "Mark as Paid",
                    dueDate: occurrence.dueDate,
                    expectedAmount: occurrence.expectedAmount
                ) { actual in
                    occurrence.isBounced = false
                    occurrence.bouncedDate = nil
                    occurrence.markPaid(actualAmount: actual, context: modelContext)
                }
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

    @ViewBuilder
    private var necessaryIcon: some View {
        switch payment.isNecessary {
        case true:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case false:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case nil:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func cycleNecessary() {
        switch payment.isNecessary {
        case nil: payment.isNecessary = true
        case true: payment.isNecessary = false
        case false: payment.isNecessary = true
        }
    }

    private func markUnpaid(_ occurrence: RecurringOccurrence) {
        if let transaction = occurrence.linkedTransaction {
            transaction.account?.reverseTransaction(amount: transaction.amount, type: transaction.type)
            modelContext.delete(transaction)
            occurrence.linkedTransaction = nil
        }
        occurrence.isPaid = false
        occurrence.actualAmount = nil
        occurrence.paidDate = nil
    }

    private func deleteOccurrence(_ occurrence: RecurringOccurrence) {
        if occurrence.isPaid {
            markUnpaid(occurrence)
        }
        modelContext.delete(occurrence)
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
            } else if occurrence.isBounced {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Bounced")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
