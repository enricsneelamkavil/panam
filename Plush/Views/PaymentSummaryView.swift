//
//  PaymentSummaryView.swift
//  Plush
//

import SwiftUI

/// Reusable read-only summary for something already paid/contributed.
/// Model-agnostic counterpart to PaymentConfirmationSheet.
struct PaymentSummaryView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let dueDate: Date
    let expectedAmount: Double
    let actualAmount: Double?
    let completedDate: Date?
    var amountLabel = "Paid"
    var dateLabel = "Paid On"

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Due Date") {
                    Text(dueDate, format: .dateTime.day().month(.abbreviated).year())
                }
                LabeledContent("Expected") {
                    Text(expectedAmount,
                         format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                }
                if let actualAmount {
                    LabeledContent(amountLabel) {
                        Text(actualAmount,
                             format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                            .foregroundStyle(.green)
                    }
                }
                if let completedDate {
                    LabeledContent(dateLabel) {
                        Text(completedDate, format: .dateTime.day().month(.abbreviated).year())
                    }
                }
            }
            .navigationTitle(title)
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
