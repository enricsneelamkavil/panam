//
//  InvestmentDetailView.swift
//  Plush
//

import SwiftUI
import SwiftData

/// Detail for a recurring (SIP-style) investment — lumpsums open the edit
/// sheet directly and never land here.
struct InvestmentDetailView: View {
    let investment: Investment

    @State private var showingEditSheet = false
    @State private var selectedOccurrence: InvestmentOccurrence?

    private static let currencyFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    private var sortedOccurrences: [InvestmentOccurrence] {
        investment.occurrences.sorted { $0.dueDate < $1.dueDate }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Instrument", value: investment.instrumentType.displayName)
                if let cadence = investment.cadence {
                    LabeledContent("Cadence", value: cadence.displayName)
                }
                LabeledContent("Amount per Installment") {
                    Text(investment.amount, format: Self.currencyFormat)
                }
                LabeledContent("Total Contributed") {
                    Text(investment.totalContributed, format: Self.currencyFormat)
                }
                if !investment.isActive {
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
        .navigationTitle(investment.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    showingEditSheet = true
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            AddEditInvestmentView(investment: investment)
        }
        .sheet(item: $selectedOccurrence) { occurrence in
            if occurrence.isContributed {
                ContributedSummaryView(occurrence: occurrence)
                    .presentationDetents([.medium])
            } else {
                MarkContributedView(occurrence: occurrence)
                    .presentationDetents([.medium])
            }
        }
    }
}

private struct OccurrenceRow: View {
    let occurrence: InvestmentOccurrence

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

            if occurrence.isContributed {
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

/// Sheet for marking an occurrence contributed, allowing the actual amount
/// to differ from the expected one — adapted from MarkPaidView.
private struct MarkContributedView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let occurrence: InvestmentOccurrence

    @State private var actualAmount: Double?

    private var canContribute: Bool {
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
                    TextField("Actual Amount Contributed", value: $actualAmount, format: .number)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Button("Mark as Contributed") {
                        markContributed()
                    }
                    .disabled(!canContribute)
                }
            }
            .navigationTitle("Mark as Contributed")
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

    private func markContributed() {
        guard let actualAmount, actualAmount > 0 else { return }
        occurrence.markContributed(actualAmount: actualAmount, context: modelContext)
        dismiss()
    }
}

/// Read-only summary for an occurrence that has already been contributed.
private struct ContributedSummaryView: View {
    @Environment(\.dismiss) private var dismiss

    let occurrence: InvestmentOccurrence

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
                    LabeledContent("Contributed") {
                        Text(actualAmount,
                             format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                            .foregroundStyle(.green)
                    }
                }
                if let contributedDate = occurrence.contributedDate {
                    LabeledContent("Contributed On") {
                        Text(contributedDate, format: .dateTime.day().month(.abbreviated).year())
                    }
                }
            }
            .navigationTitle("Contribution Details")
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
        InvestmentDetailView(
            investment: Investment(instrumentType: .mutualFund, name: "Preview Index Fund",
                                   amount: 5000)
        )
    }
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              Investment.self, InvestmentOccurrence.self],
        inMemory: true
    )
}
