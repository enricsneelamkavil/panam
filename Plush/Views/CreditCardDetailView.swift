//
//  CreditCardDetailView.swift
//  Plush
//

import SwiftUI
import SwiftData
import Charts

struct CreditCardDetailView: View {
    let account: Account

    @Query(sort: \Transaction.date, order: .reverse) private var allTransactions: [Transaction]

    @State private var showingEditSheet = false

    private static let currencyFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    /// Expense transactions on this card.
    private var cardExpenses: [Transaction] {
        allTransactions.filter { $0.account === account && $0.type == .expense }
    }

    /// Next occurrence of the given day of month (today counts if it matches).
    private func upcomingDate(day: Int) -> Date? {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        if calendar.component(.day, from: todayStart) == day {
            return todayStart
        }
        return calendar.nextDate(
            after: todayStart,
            matching: DateComponents(day: day),
            matchingPolicy: .nextTime
        )
    }

    private var nextStatementDate: Date? {
        account.statementDay.flatMap(upcomingDate)
    }

    private var nextDueDate: Date? {
        account.dueDay.flatMap(upcomingDate)
    }

    /// Current statement period: previous statement date up to the next one.
    private var statementPeriod: ClosedRange<Date>? {
        guard let statementDay = account.statementDay,
              let next = nextStatementDate,
              let previous = Calendar.current.nextDate(
                after: next,
                matching: DateComponents(day: statementDay),
                matchingPolicy: .nextTime,
                direction: .backward
              )
        else { return nil }
        return previous...next
    }

    /// This statement period's expenses summed per category, largest first.
    private var categoryTotals: [(category: Category, total: Double)] {
        guard let period = statementPeriod else { return [] }
        let expenses = cardExpenses.filter { period.contains($0.date) && $0.category != nil }
        let groups = Dictionary(grouping: expenses) { $0.category! }
        return groups
            .map { (category: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
    }

    /// Total expense on this card per calendar month for the last 6 months.
    private var monthlyTotals: [(month: Date, total: Double)] {
        let calendar = Calendar.current
        guard let currentMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: .now)
        ) else { return [] }

        let byMonth = Dictionary(grouping: cardExpenses) {
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0.date)) ?? $0.date
        }

        return (0..<6).reversed().compactMap { offset in
            guard let month = calendar.date(byAdding: .month, value: -offset, to: currentMonth)
            else { return nil }
            let total = (byMonth[month] ?? []).reduce(0) { $0 + $1.amount }
            return (month: month, total: total)
        }
    }

    var body: some View {
        List {
            Section {
                headerCard
            }

            if nextStatementDate != nil || nextDueDate != nil {
                Section("Upcoming") {
                    if let nextStatementDate {
                        LabeledContent("Next Statement") {
                            Text(nextStatementDate, format: .dateTime.day().month(.abbreviated).year())
                        }
                    }
                    if let nextDueDate {
                        LabeledContent("Payment Due") {
                            Text(nextDueDate, format: .dateTime.day().month(.abbreviated).year())
                        }
                    }
                }
            }

            if !categoryTotals.isEmpty {
                Section("This Statement Period") {
                    ForEach(categoryTotals, id: \.category.persistentModelID) { entry in
                        HStack {
                            Image(systemName: entry.category.icon)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            Text(entry.category.name)
                            Spacer()
                            Text(entry.total, format: Self.currencyFormat)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Spend Trend") {
                Chart(monthlyTotals, id: \.month) { entry in
                    BarMark(
                        x: .value("Month", entry.month, unit: .month),
                        y: .value("Spent", entry.total)
                    )
                    .foregroundStyle(.tint)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.narrow))
                    }
                }
                .frame(height: 180)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    showingEditSheet = true
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            AddEditAccountView(account: account)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Current Outstanding")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(account.balance, format: Self.currencyFormat)
                    .font(.largeTitle.bold().monospacedDigit())
            }

            if let creditLimit = account.creditLimit, creditLimit > 0 {
                let utilization = max(account.balance / creditLimit, 0)

                LabeledContent("Credit Limit") {
                    Text(creditLimit, format: Self.currencyFormat)
                }
                .font(.subheadline)

                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.quaternary)
                            Capsule()
                                .fill(utilizationColor(utilization))
                                .frame(width: geometry.size.width * min(utilization, 1))
                        }
                    }
                    .frame(height: 8)

                    Text(utilization, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .foregroundStyle(utilizationColor(utilization))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func utilizationColor(_ utilization: Double) -> Color {
        switch utilization {
        case ..<0.3: .green
        case ..<0.7: .yellow
        default: .red
        }
    }
}

#Preview {
    NavigationStack {
        CreditCardDetailView(
            account: Account(name: "Preview Card", type: .creditCard, balance: 12_500,
                             creditLimit: 100_000, statementDay: 5, dueDay: 25)
        )
    }
    .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
