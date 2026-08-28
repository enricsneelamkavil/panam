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
    // Lets the calendar heat-map switch to the Flow tab directly instead of
    // pushing a filtered TransactionsView onto this tab's own
    // NavigationStack — see TabNavigationState's doc comment.
    @Environment(TabNavigationState.self) private var tabNavigation
    @Query(sort: \Transaction.date) private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var recurringOccurrences: [RecurringOccurrence]
    @Query private var investmentOccurrences: [InvestmentOccurrence]
    @Query private var emiInstallments: [EMIInstallment]

    @State private var range: TimeRange = .month
    /// Months back from the current month the calendar heat-map is
    /// showing — 0 is the current month, 1 is one month back, etc. An
    /// offset rather than a stored Date so "jump back to the current
    /// month" and "don't let > go into the future" are both a plain
    /// integer comparison against 0.
    @State private var heatMapMonthOffset = 0

    private var calendar: Calendar { Calendar.current }

    private var rangeStart: Date {
        calendar.date(byAdding: range.startOffset, to: .now) ?? .now
    }

    private var rangeTransactions: [Transaction] {
        transactions.filter { $0.date >= rangeStart && $0.date <= .now }
    }

    var body: some View {
        // Computed once per body evaluation — see computeMetrics()'s doc
        // comment for why this matters: every card below reads from this
        // single pass instead of independently re-scanning `transactions`
        // from its own computed property.
        let metrics = computeMetrics()

        ScrollView {
            VStack(spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                keyMetricsCard(metrics)

                if transactions.isEmpty {
                    ContentUnavailableView(
                        "No Data Yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Charts appear once you have transactions.")
                    )
                    .padding(.top, 40)
                } else {
                    // Its own view, with its own drag-selection state — see
                    // SpentThisMonthChartView's doc comment for why this
                    // chart specifically was pulled out of this body rather
                    // than staying an inline computed property like its
                    // siblings below.
                    SpentThisMonthChartView(
                        thisMonthPoints: metrics.thisMonthCumulativePoints,
                        lastMonthPoints: metrics.lastMonthCumulativePoints
                    )
                    calendarHeatMap(metrics)
                    netWorthChart(metrics)
                    incomeExpenseChart(metrics)
                    categoryTrendChart(metrics)
                }

                if hasCompletedMonthOfHistory {
                    yearlyProjectionCard(metrics)
                }
            }
            .padding()
        }
    }

    // MARK: - Metrics cache

    /// Every @Query-derived figure this dashboard's cards need. Built once
    /// by `computeMetrics()` instead of exposed as independent computed
    /// properties — see that function's doc comment for why.
    private struct DashboardMetrics {
        var liquidCash: Double = 0
        var monthlyBurn: Double = 0
        var savingsRate: Double?
        var safeSpend: Double = 0
        var riskLevel: RiskLevel = .unknown

        var thisMonthCumulativePoints: [CumulativeSpendPoint] = []
        var lastMonthCumulativePoints: [CumulativeSpendPoint] = []

        var heatMapDailySpend: [Int: Double] = [:]
        var heatMapAverageDailySpend: Double = 0

        var netWorthPoints: [NetWorthPoint] = []
        var incomeExpenseBuckets: [PeriodBucket] = []

        var topCategoryNames: [String] = []
        var categoryTrendPoints: [CategoryTrendPoint] = []
        var categoryTotalsForDay: [(name: String, total: Double)] = []

        var projectedYearlyTotal: Double = 0
        var projectedYearlyDiscretionary: Double = 0
    }

    /// Computes every @Query-derived figure the dashboard's cards need,
    /// sharing intermediate results across cards instead of letting each
    /// card's own computed property re-derive them independently. Before
    /// this existed: `recurringLinkedTransactionIDs` — itself an
    /// O(recurring + investment + EMI occurrences) `Set` rebuild — was
    /// reconstructed *inside* `isDiscretionaryExpense`'s per-transaction
    /// filter closure, making `completedMonthsDiscretionarySpend` an
    /// O(transactions × occurrences) computation; `topCategoryNames` was
    /// computed twice independently (once each for `categoryTrendPoints`
    /// and `categoryTotalsForDay`); and `dailySpendByDayOfMonth`/
    /// `netWorthPoints` were re-derived from the full `transactions` array
    /// on every independent property access within a single render.
    ///
    /// Called exactly once per `body` evaluation. That evaluation now only
    /// happens when the range picker, the heat-map month, or the
    /// underlying @Query data actually change — dragging on the "Spent
    /// This Month" chart no longer triggers it at all, since that chart's
    /// selection state lives on its own `SpentThisMonthChartView` instead
    /// of on this view. That split is what makes "computed once per real
    /// change" and "computed once per render" the same thing here, without
    /// needing a separate cross-render cache with its own invalidation
    /// logic to keep in sync with edits.
    private func computeMetrics() -> DashboardMetrics {
        var metrics = DashboardMetrics()

        // Key metrics
        metrics.liquidCash = accounts
            .filter { $0.type == .bank || $0.type == .cash }
            .reduce(0) { $0 + $1.balance }

        let currentMonthTransactions = transactions.filter { currentMonthInterval.contains($0.date) }
        let currentMonthSpent = currentMonthTransactions
            .filter { $0.type.isExpenseLike && !$0.isExcludedFromFlow }
            .reduce(0) { $0 + $1.amount }
        let currentMonthRefunded = currentMonthTransactions
            .filter { $0.type == .refund }
            .reduce(0) { $0 + $1.amount }
        metrics.monthlyBurn = currentMonthSpent - currentMonthRefunded

        let monthlyIncome = transactions
            .filter {
                $0.type.isIncomeLike && $0.type != .refund && !$0.isLendingRepayment
                    && currentMonthInterval.contains($0.date)
            }
            .reduce(0) { $0 + $1.amount }
        metrics.savingsRate = monthlyIncome > 0 ? (monthlyIncome - metrics.monthlyBurn) / monthlyIncome : nil
        metrics.safeSpend = metrics.liquidCash - unpaidCommitmentsThroughMonthEnd

        var trailingTotal = 0.0
        var trailingMonthsCounted = 0
        if let currentMonthStart = calendar.dateInterval(of: .month, for: .now)?.start {
            for offset in 1...3 {
                guard let monthDate = calendar.date(byAdding: .month, value: -offset, to: currentMonthStart),
                      let monthInterval = calendar.dateInterval(of: .month, for: monthDate)
                else { continue }
                let monthTransactions = transactions.filter { monthInterval.contains($0.date) }
                let spent = monthTransactions
                    .filter { $0.type.isExpenseLike && !$0.isExcludedFromFlow }
                    .reduce(0) { $0 + $1.amount }
                let refunded = monthTransactions.filter { $0.type == .refund }.reduce(0) { $0 + $1.amount }
                trailingTotal += spent - refunded
                trailingMonthsCounted += 1
            }
        }
        let trailingThreeMonthAverageExpense: Double? =
            trailingMonthsCounted > 0 ? trailingTotal / Double(trailingMonthsCounted) : nil

        let daysElapsed = max(calendar.component(.day, from: .now), 1)
        let daysInCurrentMonth = calendar.range(of: .day, in: .month, for: .now)?.count ?? daysElapsed
        let projectedMonthSpend = metrics.monthlyBurn / Double(daysElapsed) * Double(daysInCurrentMonth)

        if let average = trailingThreeMonthAverageExpense, average > 0 {
            let ratio = projectedMonthSpend / average
            switch ratio {
            case ..<1.0: metrics.riskLevel = .onTrack
            case 1.0..<1.25: metrics.riskLevel = .watch
            default: metrics.riskLevel = .high
            }
        } else {
            metrics.riskLevel = .unknown
        }

        // Spent This Month chart
        let thisMonthDaily = dailySpendByDayOfMonth(in: currentMonthInterval)
        let today = calendar.component(.day, from: .now)
        var running = 0.0
        metrics.thisMonthCumulativePoints = (1...today).map { day in
            running += thisMonthDaily[day] ?? 0
            return CumulativeSpendPoint(day: day, cumulativeAmount: running, series: "This Month")
        }

        let lastInterval = previousMonthInterval
        let lastMonthDaily = dailySpendByDayOfMonth(in: lastInterval)
        let daysInLastMonth = calendar.range(of: .day, in: .month, for: lastInterval.start)?.count ?? 30
        running = 0.0
        metrics.lastMonthCumulativePoints = (1...daysInLastMonth).map { day in
            running += lastMonthDaily[day] ?? 0
            return CumulativeSpendPoint(day: day, cumulativeAmount: running, series: "Last Month")
        }

        // Calendar heat-map
        let heatMapDaily = dailySpendByDayOfMonth(in: heatMapMonthInterval)
        metrics.heatMapDailySpend = heatMapDaily
        metrics.heatMapAverageDailySpend = heatMapDaysInMonth > 0
            ? heatMapDaily.values.reduce(0, +) / Double(heatMapDaysInMonth)
            : 0

        // Net worth
        metrics.netWorthPoints = netWorthPoints()

        // Income vs expense and category trend share the same range-scoped
        // slice and bucket boundaries — computed once here rather than
        // once per consumer.
        let rangeTxns = rangeTransactions
        let starts = bucketStarts

        var bucketTotals: [Date: (income: Double, expense: Double)] = [:]
        for transaction in rangeTxns {
            // Transfers and adjustments have no net flow — excluded entirely.
            guard !transaction.isExcludedFromFlow else { continue }
            let key = bucketStart(for: transaction.date)
            var entry = bucketTotals[key] ?? (0, 0)
            if transaction.type == .refund {
                entry.expense -= transaction.amount
            } else if transaction.type.isIncomeLike {
                entry.income += transaction.amount
            } else {
                entry.expense += transaction.amount
            }
            bucketTotals[key] = entry
        }
        metrics.incomeExpenseBuckets = starts.map { start in
            let entry = bucketTotals[start] ?? (0, 0)
            return PeriodBucket(start: start, income: entry.income, expense: entry.expense)
        }

        let expenseTxns = rangeTxns.filter { $0.type == .expense && $0.category != nil && !$0.isExcludedFromFlow }
        let categoryGroups = Dictionary(grouping: expenseTxns) { $0.category!.name }
        let topNames = categoryGroups
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.effectiveAmount }) }
            .sorted { $0.total > $1.total }
            .prefix(3)
            .map(\.name)
        metrics.topCategoryNames = topNames

        if !topNames.isEmpty {
            if range == .day {
                var totals: [String: Double] = [:]
                for transaction in rangeTxns where transaction.type == .expense && !transaction.isExcludedFromFlow {
                    guard let name = transaction.category?.name, topNames.contains(name) else { continue }
                    totals[name, default: 0] += transaction.effectiveAmount
                }
                metrics.categoryTotalsForDay = topNames.map { (name: $0, total: totals[$0] ?? 0) }
            } else {
                var totals: [String: [Date: Double]] = [:]
                for transaction in rangeTxns where transaction.type == .expense && !transaction.isExcludedFromFlow {
                    guard let name = transaction.category?.name, topNames.contains(name) else { continue }
                    totals[name, default: [:]][bucketStart(for: transaction.date), default: 0] += transaction.effectiveAmount
                }
                // Zero-fill every bucket so each category draws a continuous line.
                metrics.categoryTrendPoints = topNames.flatMap { name in
                    starts.map { start in
                        CategoryTrendPoint(categoryName: name, bucketStart: start, total: totals[name]?[start] ?? 0)
                    }
                }
            }
        }

        // Yearly projection
        if completedMonthsThisYear > 0 {
            let interval = DateInterval(start: yearStart, end: currentCalendarMonthStart)
            // Built once here, then just checked with `.contains` per
            // transaction below — not rebuilt from scratch inside the
            // filter closure (that O(transactions × occurrences) bug is
            // exactly what made this the dashboard's worst per-render cost).
            let linkedIDs = recurringLinkedTransactionIDs()
            let completedMonthsDiscretionarySpend = transactions
                .filter { isDiscretionaryExpense($0, linkedIDs: linkedIDs) && interval.contains($0.date) }
                .reduce(0) { $0 + $1.amount }
            let averageMonthlyDiscretionarySpend = completedMonthsDiscretionarySpend / Double(completedMonthsThisYear)
            metrics.projectedYearlyDiscretionary =
                completedMonthsDiscretionarySpend + averageMonthlyDiscretionarySpend * Double(remainingMonthsThisYear)
            metrics.projectedYearlyTotal = metrics.projectedYearlyDiscretionary + recurringContributionsForYear
        }

        return metrics
    }

    // MARK: - Shared day-of-month spend helper

    /// Per-day expense total (day-of-month → amount) within `interval` —
    /// shared by both the cumulative comparison chart and the calendar
    /// heat-map below, so "what counts as a day's spend" only has one
    /// definition in this file. Same expense/refund netting convention as
    /// monthlyBurn (a .refund nets against the day it lands on, not the
    /// day of the original purchase) and effectiveAmount rather than
    /// amount (categoryTrendChart's own reasoning: a split transaction
    /// should only count the user's own share).
    private func dailySpendByDayOfMonth(in interval: DateInterval) -> [Int: Double] {
        var totals: [Int: Double] = [:]
        for transaction in transactions where interval.contains(transaction.date) && !transaction.isExcludedFromFlow {
            let day = calendar.component(.day, from: transaction.date)
            if transaction.type == .refund {
                totals[day, default: 0] -= transaction.effectiveAmount
            } else if transaction.type.isExpenseLike {
                totals[day, default: 0] += transaction.effectiveAmount
            }
        }
        return totals
    }

    // MARK: - Spent This Month (cumulative comparison)

    private var previousMonthInterval: DateInterval {
        let previousMonthDate = calendar.date(byAdding: .month, value: -1, to: currentMonthInterval.start) ?? currentMonthInterval.start
        return calendar.dateInterval(of: .month, for: previousMonthDate) ?? DateInterval(start: previousMonthDate, duration: 0)
    }

    // MARK: - Calendar heat-map

    private var heatMapMonthStart: Date {
        calendar.date(byAdding: .month, value: -heatMapMonthOffset, to: currentCalendarMonthStart) ?? currentCalendarMonthStart
    }

    private var heatMapMonthInterval: DateInterval {
        calendar.dateInterval(of: .month, for: heatMapMonthStart) ?? DateInterval(start: heatMapMonthStart, duration: 0)
    }

    private var heatMapDaysInMonth: Int {
        calendar.range(of: .day, in: .month, for: heatMapMonthStart)?.count ?? 30
    }

    /// Calendar.Component.weekday is always 1 = Sunday … 7 = Saturday in
    /// the Gregorian calendar regardless of the device's firstWeekday
    /// setting (that only affects week-of-year/week-of-month math, not
    /// this raw component) — exactly what a fixed Sun-first grid needs,
    /// independent of locale.
    private var heatMapLeadingEmptyCells: Int {
        calendar.component(.weekday, from: heatMapMonthStart) - 1
    }

    /// Near-transparent for a ₹0 day, scaling up toward fully saturated as
    /// spend approaches (and passes) twice the month's daily average —
    /// twice-average as the "fully saturated" ceiling rather than the
    /// month's single highest day, so one outlier splurge doesn't wash out
    /// every other day's relative color by comparison. `average` is
    /// `computeMetrics()`'s `heatMapAverageDailySpend`, computed once per
    /// render rather than once per cell (30-ish redundant recomputations
    /// otherwise, one per day in the grid).
    private func heatMapCellOpacity(for spend: Double, average: Double) -> Double {
        guard spend > 0 else { return 0.04 }
        guard average > 0 else { return 0.5 }
        let ratio = spend / (average * 2)
        return min(0.15 + ratio * 0.85, 1.0)
    }

    private func heatMapDate(forDay day: Int) -> Date {
        calendar.date(byAdding: .day, value: day - 1, to: heatMapMonthStart) ?? heatMapMonthStart
    }

    private var heatMapMonthLabel: String {
        heatMapMonthStart.formatted(.dateTime.month(.wide).year())
    }

    private static let weekdayHeaders = ["S", "M", "T", "W", "T", "F", "S"]

    /// One entry per grid cell — nil for a leading blank before the 1st,
    /// the day number otherwise — combined into a single array specifically
    /// so the grid below needs only one ForEach for its cells. Confirmed
    /// against a real render that keeping the blanks and the real days as
    /// two separate `ForEach(_, id: \.self)` loops sharing the same
    /// LazyVGrid silently drops days whose Int id collides with one of the
    /// blank placeholders' ids (0..<leadingCount vs 1...daysInMonth
    /// overlap on every value up to leadingCount) — SwiftUI's lazy
    /// containers de-duplicate by id across sibling ForEach, not just
    /// within one, so days 1 through leadingCount silently vanished from
    /// the rendered month. One array with one ForEach makes that
    /// collision structurally impossible.
    private var heatMapCells: [Int?] {
        Array(repeating: nil, count: heatMapLeadingEmptyCells) + (1...heatMapDaysInMonth).map(Optional.init)
    }

    private func calendarHeatMap(_ metrics: DashboardMetrics) -> some View {
        GroupBox("Spending Calendar") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        heatMapMonthOffset += 1
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    Spacer()
                    Text(heatMapMonthLabel)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        heatMapMonthOffset -= 1
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(heatMapMonthOffset == 0)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.appPrimary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(Array(Self.weekdayHeaders.enumerated()), id: \.offset) { index, symbol in
                        Text(symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .id("header-\(index)")
                    }

                    ForEach(Array(heatMapCells.enumerated()), id: \.offset) { index, day in
                        Group {
                            if let day {
                                // Switches tabs rather than pushing
                                // TransactionsView onto this tab's own
                                // NavigationStack — a filtered transaction
                                // list belongs in the Flow tab, on Flow's
                                // own stack, not layered on top of Analyze.
                                // See TabNavigationState's doc comment for
                                // why this needs shared state rather than a
                                // plain NavigationLink.
                                Button {
                                    tabNavigation.pendingTransactionsDayFilter = heatMapDate(forDay: day)
                                    tabNavigation.selectedTab = .flow
                                } label: {
                                    heatMapCell(
                                        day: day,
                                        spend: metrics.heatMapDailySpend[day] ?? 0,
                                        average: metrics.heatMapAverageDailySpend
                                    )
                                }
                                .buttonStyle(.plain)
                            } else {
                                Color.clear.frame(height: 44)
                            }
                        }
                        .id("cell-\(index)")
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func heatMapCell(day: Int, spend: Double, average: Double) -> some View {
        VStack(spacing: 2) {
            Text("\(day)")
                .font(.caption2.weight(.medium))
            if spend > 0 {
                MaskableCurrencyText(amount: spend)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(Color.appPrimary.opacity(heatMapCellOpacity(for: spend, average: average)), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
    private func netWorthPoints() -> [NetWorthPoint] {
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

    private func netWorthChart(_ metrics: DashboardMetrics) -> some View {
        GroupBox("Net Worth") {
            Chart(metrics.netWorthPoints) { point in
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

    private func incomeExpenseChart(_ metrics: DashboardMetrics) -> some View {
        GroupBox("Income vs Expense") {
            // Diverging bars: income grows up, expense hangs down from zero.
            Chart(metrics.incomeExpenseBuckets) { bucket in
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

    private func categoryTrendChart(_ metrics: DashboardMetrics) -> some View {
        GroupBox("Top Category Trends") {
            if range == .day {
                if metrics.categoryTotalsForDay.isEmpty {
                    Text("No categorized expenses in this range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    Chart(metrics.categoryTotalsForDay, id: \.name) { entry in
                        BarMark(
                            x: .value("Category", entry.name),
                            y: .value("Spent", entry.total)
                        )
                        .foregroundStyle(by: .value("Category", entry.name))
                    }
                    .frame(height: 180)
                }
            } else if metrics.categoryTrendPoints.isEmpty {
                Text("No categorized expenses in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                Chart(metrics.categoryTrendPoints) { point in
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

    private var currentMonthInterval: DateInterval {
        calendar.dateInterval(of: .month, for: .now) ?? DateInterval(start: .now, duration: 0)
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

    private func keyMetricsCard(_ metrics: DashboardMetrics) -> some View {
        GroupBox("Key Metrics") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    metricTile(title: "Liquid Cash", value: metrics.liquidCash, color: .primary)
                    metricTile(title: "Monthly Burn", value: metrics.monthlyBurn, color: .red)
                }
                HStack(spacing: 12) {
                    savingsRateTile(metrics.savingsRate)
                    metricTile(
                        title: "Safe Spend",
                        value: metrics.safeSpend,
                        color: metrics.safeSpend >= 0 ? .green : .red
                    )
                }
                HStack {
                    Text("Risk Level")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(metrics.riskLevel.rawValue)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(metrics.riskLevel.color.opacity(0.15), in: Capsule())
                        .foregroundStyle(metrics.riskLevel.color)
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

    private func savingsRateTile(_ rate: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Savings Rate")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let rate {
                Text(rate, format: .percent.precision(.fractionLength(0)))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(rate >= 0 ? .green : .red)
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
    /// everything else counts as discretionary spend. Returned rather than
    /// exposed as a computed property so callers build it exactly once and
    /// pass it in — see computeMetrics()'s doc comment for why that matters.
    private func recurringLinkedTransactionIDs() -> Set<PersistentIdentifier> {
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

    private func isDiscretionaryExpense(_ transaction: Transaction, linkedIDs: Set<PersistentIdentifier>) -> Bool {
        transaction.type == .expense && !linkedIDs.contains(transaction.persistentModelID)
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

    private var yearLabel: String {
        calendar.component(.year, from: .now).formatted(.number.grouping(.never))
    }

    private func yearlyProjectionCard(_ metrics: DashboardMetrics) -> some View {
        GroupBox("Yearly Projection") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 4) {
                    Text("Projected Total for \(yearLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(metrics.projectedYearlyTotal, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                        .font(.title2.bold().monospacedDigit())
                }
                .frame(maxWidth: .infinity)

                Divider()

                HStack {
                    Text("Discretionary")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(metrics.projectedYearlyDiscretionary,
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

/// One point on the "Spent This Month" cumulative-comparison chart — a
/// running total for either the current or the previous calendar month,
/// plotted by day-of-month. Shared between `DetailedDashboardView` (which
/// computes both series once in `computeMetrics()`) and
/// `SpentThisMonthChartView` (which renders them and owns the drag-to-
/// inspect interaction), so it lives at file scope rather than nested in
/// either.
private struct CumulativeSpendPoint: Identifiable {
    let day: Int
    let cumulativeAmount: Double
    let series: String
    var id: String { "\(series)|\(day)" }
}

/// The "Spent This Month" card, as its own view rather than a computed
/// property on `DetailedDashboardView`. It used to be one — along with the
/// `selectedSpendDay`/`selectedSpendSeries`/`calloutSize` state that drives
/// its drag-to-inspect interaction — and that was the root cause of the
/// chart feeling laggy (and, with a large transaction history, freezing
/// outright) while dragging: that state lived directly on
/// `DetailedDashboardView`, whose `body` is one flat property building
/// every dashboard card in sequence. Every `DragGesture.onChanged` during a
/// touch therefore re-evaluated `keyMetricsCard`, `calendarHeatMap`,
/// `netWorthChart`, `incomeExpenseChart`, `categoryTrendChart`, and
/// `yearlyProjectionCard` too — none of which have anything to do with this
/// chart — redoing several uncached O(transactions) and worse scans on
/// every single frame of the drag.
///
/// Taking only the two already-computed point arrays as parameters (no
/// `@Query`, no access to `DetailedDashboardView`'s environment or its
/// other derived metrics) means a drag here can only ever invalidate this
/// view's own body.
private struct SpentThisMonthChartView: View {
    let thisMonthPoints: [CumulativeSpendPoint]
    let lastMonthPoints: [CumulativeSpendPoint]

    /// Day currently under the drag/tap on the chart — nil means "not
    /// touching the chart right now," which hides the rule line, the
    /// highlighted point, and the callout together.
    @State private var selectedSpendDay: Int?

    /// Which of the two series the touch actually resolved to — set
    /// alongside `selectedSpendDay` by `updateSelection(at:proxy:geometry:)`,
    /// which compares the touch's y-position against each series' y-value
    /// at that day rather than just picking an x and showing both. Nil
    /// only when neither series has data at the selected day (shouldn't
    /// normally happen, since a day is only ever selected from a touch
    /// inside the plot area).
    @State private var selectedSpendSeries: SpendSeriesSelection?

    private enum SpendSeriesSelection {
        case thisMonth
        case lastMonth
    }

    /// Measured size of the floating callout bubble, captured via
    /// `.onGeometryChange` where it's rendered below — needed to center it
    /// horizontally on the touch point and to sit its bottom edge just
    /// above the line, since `.position(x:y:)` places a view's *center*
    /// and the bubble's size varies with which series is highlighted.
    @State private var calloutSize: CGSize = .zero

    private var selectedThisMonthPoint: CumulativeSpendPoint? {
        guard let selectedSpendDay else { return nil }
        return thisMonthPoints.first { $0.day == selectedSpendDay }
    }

    private var selectedLastMonthPoint: CumulativeSpendPoint? {
        guard let selectedSpendDay else { return nil }
        return lastMonthPoints.first { $0.day == selectedSpendDay }
    }

    /// The single point actually highlighted — whichever series
    /// `updateSelection` resolved the touch to, not both at once.
    private var activeSelectedPoint: CumulativeSpendPoint? {
        switch selectedSpendSeries {
        case .thisMonth: selectedThisMonthPoint
        case .lastMonth: selectedLastMonthPoint
        case nil: nil
        }
    }

    /// Matches each series' own line color — appPrimary (blue) for This
    /// Month, secondary (gray) for Last Month — so the highlight dot and
    /// callout are unambiguous about which line they belong to.
    private var activeSelectedColor: Color {
        selectedSpendSeries == .lastMonth ? Color.secondary : Color.appPrimary
    }

    var body: some View {
        GroupBox("Spent This Month") {
            VStack(alignment: .leading, spacing: 12) {
                MaskableCurrencyText(amount: thisMonthPoints.last?.cumulativeAmount ?? 0)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.appPrimary)

                Chart {
                    ForEach(thisMonthPoints) { point in
                        AreaMark(
                            x: .value("Day", point.day),
                            y: .value("Spent", point.cumulativeAmount),
                            series: .value("Series", point.series)
                        )
                        .foregroundStyle(Color.appPrimary.opacity(0.15))

                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Spent", point.cumulativeAmount),
                            series: .value("Series", point.series)
                        )
                        .foregroundStyle(Color.appPrimary)
                    }
                    ForEach(lastMonthPoints) { point in
                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Spent", point.cumulativeAmount),
                            series: .value("Series", point.series)
                        )
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(dash: [4, 4]))
                    }

                    if let selectedSpendDay {
                        RuleMark(x: .value("Day", selectedSpendDay))
                            .foregroundStyle(.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            // No .annotation(...) here — Charts reserves
                            // layout space for a mark annotation and can
                            // shrink the plot area to fit it, which is
                            // exactly the "chart deforms while dragging"
                            // bug: the callout's height changes underneath
                            // the drag (one price row some days, two on
                            // others) and the plot visibly squishes to
                            // match. The callout is rendered as a floating
                            // overlay in .chartOverlay below instead, so it
                            // sits on top of the chart without ever
                            // participating in its layout. The rule line
                            // itself stays — it's still useful to show
                            // *which day* is selected — but only one
                            // series' point gets highlighted on it, not
                            // both: see updateSelection(at:proxy:geometry:).

                        if let activeSelectedPoint {
                            // Background-colored halo behind the dot —
                            // same "ring behind a solid marker" look Health/
                            // Photos use for a selected point — so the
                            // highlight pops off the line it sits on
                            // instead of just being a slightly bigger dot
                            // of the same color.
                            PointMark(
                                x: .value("Day", activeSelectedPoint.day),
                                y: .value("Spent", activeSelectedPoint.cumulativeAmount)
                            )
                            .foregroundStyle(.background)
                            .symbolSize(120)

                            PointMark(
                                x: .value("Day", activeSelectedPoint.day),
                                y: .value("Spent", activeSelectedPoint.cumulativeAmount)
                            )
                            .foregroundStyle(activeSelectedColor)
                            .symbolSize(50)
                        }
                    }
                }
                .frame(height: 200)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .gesture(
                                    // minimumDistance: 0 so a plain tap (no
                                    // movement at all) still reports a location —
                                    // the same recognizer covers both "tap" and
                                    // "drag" from the task's own wording, rather
                                    // than needing a separate TapGesture.
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            updateSelection(at: value.location, proxy: proxy, geometry: geometry)
                                        }
                                        .onEnded { _ in
                                            selectedSpendDay = nil
                                            selectedSpendSeries = nil
                                        }
                                )

                            if let activeSelectedPoint,
                               let anchor = calloutAnchor(for: activeSelectedPoint, proxy: proxy, geometry: geometry) {
                                spendCallout(for: activeSelectedPoint, color: activeSelectedColor)
                                    .fixedSize()
                                    // Reports the bubble's real rendered
                                    // size back into `calloutSize` — the
                                    // `GeometryReader`-in-`.background` +
                                    // `PreferenceKey` version of this tried
                                    // first never actually worked: nested
                                    // inside this deep a modifier chain the
                                    // preference silently never reached the
                                    // `.onPreferenceChange` up on the
                                    // ZStack (confirmed via debug logging
                                    // on-device — calloutSize stayed .zero
                                    // for the entire session). onGeometryChange
                                    // reports directly, no propagation to
                                    // rely on.
                                    .onGeometryChange(for: CGSize.self) { $0.size } action: { calloutSize = $0 }
                                    // .position sets the view's *center*, so
                                    // the bubble's bottom edge — not its
                                    // center — is what needs to sit just
                                    // above the anchor point; hence the
                                    // half-height-plus-spacing offset. X is
                                    // clamped so the bubble never hangs off
                                    // either edge of the chart when the
                                    // touched day is near day 1 or the end
                                    // of the month.
                                    .position(
                                        x: clampedCalloutX(anchor.x, containerWidth: geometry.size.width),
                                        y: anchor.y - calloutSize.height / 2 - 10
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }

                HStack(spacing: 16) {
                    legendItem(color: .appPrimary, label: "This Month")
                    legendItem(color: .secondary, label: "Last Month")
                }
            }
            .padding(.top, 4)
        }
    }

    /// Resolves a touch location (in the chart's own coordinate space) to
    /// the nearest day-of-month — clamped to whichever series actually
    /// reaches furthest right, since Last Month's dashed line commonly
    /// extends past This Month's solid one (a full month vs. only the days
    /// elapsed so far) — and to *which series* the touch is actually
    /// closer to at that day, by comparing the touch's y-position against
    /// each series' resolved y-position rather than always showing both.
    /// When only one series has data at that day, that's an unambiguous
    /// pick regardless of distance; when both do and the touch is
    /// genuinely equidistant (rare — would need the two series to have the
    /// exact same value that day), This Month wins as the deliberate,
    /// deterministic default rather than an arbitrary one.
    ///
    /// Reads `thisMonthPoints`/`lastMonthPoints` directly — they're `let`
    /// parameters computed once by `DetailedDashboardView.computeMetrics()`
    /// and passed in, not computed properties re-deriving from the full
    /// transaction history on every access the way they used to.
    private func updateSelection(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geometry[plotFrame].origin
        let xPosition = location.x - origin.x
        guard let day: Int = proxy.value(atX: xPosition) else { return }
        let maxDay = max(thisMonthPoints.last?.day ?? 1, lastMonthPoints.last?.day ?? 1)
        let clampedDay = min(max(day, 1), maxDay)
        selectedSpendDay = clampedDay

        let thisMonthPoint = thisMonthPoints.first { $0.day == clampedDay }
        let lastMonthPoint = lastMonthPoints.first { $0.day == clampedDay }

        switch (thisMonthPoint, lastMonthPoint) {
        case (nil, nil):
            selectedSpendSeries = nil
        case (.some, nil):
            selectedSpendSeries = .thisMonth
        case (nil, .some):
            selectedSpendSeries = .lastMonth
        case let (.some(thisPoint), .some(lastPoint)):
            let touchY = location.y - origin.y
            guard let thisY = proxy.position(forY: thisPoint.cumulativeAmount),
                  let lastY = proxy.position(forY: lastPoint.cumulativeAmount) else {
                selectedSpendSeries = .thisMonth
                return
            }
            let thisDistance = abs(touchY - thisY)
            let lastDistance = abs(touchY - lastY)
            selectedSpendSeries = lastDistance < thisDistance ? .lastMonth : .thisMonth
        }
    }

    /// Where the callout should float, in the chartOverlay's own
    /// coordinate space — the resolved position of `point`, the single
    /// series `updateSelection` actually picked, not just an x position
    /// pinned to the top of the chart. `proxy.position(forX:/forY:)`
    /// returns plot-area-relative coordinates, so the plot area's own
    /// origin has to be added back in to land in the overlay's coordinate
    /// space.
    private func calloutAnchor(for point: CumulativeSpendPoint, proxy: ChartProxy, geometry: GeometryProxy) -> CGPoint? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        guard let xPosition = proxy.position(forX: point.day),
              let yPosition = proxy.position(forY: point.cumulativeAmount) else { return nil }
        return CGPoint(x: origin.x + xPosition, y: origin.y + yPosition)
    }

    /// Keeps the callout's horizontal center far enough from the chart's
    /// left/right edges that its own width never pushes it off-screen —
    /// relevant near day 1 or the end of the month, where the anchor point
    /// itself sits right at the plot area's edge.
    private func clampedCalloutX(_ x: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let halfWidth = calloutSize.width / 2
        guard halfWidth > 0, halfWidth * 2 < containerWidth else { return x }
        return min(max(x, halfWidth), containerWidth - halfWidth)
    }

    /// Floating callout shown above the highlighted point — which series
    /// it belongs to (dot + "This Month"/"Last Month", from `point.series`
    /// so this can't drift out of sync with the Chart's own series
    /// labels), the day, then that series' cumulative total. Per-series
    /// now, not a combined "both series' values for this day" — matching
    /// the single highlighted point, so the callout never claims a value
    /// for a line the touch wasn't actually resolved to.
    private func spendCallout(for point: CumulativeSpendPoint, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(point.series)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("Day \(point.day)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            MaskableCurrencyText(amount: point.cumulativeAmount)
                .font(.caption2.weight(.semibold))
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    /// Dot + label legend row — same visual shape as InvestmentsView's own
    /// chart legend (a small filled Circle plus a caption label), reused
    /// here for a plain two-item HStack rather than that view's adaptive
    /// grid, since there are always exactly two series to label.
    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        DetailedDashboardView()
    }
    .environment(TabNavigationState())
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              RecurringPayment.self, RecurringOccurrence.self,
              Person.self, LendingEntry.self, Investment.self, InvestmentOccurrence.self,
              CreditCardEMI.self, EMIInstallment.self],
        inMemory: true
    )
}
