//
//  DetailedDashboardView.swift
//  Panam
//

import SwiftUI
import SwiftData
import Charts

/// The "Detailed" dashboard: trend charts over a selectable time range.
/// Embedded inside DashboardView's NavigationStack.
struct DetailedDashboardView: View {
    @Query(sort: \Transaction.date) private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var recurringOccurrences: [RecurringOccurrence]
    @Query private var investmentOccurrences: [InvestmentOccurrence]
    @Query private var emiInstallments: [EMIInstallment]

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

                keyMetricsCard

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

                if hasCompletedMonthOfHistory {
                    yearlyProjectionCard
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
                case .bank, .cash, .wallet:
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
            // Transfers and adjustments have no net flow — excluded entirely.
            guard !transaction.isExcludedFromFlow else { continue }

            let key = bucketStart(for: transaction.date)
            var entry = totals[key] ?? (0, 0)
            if transaction.type == .refund {
                entry.expense -= transaction.amount
            } else if transaction.type.isIncomeLike {
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

    /// Uses `effectiveAmount` (not `amount`) so a split transaction only
    /// contributes the user's own portion to a category's trend — see
    /// `Transaction.effectiveAmount`.
    private var topCategoryNames: [String] {
        let expenses = rangeTransactions.filter {
            $0.type == .expense && $0.category != nil && !$0.isExcludedFromFlow
        }
        let groups = Dictionary(grouping: expenses) { $0.category!.name }
        return groups
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.effectiveAmount }) }
            .sorted { $0.total > $1.total }
            .prefix(3)
            .map(\.name)
    }

    private var categoryTrendPoints: [CategoryTrendPoint] {
        let names = topCategoryNames
        guard !names.isEmpty else { return [] }

        var totals: [String: [Date: Double]] = [:]
        for transaction in rangeTransactions where transaction.type == .expense && !transaction.isExcludedFromFlow {
            guard let name = transaction.category?.name, names.contains(name) else { continue }
            totals[name, default: [:]][bucketStart(for: transaction.date), default: 0] += transaction.effectiveAmount
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

    /// Single total per top category for the whole range — used for "Day",
    /// where a hourly trend line would be noise rather than signal.
    private var categoryTotalsForDay: [(name: String, total: Double)] {
        let names = topCategoryNames
        guard !names.isEmpty else { return [] }

        var totals: [String: Double] = [:]
        for transaction in rangeTransactions where transaction.type == .expense && !transaction.isExcludedFromFlow {
            guard let name = transaction.category?.name, names.contains(name) else { continue }
            totals[name, default: 0] += transaction.effectiveAmount
        }
        return names.map { (name: $0, total: totals[$0] ?? 0) }
    }

    private var categoryTrendChart: some View {
        GroupBox("Top Category Trends") {
            if range == .day {
                if categoryTotalsForDay.isEmpty {
                    Text("No categorized expenses in this range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    Chart(categoryTotalsForDay, id: \.name) { entry in
                        BarMark(
                            x: .value("Category", entry.name),
                            y: .value("Spent", entry.total)
                        )
                        .foregroundStyle(by: .value("Category", entry.name))
                    }
                    .frame(height: 180)
                }
            } else if categoryTrendPoints.isEmpty {
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

    // MARK: - Key Metrics

    private var liquidCash: Double {
        accounts
            .filter { $0.type == .bank || $0.type == .cash }
            .reduce(0) { $0 + $1.balance }
    }

    private var currentMonthInterval: DateInterval {
        calendar.dateInterval(of: .month, for: .now) ?? DateInterval(start: .now, duration: 0)
    }

    /// .expense + .taxAndFee within the current month, netted against refunds.
    private var monthlyBurn: Double {
        let monthTransactions = transactions.filter { currentMonthInterval.contains($0.date) }
        let spent = monthTransactions
            .filter { $0.type.isExpenseLike && !$0.isExcludedFromFlow }
            .reduce(0) { $0 + $1.amount }
        let refunded = monthTransactions.filter { $0.type == .refund }.reduce(0) { $0 + $1.amount }
        return spent - refunded
    }

    /// Income-like transactions within the current month, excluding refund
    /// (a refund reduces monthlyBurn instead of adding to income).
    private var monthlyIncome: Double {
        transactions
            .filter {
                $0.type.isIncomeLike && $0.type != .refund && !$0.isLendingRepayment
                    && currentMonthInterval.contains($0.date)
            }
            .reduce(0) { $0 + $1.amount }
    }

    /// nil when there's no income this month yet — shown as "—" rather than
    /// a misleading -infinity%/0%.
    private var savingsRate: Double? {
        guard monthlyIncome > 0 else { return nil }
        return (monthlyIncome - monthlyBurn) / monthlyIncome
    }

    /// Unpaid recurring bills, SIP contributions, and EMI installments due
    /// before the end of the current month.
    private var unpaidCommitmentsThroughMonthEnd: Double {
        let monthEnd = currentMonthInterval.end
        let bills = recurringOccurrences
            .filter { !$0.isPaid && $0.dueDate < monthEnd }
            .reduce(0) { $0 + $1.expectedAmount }
        let sips = investmentOccurrences
            .filter { !$0.isContributed && $0.dueDate < monthEnd }
            .reduce(0) { $0 + $1.expectedAmount }
        let emis = emiInstallments
            .filter { !$0.isPaid && $0.dueDate < monthEnd }
            .reduce(0) { $0 + $1.amount }
        return bills + sips + emis
    }

    private var safeSpend: Double {
        liquidCash - unpaidCommitmentsThroughMonthEnd
    }

    /// Average total expense across the last 3 fully completed calendar months.
    private var trailingThreeMonthAverageExpense: Double? {
        guard let currentMonthStart = calendar.dateInterval(of: .month, for: .now)?.start
        else { return nil }

        var total = 0.0
        var monthsCounted = 0
        for offset in 1...3 {
            guard let monthDate = calendar.date(byAdding: .month, value: -offset, to: currentMonthStart),
                  let monthInterval = calendar.dateInterval(of: .month, for: monthDate)
            else { continue }
            let monthTransactions = transactions.filter { monthInterval.contains($0.date) }
            let spent = monthTransactions
                .filter { $0.type.isExpenseLike && !$0.isExcludedFromFlow }
                .reduce(0) { $0 + $1.amount }
            let refunded = monthTransactions.filter { $0.type == .refund }.reduce(0) { $0 + $1.amount }
            total += spent - refunded
            monthsCounted += 1
        }
        guard monthsCounted > 0 else { return nil }
        return total / Double(monthsCounted)
    }

    /// This month's expense-so-far, extrapolated to a full-month pace.
    private var projectedMonthSpend: Double {
        let daysElapsed = max(calendar.component(.day, from: .now), 1)
        let daysInMonth = calendar.range(of: .day, in: .month, for: .now)?.count ?? daysElapsed
        return monthlyBurn / Double(daysElapsed) * Double(daysInMonth)
    }

    private enum RiskLevel: String {
        case onTrack = "On Track"
        case watch = "Watch"
        case high = "High"
        case unknown = "No Baseline"

        var color: Color {
            switch self {
            case .onTrack: .green
            case .watch: .orange
            case .high: .red
            case .unknown: .secondary
            }
        }
    }

    /// Compares this month's spend pace to the trailing 3-month average.
    /// Thresholds are a heuristic, not a spec value — tune to taste.
    private var riskLevel: RiskLevel {
        guard let average = trailingThreeMonthAverageExpense, average > 0 else { return .unknown }
        let ratio = projectedMonthSpend / average
        switch ratio {
        case ..<1.0: return .onTrack
        case 1.0..<1.25: return .watch
        default: return .high
        }
    }

    private var keyMetricsCard: some View {
        GroupBox("Key Metrics") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    metricTile(title: "Liquid Cash", value: liquidCash, color: .primary)
                    metricTile(title: "Monthly Burn", value: monthlyBurn, color: .red)
                }
                HStack(spacing: 12) {
                    savingsRateTile
                    metricTile(
                        title: "Safe Spend",
                        value: safeSpend,
                        color: safeSpend >= 0 ? .green : .red
                    )
                }
                HStack {
                    Text("Risk Level")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(riskLevel.rawValue)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(riskLevel.color.opacity(0.15), in: Capsule())
                        .foregroundStyle(riskLevel.color)
                }
            }
            .padding(.top, 4)
        }
    }

    private func metricTile(title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var savingsRateTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Savings Rate")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let savingsRate {
                Text(savingsRate, format: .percent.precision(.fractionLength(0)))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(savingsRate >= 0 ? .green : .red)
            } else {
                Text("—")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Yearly Projection

    private var yearStart: Date {
        calendar.dateInterval(of: .year, for: .now)?.start ?? .now
    }

    private var currentCalendarMonthStart: Date {
        calendar.dateInterval(of: .month, for: .now)?.start ?? .now
    }

    /// Gate: is there at least one full completed calendar month of history
    /// (anywhere in the transaction record, not necessarily this year)?
    private var hasCompletedMonthOfHistory: Bool {
        guard let earliestDate = transactions.map(\.date).min() else { return false }
        let earliestMonthStart = calendar.dateInterval(of: .month, for: earliestDate)?.start ?? earliestDate
        return earliestMonthStart < currentCalendarMonthStart
    }

    /// Fully completed calendar months so far this year (January up to,
    /// but not including, the current month).
    private var completedMonthsThisYear: Int {
        max(calendar.dateComponents([.month], from: yearStart, to: currentCalendarMonthStart).month ?? 0, 0)
    }

    private var remainingMonthsThisYear: Int {
        12 - completedMonthsThisYear
    }

    /// Transaction IDs generated by a recurring bill, SIP, or EMI payment —
    /// everything else counts as discretionary spend.
    private var recurringLinkedTransactionIDs: Set<PersistentIdentifier> {
        var ids = Set<PersistentIdentifier>()
        for occurrence in recurringOccurrences {
            if let linked = occurrence.linkedTransaction { ids.insert(linked.persistentModelID) }
        }
        for occurrence in investmentOccurrences {
            if let linked = occurrence.linkedTransaction { ids.insert(linked.persistentModelID) }
        }
        for installment in emiInstallments {
            if let linked = installment.linkedTransaction { ids.insert(linked.persistentModelID) }
        }
        return ids
    }

    private func isDiscretionaryExpense(_ transaction: Transaction) -> Bool {
        transaction.type == .expense && !recurringLinkedTransactionIDs.contains(transaction.persistentModelID)
    }

    /// Actual discretionary spend across the completed months so far this year.
    private var completedMonthsDiscretionarySpend: Double {
        guard completedMonthsThisYear > 0 else { return 0 }
        let interval = DateInterval(start: yearStart, end: currentCalendarMonthStart)
        return transactions
            .filter { isDiscretionaryExpense($0) && interval.contains($0.date) }
            .reduce(0) { $0 + $1.amount }
    }

    private var averageMonthlyDiscretionarySpend: Double {
        guard completedMonthsThisYear > 0 else { return 0 }
        return completedMonthsDiscretionarySpend / Double(completedMonthsThisYear)
    }

    /// Recurring commitments (bills, SIPs, EMIs) for the whole calendar year:
    /// actual amount where already paid/contributed, expected amount otherwise.
    private var recurringContributionsForYear: Double {
        guard let yearInterval = calendar.dateInterval(of: .year, for: .now) else { return 0 }
        let bills = recurringOccurrences
            .filter { yearInterval.contains($0.dueDate) }
            .reduce(0) { $0 + ($1.isPaid ? ($1.actualAmount ?? $1.expectedAmount) : $1.expectedAmount) }
        let sips = investmentOccurrences
            .filter { yearInterval.contains($0.dueDate) }
            .reduce(0) { $0 + ($1.isContributed ? ($1.actualAmount ?? $1.expectedAmount) : $1.expectedAmount) }
        let emis = emiInstallments
            .filter { yearInterval.contains($0.dueDate) }
            .reduce(0) { $0 + $1.amount }
        return bills + sips + emis
    }

    private var projectedYearlyDiscretionary: Double {
        completedMonthsDiscretionarySpend + averageMonthlyDiscretionarySpend * Double(remainingMonthsThisYear)
    }

    private var projectedYearlyTotal: Double {
        projectedYearlyDiscretionary + recurringContributionsForYear
    }

    private var yearLabel: String {
        calendar.component(.year, from: .now).formatted(.number.grouping(.never))
    }

    private var yearlyProjectionCard: some View {
        GroupBox("Yearly Projection") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 4) {
                    Text("Projected Total for \(yearLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(projectedYearlyTotal, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                        .font(.title2.bold().monospacedDigit())
                }
                .frame(maxWidth: .infinity)

                Divider()

                HStack {
                    Text("Discretionary")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(projectedYearlyDiscretionary,
                         format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                        .font(.subheadline.monospacedDigit())
                }
                HStack {
                    Text("Recurring (bills, SIPs, EMIs)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(recurringContributionsForYear,
                         format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                        .font(.subheadline.monospacedDigit())
                }

                Text("Based on \(completedMonthsThisYear) completed month\(completedMonthsThisYear == 1 ? "" : "s") of actual discretionary spend this year, averaged forward across the rest of \(yearLabel).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }
}

private enum TimeRange: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case quarter = "Quarter"
    case year = "Year"

    /// How far back the range reaches from now.
    var startOffset: DateComponents {
        switch self {
        case .day: DateComponents(day: -1)
        case .week: DateComponents(day: -7)
        case .month: DateComponents(month: -1)
        case .quarter: DateComponents(month: -3)
        case .year: DateComponents(year: -1)
        }
    }

    /// Step between net-worth reconstruction samples.
    var sampleStep: DateComponents {
        switch self {
        case .day: DateComponents(hour: 1)
        case .week: DateComponents(day: 1)
        case .month: DateComponents(weekOfYear: 1)
        case .quarter, .year: DateComponents(month: 1)
        }
    }

    /// Bucket size for the bar and trend charts.
    var bucketUnit: Calendar.Component {
        switch self {
        case .day: .hour
        case .week: .day
        case .month, .quarter: .weekOfYear
        case .year: .month
        }
    }

    var bucketStep: DateComponents {
        switch self {
        case .day: DateComponents(hour: 1)
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
              Person.self, LendingEntry.self, Investment.self, InvestmentOccurrence.self,
              CreditCardEMI.self, EMIInstallment.self],
        inMemory: true
    )
}
