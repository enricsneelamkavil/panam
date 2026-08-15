//
//  InvestmentDetailView.swift
//  Panam
//

import SwiftUI
import SwiftData

/// Detail for any Investment, lumpsum or recurring (SIP-style) alike —
/// InvestmentsView routes both here now. Recurring-only content (cadence,
/// "Next" due date, contributed-so-far, the Occurrences list) only shows
/// when investment.isRecurring; a lumpsum investment shows just its basic
/// info (instrument, amount, date) plus Returns below, once any Demat
/// Statements match has been confirmed for it. Either way, Edit (toolbar)
/// is still how amount/date/account get changed — this view itself never
/// mutates those.
struct InvestmentDetailView: View {
    let investment: Investment

    @Environment(\.modelContext) private var modelContext

    @State private var showingEditSheet = false
    @State private var selectedOccurrence: InvestmentOccurrence?

    private static let currencyFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    private var sortedOccurrences: [InvestmentOccurrence] {
        investment.occurrences.sorted { $0.dueDate < $1.dueDate }
    }

    private var nextDueDate: Date? {
        investment.occurrences
            .filter { !$0.isContributed }
            .min(by: { $0.dueDate < $1.dueDate })?
            .dueDate
    }

    /// "Money in" vs. "what it's worth now" — nil (section hidden entirely)
    /// until a Demat Statements match has actually been confirmed at least
    /// once (Investment.currentValue's doc comment).
    private var returnsAmount: Double? {
        guard let currentValue = investment.currentValue else { return nil }
        return currentValue - investment.investedValue
    }

    private var returnsPercent: Double? {
        guard let returnsAmount, investment.investedValue != 0 else { return nil }
        return (returnsAmount / investment.investedValue) * 100
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Instrument", value: investment.instrumentType.displayName)

                if investment.isRecurring {
                    if let cadence = investment.cadence {
                        LabeledContent("Cadence", value: cadence.displayName)
                    }
                    if let nextDueDate {
                        LabeledContent("Next") {
                            Text(nextDueDate, format: .dateTime.day().month(.abbreviated).year())
                        }
                    }
                    if investment.autopayEnabled {
                        HStack {
                            Text("Autopay")
                            Spacer()
                            Image(systemName: "a.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                } else {
                    // Lumpsum has no due-date/cadence concept — just when
                    // the money actually moved.
                    LabeledContent("Date") {
                        Text(investment.date, format: .dateTime.day().month(.abbreviated).year())
                    }
                }

                LabeledContent(investment.isRecurring ? "Amount per Installment" : "Amount") {
                    Text(investment.amount, format: Self.currencyFormat)
                }

                if investment.isRecurring {
                    if investment.priorAmount > 0 {
                        LabeledContent("Starting Amount") {
                            Text(investment.priorAmount, format: Self.currencyFormat)
                        }
                    }
                    LabeledContent("Total Contributed") {
                        Text(investment.totalContributed, format: Self.currencyFormat)
                    }
                    if !investment.isActive {
                        Text("Paused")
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Clearly separate from the Section above — Invested there is
            // pure contribution history and never moves on its own;
            // everything here is the current-worth figure a confirmed Demat
            // Statements match writes (see Investment.currentValue).
            if let currentValue = investment.currentValue, let returnsAmount {
                Section {
                    LabeledContent("Current Value") {
                        Text(currentValue, format: Self.currencyFormat)
                    }
                    LabeledContent("Returns") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(returnsAmount >= 0 ? "+" : "−")\(abs(returnsAmount), format: Self.currencyFormat)")
                                .foregroundStyle(returnsAmount >= 0 ? .green : .red)
                            if let returnsPercent {
                                Text("\(returnsPercent >= 0 ? "+" : "−")\(abs(returnsPercent).formatted(.number.precision(.fractionLength(1))))%")
                                    .font(.caption)
                                    .foregroundStyle(returnsAmount >= 0 ? .green : .red)
                            }
                        }
                    }
                    if let lastValuationDate = investment.lastValuationDate {
                        LabeledContent("As Of") {
                            Text(lastValuationDate, format: .dateTime.day().month(.abbreviated).year())
                        }
                    }
                } header: {
                    Text("Returns")
                } footer: {
                    Text("What this investment is actually worth right now, from your last confirmed Demat Statements match — separate from Invested above, which is only what you've put in.")
                }
            }

            if investment.isRecurring {
                Section("Occurrences") {
                    ForEach(sortedOccurrences) { occurrence in
                        Button {
                            selectedOccurrence = occurrence
                        } label: {
                            OccurrenceRow(occurrence: occurrence)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if occurrence.isContributed {
                                Button(role: .destructive) {
                                    markUnpaid(occurrence)
                                } label: {
                                    Label("Mark as Unpaid", systemImage: "arrow.uturn.backward")
                                }
                            }
                        }
                    }
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
                PaymentSummaryView(
                    title: "Contribution Details",
                    dueDate: occurrence.dueDate,
                    expectedAmount: occurrence.expectedAmount,
                    actualAmount: occurrence.actualAmount,
                    completedDate: occurrence.contributedDate,
                    amountLabel: "Contributed",
                    dateLabel: "Contributed On",
                    onMarkUnpaid: { markUnpaid(occurrence) }
                )
                .presentationDetents([.medium])
            } else {
                MarkContributedView(occurrence: occurrence)
                    .presentationDetents([.medium])
            }
        }
    }

    private func markUnpaid(_ occurrence: InvestmentOccurrence) {
        if let transaction = occurrence.linkedTransaction {
            transaction.account?.reverseTransaction(amount: transaction.amount, type: transaction.type)
            modelContext.delete(transaction)
            occurrence.linkedTransaction = nil
        }
        occurrence.isContributed = false
        occurrence.actualAmount = nil
        occurrence.contributedDate = nil
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
