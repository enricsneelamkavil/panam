//
//  RecurringDetailView.swift
//  Plush
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
                PaymentSummaryView(
                    title: "Payment Details",
                    dueDate: occurrence.dueDate,
                    expectedAmount: occurrence.expectedAmount,
                    actualAmount: occurrence.actualAmount,
                    completedDate: occurrence.paidDate
                )
                .presentationDetents([.medium])
            } else {
                PaymentConfirmationSheet(
                    title: "Mark as Paid",
                    dueDate: occurrence.dueDate,
                    expectedAmount: occurrence.expectedAmount
                ) { actual in
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
