//
//  InvestmentsView.swift
//  Panam
//

import SwiftUI
import SwiftData
import Charts

extension InstrumentType {
    /// Fixed per-type color for the breakdown chart/legend below — same
    /// "assign in a stable order, reserve gray for the catch-all bucket"
    /// convention DashboardView.barPalette/CategoryColorAssigner already
    /// use for spending categories (.other here plays the same role
    /// "Uncategorized" does there). Deliberately not Swift Charts' own
    /// automatic categorical assignment (foregroundStyle(by:)) — this
    /// drives both the pie sectors and the custom legend directly, so the
    /// two can never disagree on which color is which type.
    var chartColor: Color {
        switch self {
        case .mutualFund: .blue
        case .stock: .green
        case .epf: .orange
        case .gold: .purple
        case .silver: .pink
        case .chitFund: .red
        case .recurringDeposit: .yellow
        case .platinum: .teal
        case .other: .gray
        }
    }
}

struct InvestmentsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Investment.date, order: .reverse) private var investments: [Investment]

    @State private var showingAddSheet = false

    private var totalInvested: Double {
        investments.reduce(0) { $0 + $1.investedValue }
    }

    /// Invested total per instrument type, in declaration order, empty types omitted.
    private var typeTotals: [(type: InstrumentType, total: Double)] {
        InstrumentType.allCases.compactMap { type in
            let total = investments.filter { $0.instrumentType == type }.reduce(0) { $0 + $1.investedValue }
            return total > 0 ? (type: type, total: total) : nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if investments.isEmpty {
                    ContentUnavailableView(
                        "No Investments",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Tap + to record your first investment.")
                    )
                } else {
                    List {
                        Section {
                            header
                        }

                        ForEach(typeTotals, id: \.type) { entry in
                            let typeInvestments = investments.filter { $0.instrumentType == entry.type }
                            Section(entry.type.displayName) {
                                ForEach(typeInvestments) { investment in
                                    // Same NavigationLink → InvestmentDetailView
                                    // for both now — lumpsum used to jump
                                    // straight to the edit sheet, but that
                                    // skipped the one place Returns (from a
                                    // confirmed Demat Statements match) is
                                    // shown. InvestmentDetailView itself hides
                                    // everything recurring-only (Occurrences,
                                    // "Next," contributed-so-far) when
                                    // !isRecurring, and still offers Edit from
                                    // its toolbar for changing amount/date/
                                    // account either way.
                                    NavigationLink {
                                        InvestmentDetailView(investment: investment)
                                    } label: {
                                        if investment.isRecurring {
                                            RecurringInvestmentRow(investment: investment)
                                        } else {
                                            InvestmentRow(investment: investment)
                                        }
                                    }
                                }
                                .onDelete { offsets in
                                    deleteInvestments(at: offsets, from: typeInvestments)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Investments")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Investment", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddEditInvestmentView()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Total Invested")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                MaskableCurrencyText(amount: totalInvested)
                    .font(.largeTitle.bold().monospacedDigit())
            }

            Chart(typeTotals, id: \.type) { entry in
                SectorMark(
                    angle: .value("Amount", entry.total),
                    innerRadius: .ratio(0.6),
                    angularInset: 1.5
                )
                .cornerRadius(3)
                .foregroundStyle(entry.type.chartColor)
            }
            .frame(height: 180)

            legend
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// Swift Charts' built-in .chartLegend has no public hook for
    /// lineLimit/truncation on the labels it generates — with instrument
    /// names as long as "Recurring Deposit," its flow layout sometimes
    /// wraps at the wrong point and the last entry on a row pokes past the
    /// card's trailing edge instead of moving to the next line (visible
    /// once enough instrument types are populated to need real wrapping).
    /// A LazyVGrid gives every entry a real, fixed-width cell instead of a
    /// flow-computed one, so .lineLimit(1)/.truncationMode(.tail) has an
    /// actual width to truncate against — the overflow becomes structurally
    /// impossible rather than just less likely.
    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 12, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(typeTotals, id: \.type) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.type.chartColor)
                        .frame(width: 8, height: 8)
                    Text(entry.type.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func deleteInvestments(at offsets: IndexSet, from typeInvestments: [Investment]) {
        for index in offsets {
            let investment = typeInvestments[index]
            // Undo the money movement before removing both records.
            if let transaction = investment.linkedTransaction {
                transaction.account?.reverseTransaction(amount: transaction.amount, type: transaction.type)
                modelContext.delete(transaction)
            }
            modelContext.delete(investment)
        }
    }
}

private struct InvestmentRow: View {
    let investment: Investment

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(investment.name)
                Text(investment.date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MaskableCurrencyText(amount: investment.amount)
                .font(.body.monospacedDigit())
        }
    }
}

private struct RecurringInvestmentRow: View {
    let investment: Investment

    private var nextDueDate: Date? {
        investment.occurrences
            .filter { !$0.isContributed }
            .min(by: { $0.dueDate < $1.dueDate })?
            .dueDate
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(investment.name)
                    if investment.autopayEnabled {
                        Image(systemName: "a.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                if let nextDueDate {
                    Text("Next: \(nextDueDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("None scheduled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                MaskableCurrencyText(amount: investment.investedValue)
                Text("contributed")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    InvestmentsView()
        .modelContainer(
            for: [Account.self, Category.self, Transaction.self,
                  RecurringPayment.self, RecurringOccurrence.self,
                  Person.self, LendingEntry.self, Investment.self, InvestmentOccurrence.self],
            inMemory: true
        )
}
