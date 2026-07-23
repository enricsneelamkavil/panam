//
//  MarkPaidView.swift
//  Plush
//

import SwiftUI
import SwiftData

/// Sheet for marking an unpaid occurrence as paid, allowing the actual
/// amount to differ from the expected one.
struct MarkPaidView: View {
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
