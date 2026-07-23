//
//  DetailedDashboardView.swift
//  Plush
//

import SwiftUI
import SwiftData
import Charts

/// The "Detailed" dashboard: trend charts over a selectable time range.
/// Embedded inside DashboardView's NavigationStack.
struct DetailedDashboardView: View {
    @Query(sort: \Transaction.date) private var transactions: [Transaction]
    @Query private var accounts: [Account]

    @State private var range: TimeRange = .month

    private var calendar: Calendar { Calendar.current }

    private var rangeStart: Date {
        calendar.date(byAdding: range.startOffset, to: .now) ?? .now
    }

    private var rangeTransactions: [Transaction] {
        transactions.filter { $0.date >= rangeStart && $0.date <= .now }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                if transactions.isEmpty {
                    ContentUnavailableView(
                        "No Data Yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Charts appear once you have transactions.")
                    )
                    .padding(.top, 40)
                } else {
                    netWorthChart
                    incomeExpenseChart
                    categoryTrendChart
                }
            }
            .padding()
        }
    }

    // MARK: - Net worth over time

    private struct NetWorthPoint: Identifiable {
        let date: Date
        let bankCash: Double
        let creditCard: Double
        var id: Date { date }
    }

    /// Reconstructs past balances by starting from current balances and
    /// reversing every transaction that happened after each sample date.
    private var netWorthPoints: [NetWorthPoint] {
        var sampleDates: [Date] = []
        var date = rangeStart
        while date < .now {
            sampleDates.append(date)
            guard let next = calendar.date(byAdding: range.sampleStep, to: date), next > date
            else { break }
            date = next
        }
        sampleDates.append(.now)

        let currentBankCash = accounts
            .filter { $0.type != .creditCard }
            .reduce(0) { $0 + $1.balance }
        let currentCreditCard = accounts
            .filter { $0.type == .creditCard }
            .reduce(0) { $0 + $1.balance }

        return sampleDates.map { sampleDate in
            var bankCash = currentBankCash
            var creditCard = currentCreditCard
            for transaction in transactions where transaction.date > sampleDate {
                guard let account = transaction.account else { continue }
                switch account.type {
                case .bank, .cash:
                    bankCash -= transaction.type == .income ? transaction.amount : -transaction.amount
                case .creditCard:
                    creditCard -= transaction.type == .expense ? transaction.amount : -transaction.amount
                }
            }
            return NetWorthPoint(date: sampleDate, bankCash: bankCash, creditCard: creditCard)
        }
    }

    private var netWorthChart: some View {
        GroupBox("Net Worth") {
            Chart(netWorthPoints) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Amount", point.bankCash),
                    series: .value("Series", "Net Worth")
                )
                .foregroundStyle(by: .value("Series", "Net Worth"))

                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Amount", point.creditCard),
                    series: .value("Series", "Card Outstanding")
                )
                .foregroundStyle(by: .value("Series", "Card Outstanding"))
                .lineStyle(StrokeStyle(dash: [4, 4]))
            }
            .chartForegroundStyleScale([
                "Net Worth": Color.blue,
                "Card Outstanding": Color.orange,
            ])
            .frame(height: 200)

            Text("Card outstanding is shown for reference and is not part of net worth.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }

    // MARK: - Income vs expense bars

    private struct PeriodBucket: Identifiable {
        let start: Date
        var income: Double
        var expense: Double
        var id: Date { start }
    }

    /// All bucket start dates covering the range, so quiet periods still get bars.
    private var bucketStarts: [Date] {
        guard let first = calendar.dateInterval(of: range.bucketUnit, for: rangeStart)?.start
        else { return [] }
        var starts: [Date] = []
        var date = first
        while date <= .now {
            starts.append(date)
            guard let next = calendar.date(byAdding: range.bucketStep, to: date), next > date
            else { break }
            date = next
        }
        return starts
    }

    private func bucketStart(for date: Date) -> Date {
        calendar.dateInterval(of: range.bucketUnit, for: date)?.start ?? date
    }

    private var incomeExpenseBuckets: [PeriodBucket] {
        var totals: [Date: (income: Double, expense: Double)] = [:]
        for transaction in rangeTransactions {
            let key = bucketStart(for: transaction.date)
            var entry = totals[key] ?? (0, 0)
            if transaction.type == .income {
                entry.income += transaction.amount
            } else {
                entry.expense += transaction.amount
            }
            totals[key] = entry
        }
        return bucketStarts.map { start in
            let entry = totals[start] ?? (0, 0)
            return PeriodBucket(start: start, income: entry.income, expense: entry.expense)
        }
    }

    private var incomeExpenseChart: some View {
        GroupBox("Income vs Expense") {
            // Diverging bars: income grows up, expense hangs down from zero.
            Chart(incomeExpenseBuckets) { bucket in
                BarMark(
                    x: .value("Period", bucket.start, unit: range.bucketUnit),
                    y: .value("Income", bucket.income)
                )
                .foregroundStyle(.green)

                BarMark(
                    x: .value("Period", bucket.start, unit: range.bucketUnit),
                    y: .value("Expense", -bucket.expense)
                )
                .foregroundStyle(.red)
            }
            .frame(height: 200)
        }
    }

    // MARK: - Category trend

    private struct CategoryTrendPoint: Identifiable {
        let categoryName: String
        let bucketStart: Date
        let total: Double
        var id: String { "\(categoryName)|\(bucketStart.timeIntervalSinceReferenceDate)" }
    }

    private var topCategoryNames: [String] {
        let expenses = rangeTransactions.filter { $0.type == .expense && $0.category != nil }
        let groups = Dictionary(grouping: expenses) { $0.category!.name }
        return groups
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
            .prefix(3)
            .map(\.name)
    }

    private var categoryTrendPoints: [CategoryTrendPoint] {
        let names = topCategoryNames
        guard !names.isEmpty else { return [] }

        var totals: [String: [Date: Double]] = [:]
        for transaction in rangeTransactions where transaction.type == .expense {
            guard let name = transaction.category?.name, names.contains(name) else { continue }
            totals[name, default: [:]][bucketStart(for: transaction.date), default: 0] += transaction.amount
        }

        // Zero-fill every bucket so each category draws a continuous line.
        return names.flatMap { name in
            bucketStarts.map { start in
                CategoryTrendPoint(
                    categoryName: name,
                    bucketStart: start,
                    total: totals[name]?[start] ?? 0
                )
            }
        }
    }

    private var categoryTrendChart: some View {
        GroupBox("Top Category Trends") {
            if categoryTrendPoints.isEmpty {
                Text("No categorized expenses in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                Chart(categoryTrendPoints) { point in
                    LineMark(
                        x: .value("Period", point.bucketStart, unit: range.bucketUnit),
                        y: .value("Spent", point.total),
                        series: .value("Category", point.categoryName)
                    )
                    .foregroundStyle(by: .value("Category", point.categoryName))
                }
                .frame(height: 180)
            }
        }
    }
}

private enum TimeRange: String, CaseIterable {
    case week = "Week"
    case month = "Month"
    case quarter = "Quarter"
    case year = "Year"

    /// How far back the range reaches from now.
    var startOffset: DateComponents {
        switch self {
        case .week: DateComponents(day: -7)
        case .month: DateComponents(month: -1)
        case .quarter: DateComponents(month: -3)
        case .year: DateComponents(year: -1)
        }
    }

    /// Step between net-worth reconstruction samples.
    var sampleStep: DateComponents {
        switch self {
        case .week: DateComponents(day: 1)
        case .month: DateComponents(weekOfYear: 1)
        case .quarter, .year: DateComponents(month: 1)
        }
    }

    /// Bucket size for the bar and trend charts.
    var bucketUnit: Calendar.Component {
        switch self {
        case .week: .day
        case .month, .quarter: .weekOfYear
        case .year: .month
        }
    }

    var bucketStep: DateComponents {
        switch self {
        case .week: DateComponents(day: 1)
        case .month, .quarter: DateComponents(weekOfYear: 1)
        case .year: DateComponents(month: 1)
        }
    }
}

#Preview {
    NavigationStack {
        DetailedDashboardView()
    }
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              RecurringPayment.self, RecurringOccurrence.self,
              Person.self, LendingEntry.self, Investment.self],
        inMemory: true
    )
}
