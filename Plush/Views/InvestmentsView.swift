//
//  InvestmentsView.swift
//  Plush
//

import SwiftUI
import SwiftData
import Charts

struct InvestmentsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Investment.date, order: .reverse) private var investments: [Investment]

    @State private var showingAddSheet = false
    @State private var investmentToEdit: Investment?

    private var totalInvested: Double {
        investments.reduce(0) { $0 + $1.amount }
    }

    /// Invested total per instrument type, in declaration order, empty types omitted.
    private var typeTotals: [(type: InstrumentType, total: Double)] {
        InstrumentType.allCases.compactMap { type in
            let total = investments.filter { $0.instrumentType == type }.reduce(0) { $0 + $1.amount }
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
                                    if investment.isRecurring {
                                        NavigationLink {
                                            InvestmentDetailView(investment: investment)
                                        } label: {
                                            RecurringInvestmentRow(investment: investment)
                                        }
                                    } else {
                                        InvestmentRow(investment: investment)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                investmentToEdit = investment
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
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddEditInvestmentView()
            }
            .sheet(item: $investmentToEdit) { investment in
                AddEditInvestmentView(investment: investment)
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
                .foregroundStyle(by: .value("Type", entry.type.displayName))
            }
            .chartLegend(position: .bottom, alignment: .center)
            .frame(height: 200)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
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
