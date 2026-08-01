//
//  DashboardView.swift
//  Panam
//

import SwiftUI
import SwiftData

// Content height (pre-padding) of the two-line summary cards (Accounts,
// Recurring, Loans), applied to single-line cards (Upcoming Dues, Lending,
// Monthly Replay) so all six render at the same total card height.
fileprivate let twoLineCardContentHeight: CGFloat = 44

// Shared card surface applied to every dashboard tile.
extension View {
    func dashboardCard() -> some View {
        padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
    }
}

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \RecurringOccurrence.dueDate) private var occurrences: [RecurringOccurrence]
    @Query private var accounts: [Account]
    @Query private var recurringPayments: [RecurringPayment]
    @Query private var loans: [Loan]

    @State private var showingChat = false
    @State private var showingSettings = false
    @State private var showingReorder = false

    @Environment(PrivacyState.self) private var privacyState: PrivacyState?

    // MARK: - Summary period

    private enum SummaryPeriod: String, CaseIterable {
        case salaryCycle = "Salary Cycle"
        case monthly = "Monthly"
        case custom = "Custom"
    }

    @AppStorage(AppSettings.salaryDayKey)
    private var salaryDay = AppSettings.salaryDayDefault

    @AppStorage(AppSettings.salaryDayModeKey)
    private var salaryDayMode = AppSettings.salaryDayModeDefault

    private var resolvedSalaryDay: Int {
        switch salaryDayMode {
        case "last":
            return Calendar.current.range(of: .day, in: .month, for: .now)?.count ?? 31
        case "custom":
            return min(max(salaryDay, 1), 31)
        default:
            return 1
        }
    }

    @State private var period: SummaryPeriod = .salaryCycle
    @State private var customStart: Date =
        Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var customEnd: Date = .now

    private var activeInterval: DateInterval {
        let calendar = Calendar.current
        let now = Date.now
        switch period {
        case .salaryCycle:
            let day = resolvedSalaryDay
            var components = calendar.dateComponents([.year, .month], from: now)
            components.day = day
            var start = calendar.date(from: components) ?? now
            if calendar.component(.day, from: now) < day {
                start = calendar.date(byAdding: .month, value: -1, to: start) ?? start
            }
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
            return DateInterval(start: calendar.startOfDay(for: start), end: end)
        case .monthly:
            return calendar.dateInterval(of: .month, for: now)
                ?? DateInterval(start: now, duration: 0)
        case .custom:
            let start = calendar.startOfDay(for: customStart)
            let endDay = calendar.startOfDay(for: customEnd)
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return DateInterval(start: start, end: max(start, end))
        }
    }

    private var periodTransactions: [Transaction] {
        let interval = activeInterval
        return transactions.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    /// Income-like transactions, excluding refund — a refund reduces Expense instead of adding to Income.
    private var incomeTotal: Double {
        periodTransactions
            .filter { $0.type.isIncomeLike && $0.type != .refund && !$0.isLendingRepayment }
            .reduce(0) { $0 + $1.amount }
    }

    /// .expense + .taxAndFee, netted against refunds.
    private var expenseTotal: Double {
        let spent = periodTransactions
            .filter { $0.type.isExpenseLike && !$0.isLendingRepayment }
            .reduce(0) { $0 + $1.amount }
        let refunded = periodTransactions.filter { $0.type == .refund }.reduce(0) { $0 + $1.amount }
        return spent - refunded
    }

    private var categoryTotals: [(category: Category, total: Double)] {
        let expenses = periodTransactions.filter { $0.type == .expense && $0.category != nil }
        let groups = Dictionary(grouping: expenses) { $0.category! }
        return groups
            .map { (category: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
    }

    // MARK: - Dues / lending / balances

    private var upcomingDues: [RecurringOccurrence] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        guard let windowEnd = calendar.date(byAdding: .day, value: 3, to: todayStart)
        else { return [] }

        return occurrences.filter { occurrence in
            guard !occurrence.isPaid,
                  let cadence = occurrence.parent?.cadence,
                  cadence.reminderEligible
            else { return false }
            return calendar.startOfDay(for: occurrence.dueDate) <= windowEnd
        }
    }

    private var totalBalance: Double {
        accounts.filter { $0.type != .creditCard }.reduce(0) { $0 + $1.balance }
    }

    private var creditCardDue: Double {
        accounts.filter { $0.type == .creditCard }.reduce(0) { $0 + $1.balance }
    }

    private var totalBalance7DaysAgo: Double {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)
        else { return totalBalance }
        var value = totalBalance
        for transaction in transactions where transaction.date > cutoff {
            guard let account = transaction.account, account.type != .creditCard else { continue }
            value -= transaction.type == .income ? transaction.amount : -transaction.amount
        }
        return value
    }

    private var sevenDayChangePercent: Double? {
        let past = totalBalance7DaysAgo
        guard past != 0 else { return nil }
        return (totalBalance - past) / abs(past) * 100
    }

    // MARK: - Section ordering

    // "netWorth" removed — net worth is now shown directly in the pinned balance card.
    private static let defaultSectionOrder = [
        "summary", "upcomingDues", "spendBar", "topCategories", "accounts", "lending", "recurring", "loans",
        "monthlyReplay",
    ]

    @AppStorage("dashboardSectionOrder") private var sectionOrderJSON = ""

    private var orderedSectionIDs: [String] {
        let stored = (try? JSONDecoder().decode([String].self, from: Data(sectionOrderJSON.utf8))) ?? []
        // Filter to known ids only (drops stale "netWorth" from old stored orders).
        var order = stored.filter { Self.defaultSectionOrder.contains($0) }
        for id in Self.defaultSectionOrder where !order.contains(id) {
            order.append(id)
        }
        return order
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    balanceCard

                    ForEach(orderedSectionIDs, id: \.self) { id in
                        sectionView(for: id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 88) // clear chat FAB + tab bar
            }
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .bottomTrailing) {
                chatButton
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        privacyState?.amountsHidden.toggle()
                    } label: {
                        Label(
                            privacyState?.amountsHidden == true ? "Show Amounts" : "Hide Amounts",
                            systemImage: privacyState?.amountsHidden == true ? "eye.slash.fill" : "eye.fill"
                        )
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingReorder = true } label: {
                        Label("Reorder Sections", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingReorder) {
                DashboardReorderView()
            }
            .sheet(isPresented: $showingChat) {
                FinanceChatView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Card 1: Balance (pinned, always first)

    private var balanceCard: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Total Balance")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                MaskableCurrencyText(amount: totalBalance)
                    .font(.largeTitle.bold().monospacedDigit())
                if let change = sevenDayChangePercent {
                    Text(String(format: "%+.1f%% past 7 days", change))
                        .font(.caption)
                        .foregroundStyle(change >= 0 ? .green : .red)
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            HStack {
                Text("Credit Card Due")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                MaskableCurrencyText(amount: creditCardDue)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(creditCardDue > 0 ? .red : .secondary)
            }
        }
        .dashboardCard()
    }

    // MARK: - Section dispatcher

    @ViewBuilder
    private func sectionView(for id: String) -> some View {
        switch id {
        case "summary":      summarySection
        case "upcomingDues": upcomingDuesSection
        case "spendBar":     spendBarSection
        case "topCategories": topCategoriesSection
        case "accounts":     accountsSection
        case "lending":      lendingSection
        case "recurring":    recurringSection
        case "loans":        loansSection
        case "monthlyReplay": monthlyReplaySection
        default:             EmptyView()
        }
    }

    // MARK: - Card 2: Summary (period picker + income/expense/net)

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.headline)

            Picker("Summary Period", selection: $period) {
                ForEach(SummaryPeriod.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)

            if period == .custom {
                DatePicker("From", selection: $customStart, displayedComponents: .date)
                DatePicker("To", selection: $customEnd, displayedComponents: .date)
            }

            HStack {
                statColumn(title: "Income", amount: incomeTotal, color: .green)
                Divider()
                statColumn(title: "Expense", amount: expenseTotal, color: .red)
            }

            Divider()

            HStack {
                Text("Net")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                MaskableCurrencyText(amount: incomeTotal - expenseTotal)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(incomeTotal - expenseTotal >= 0 ? .green : .red)
            }
        }
        .dashboardCard()
    }

    // MARK: - Card 3: Upcoming Dues

    private var upcomingDuesSection: some View {
        NavigationLink {
            UpcomingDuesListView()
        } label: {
            HStack {
                Text("Upcoming Dues")
                    .font(.headline)
                    .foregroundStyle(.primary)

                if upcomingDues.count > 0 {
                    Text("\(upcomingDues.count)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.appPrimary, in: Circle())
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(height: twoLineCardContentHeight)
        }
        .buttonStyle(.plain)
        .dashboardCard()
    }

    // MARK: - Card 4: Spend Bar

    fileprivate static let barPalette: [Color] = [.blue, .green, .orange, .purple, .pink]

    private var spendSegments: [(id: String, color: Color, share: Double)] {
        guard expenseTotal > 0 else { return [] }
        var segments: [(id: String, color: Color, share: Double)] = []
        for (index, entry) in categoryTotals.prefix(5).enumerated() {
            segments.append((
                id: entry.category.name,
                color: Self.barPalette[index % Self.barPalette.count],
                share: entry.total / expenseTotal
            ))
        }
        let covered = segments.reduce(0) { $0 + $1.share }
        if covered < 0.999 {
            segments.append((id: "other", color: .gray, share: 1 - covered))
        }
        return segments
    }

    private var spendBarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spending")
                    .font(.headline)
                Spacer()
                MaskableCurrencyText(amount: expenseTotal)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if spendSegments.isEmpty {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 20)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(spendSegments, id: \.id) { segment in
                            Rectangle()
                                .fill(segment.color)
                                .frame(width: max(geometry.size.width * segment.share - 2, 2))
                        }
                    }
                }
                .frame(height: 20)
                .clipShape(Capsule())
            }
        }
        .dashboardCard()
    }

    // MARK: - Card 5: Top Categories

    private var topCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Top Categories")
                    .font(.headline)
                Spacer()
                if categoryTotals.count > 5 {
                    NavigationLink("See All") {
                        CategoryBreakdownView(totals: categoryTotals)
                    }
                    .font(.subheadline)
                }
            }

            if categoryTotals.isEmpty {
                Text("No spending yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(categoryTotals.prefix(5).enumerated()), id: \.element.category.persistentModelID) { index, entry in
                    CategoryTotalRow(
                        category: entry.category,
                        total: entry.total,
                        share: entry.total / (categoryTotals.first?.total ?? 1),
                        color: Self.barPalette[index % Self.barPalette.count]
                    )
                }
            }
        }
        .dashboardCard()
    }

    // MARK: - Card 6: Accounts

    private var accountsSection: some View {
        NavigationLink {
            AccountsView()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accounts")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .dashboardCard()
    }

    // MARK: - Card 7: Lending

    private var lendingSection: some View {
        NavigationLink {
            LendingLedgerView()
        } label: {
            HStack {
                Text("Lending")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(height: twoLineCardContentHeight)
        }
        .buttonStyle(.plain)
        .dashboardCard()
    }

    // MARK: - Card 8: Recurring

    private var activeRecurringCount: Int {
        recurringPayments.filter { $0.isActive }.count
    }

    private var recurringSection: some View {
        NavigationLink {
            RecurringView()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recurring")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(activeRecurringCount) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .dashboardCard()
    }

    // MARK: - Card 9: Loans

    private var activeLoansCount: Int {
        loans.filter(\.isActive).count
    }

    private var loansSection: some View {
        NavigationLink {
            LoansView()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loans")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(activeLoansCount) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .dashboardCard()
    }

    // MARK: - Card 10: Monthly Replay

    private var monthlyReplaySection: some View {
        NavigationLink {
            MonthlyReplayView()
        } label: {
            HStack {
                Text("Monthly Replay")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(height: twoLineCardContentHeight)
        }
        .buttonStyle(.plain)
        .dashboardCard()
    }

    // MARK: - Chat FAB

    private var chatButton: some View {
        Button {
            showingChat = true
        } label: {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.appPrimary, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel("Ask Panam")
    }

    private func statColumn(title: String, amount: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            MaskableCurrencyText(amount: amount)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Supporting views

/// Full category breakdown, pushed from Top Categories "See All".
private struct CategoryBreakdownView: View {
    let totals: [(category: Category, total: Double)]

    var body: some View {
        List {
            ForEach(Array(totals.enumerated()), id: \.element.category.persistentModelID) { index, entry in
                CategoryTotalRow(
                    category: entry.category,
                    total: entry.total,
                    share: entry.total / (totals.first?.total ?? 1),
                    color: DashboardView.barPalette[index % DashboardView.barPalette.count]
                )
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// All unpaid/overdue recurring occurrences, pushed from Upcoming Dues "See All".
private struct UpcomingDuesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringOccurrence.dueDate) private var occurrences: [RecurringOccurrence]
    @State private var occurrenceToPay: RecurringOccurrence?

    private var unpaidOccurrences: [RecurringOccurrence] {
        occurrences.filter {
            !$0.isPaid && ($0.parent?.cadence.reminderEligible ?? false)
        }
    }

    var body: some View {
        List {
            if unpaidOccurrences.isEmpty {
                Text("All caught up — nothing pending.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(unpaidOccurrences) { occurrence in
                    Button {
                        occurrenceToPay = occurrence
                    } label: {
                        UpcomingDueRow(occurrence: occurrence)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                NavigationLink {
                    FutureView()
                } label: {
                    Text("View Full 12-Month Outlook")
                }
            }
        }
        .navigationTitle("Upcoming Dues")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $occurrenceToPay) { occurrence in
            PaymentConfirmationSheet(
                title: "Mark as Paid",
                dueDate: occurrence.dueDate,
                expectedAmount: occurrence.expectedAmount
            ) { actual in
                occurrence.markPaid(actualAmount: actual, context: modelContext)
            }
            .presentationDetents([.medium])
        }
    }
}

private struct UpcomingDueRow: View {
    let occurrence: RecurringOccurrence

    private var daysUntilDue: Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: occurrence.dueDate)
        ).day ?? 0
    }

    private var dueLabel: String {
        switch daysUntilDue {
        case ..<0: "Overdue by \(-daysUntilDue) day\(daysUntilDue == -1 ? "" : "s")"
        case 0:    "Due today"
        case 1:    "Due tomorrow"
        default:   "Due in \(daysUntilDue) days"
        }
    }

    private var dueColor: Color? {
        switch daysUntilDue {
        case ..<0:  .red
        case 0, 1: .orange
        default:    nil
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.parent?.name ?? "Recurring Payment")
                Text(dueLabel)
                    .font(.caption)
                    .foregroundStyle(dueColor ?? .secondary)
            }
            Spacer()
            MaskableCurrencyText(amount: occurrence.expectedAmount)
                .font(.subheadline.monospacedDigit())
        }
        .contentShape(Rectangle())
    }
}

private struct CategoryTotalRow: View {
    let category: Category
    let total: Double
    let share: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(category.name)
                Spacer()
                MaskableCurrencyText(amount: total)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                Capsule()
                    .fill(color.opacity(0.35))
                    .frame(width: max(geometry.size.width * share, 4))
            }
            .frame(height: 5)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    DashboardView()
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
