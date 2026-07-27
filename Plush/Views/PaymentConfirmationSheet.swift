//
//  PaymentConfirmationSheet.swift
//  Plush
//

import SwiftUI

/// Reusable confirmation sheet for marking something paid/contributed with
/// an adjustable actual amount. Knows nothing about the underlying model —
/// the caller supplies what happens on confirm.
struct PaymentConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let dueDate: Date
    let expectedAmount: Double
    let onConfirm: (Double) -> Void

    @State private var actualAmount: Double?

    private var canConfirm: Bool {
        guard let actualAmount else { return false }
        return actualAmount > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Due Date") {
                        Text(dueDate, format: .dateTime.day().month(.abbreviated).year())
                    }
                    LabeledContent("Expected") {
                        Text(expectedAmount,
                             format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                    }
                }

                Section {
                    TextField("Actual Amount", value: $actualAmount, format: .number)
                        .keyboardType(.decimalPad)
                }

                Button {
                    confirm()
                } label: {
                    Text(title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
                .disabled(!canConfirm)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                actualAmount = expectedAmount
            }
        }
    }

    private func confirm() {
        guard let actualAmount, actualAmount > 0 else { return }
        onConfirm(actualAmount)
        dismiss()
    }
}
