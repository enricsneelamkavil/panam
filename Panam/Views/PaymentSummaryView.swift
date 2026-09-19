//
//  PaymentSummaryView.swift
//  Panam
//

import SwiftUI

/// Reusable read-only summary for something already paid/contributed or bounced.
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
    var statusLabel: String? = nil
    var actionButtonTitle = "Mark as Unpaid"
    /// When non-nil, offers an undo/action button (e.g. "Mark as Unpaid" or "Mark as Not Bounced").
    /// The closure is responsible for the underlying model state change; this view
    /// only dismisses afterward.
    var onMarkUnpaid: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let statusLabel {
                        Label(statusLabel, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
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
                                .foregroundStyle(statusLabel == nil ? .green : .orange)
                        }
                    }
                    if let completedDate {
                        LabeledContent(dateLabel) {
                            Text(completedDate, format: .dateTime.day().month(.abbreviated).year())
                        }
                    }
                }

                if let onMarkUnpaid {
                    Section {
                        Button(actionButtonTitle, role: .destructive) {
                            onMarkUnpaid()
                            dismiss()
                        }
                        .foregroundStyle(.red)
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
