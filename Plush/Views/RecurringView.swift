//
//  RecurringView.swift
//  Plush
//

import SwiftUI
import SwiftData

extension Cadence {
    nonisolated var displayName: String {
        switch self {
        case .daily: "Daily"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .halfYearly: "Half-Yearly"
        case .yearly: "Yearly"
        }
    }
}

struct RecurringView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringPayment.name) private var payments: [RecurringPayment]

    @State private var showingAddSheet = false

    private var activeSubscriptionsCount: Int {
        payments.filter { $0.isSubscription && $0.isActive }.count
    }

    private var totalMonthlyEquivalent: Double {
        payments
            .filter { $0.isSubscription && $0.isActive }
            .reduce(0) { $0 + $1.monthlyEquivalentCost }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        SubscriptionsView()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Subscriptions")
                                Text("\(activeSubscriptionsCount) active")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(totalMonthlyEquivalent,
                                 format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                }

                ForEach(payments) { payment in
                    NavigationLink {
                        RecurringDetailView(payment: payment)
                    } label: {
                        RecurringPaymentRow(payment: payment)
                    }
                }
                .onDelete(perform: deletePayments)
            }
            .overlay {
                if payments.isEmpty {
                    ContentUnavailableView(
                        "No Recurring Payments",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Tap + to set up your first recurring payment.")
                    )
                }
            }
            .navigationTitle("Recurring")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Recurring Payment", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddEditRecurringPaymentView()
            }
        }
    }

    private func deletePayments(at offsets: IndexSet) {
        for index in offsets {
            // Occurrences are removed automatically via the cascade delete rule.
            modelContext.delete(payments[index])
        }
    }
}

private struct RecurringPaymentRow: View {
    let payment: RecurringPayment

    private var nextUnpaidDueDate: Date? {
        payment.occurrences
            .filter { !$0.isPaid }
            .min(by: { $0.dueDate < $1.dueDate })?
            .dueDate
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(payment.name)
                    .font(.body)
                Text(payment.cadence.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let nextUnpaidDueDate {
                    Text("Next: \(nextUnpaidDueDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                } else {
                    Text("None scheduled")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }
            Spacer()
            Text(payment.expectedAmount, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                .font(.body.monospacedDigit())
        }
    }
}

#Preview {
    RecurringView()
        .modelContainer(
            for: [Account.self, Category.self, Transaction.self,
                  RecurringPayment.self, RecurringOccurrence.self],
            inMemory: true
        )
}
