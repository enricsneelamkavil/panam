//
//  DashboardView.swift
//  Panam
//

import SwiftUI
import SwiftData
import GoogleSignIn

// Content height (pre-padding) of the two-line summary cards (Accounts,
// Recurring, Loans), applied to single-line cards (Upcoming Dues, Lending,
// Monthly Replay) so all six render at the same total card height.
fileprivate let twoLineCardContentHeight: CGFloat = 44

/// Shared by the Upcoming Dues card and its "See All" list: unpaid,
/// reminder-eligible occurrences that are overdue or due within the next 7
/// days. No lower bound — an overdue dueDate is always <= the window end.
fileprivate func isOverdueOrDueSoon(_ occurrence: RecurringOccurrence) -> Bool {
    guard !occurrence.isPaid,
          let cadence = occurrence.parent?.cadence,
          cadence.reminderEligible
    else { return false }
    let calendar = Calendar.current
    let todayStart = calendar.startOfDay(for: .now)
    guard let windowEnd = calendar.date(byAdding: .day, value: 7, to: todayStart)
    else { return false }
    return calendar.startOfDay(for: occurrence.dueDate) <= windowEnd
}

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
    @Query(sort: \Category.name) private var allCategories: [Category]

    @State private var showingSettings = false
    @State private var showingProfile = false

    @Environment(PrivacyState.self) private var privacyState: PrivacyState?
    @Environment(AuthState.self) private var authState: AuthState?

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
            .filter { $0.type.isExpenseLike && !$0.isExcludedFromFlow }
            .reduce(0) { $0 + $1.amount }
        let refunded = periodTransactions.filter { $0.type == .refund }.reduce(0) { $0 + $1.amount }
        return spent - refunded
    }

    /// Every category with any expense-like spend in the period — .expense
    /// and .taxAndFee alike, as long as a category is actually assigned —
    /// netted against any .refund sharing that same category, the same way
    /// expenseTotal above nets refunds against the aggregate: a full refund
    /// (credit == the original debit) nets the category back to zero, a
    /// partial one (credit == debit − a platform fee) nets it down to just
    /// the fee, with no separate "Fees" category or extra bookkeeping —
    /// the netting arithmetic alone produces that outcome once both
    /// entries share a category, which is exactly what
    /// EmailTransactionParser.matchRefund defaults a matched refund's
    /// category to. This used to only subtract refunds from the period's
    /// overall expenseTotal, leaving a per-category total inflated by
    /// however much of it had actually been refunded.
    /// Uncategorized spend (category == nil) is tracked separately below
    /// instead of being silently dropped or folded into these totals.
    /// Uses `effectiveAmount` (not `amount`) so a split transaction only
    /// counts the user's own portion here — the account balance still moves
    /// by the full `amount`, but a category's "spend" is personal spend.
    private var categoryTotals: [(category: Category, total: Double)] {
        var totals: [Category: Double] = [:]
        for transaction in periodTransactions where !transaction.isExcludedFromFlow {
            guard let category = transaction.category else { continue }
            if transaction.type.isExpenseLike {
                totals[category, default: 0] += transaction.effectiveAmount
            } else if transaction.type == .refund {
                totals[category, default: 0] -= transaction.effectiveAmount
            }
        }
        return totals
            .map { (category: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
    }

    /// Expense-like spend with no category assigned at all (including
    /// uncategorized .taxAndFee), netted against any uncategorized .refund
    /// for the same reason categoryTotals above nets per category — this is
    /// what keeps sum(categoryTotals) + uncategorizedTotal equal to
    /// expenseTotal. Genuinely unattributed, as opposed to simply falling
    /// outside a top-N cutoff. Also uses `effectiveAmount`, for the same
    /// reason as `categoryTotals` above.
    private var uncategorizedTotal: Double {
        let spent = periodTransactions
            .filter { $0.type.isExpenseLike && $0.category == nil && !$0.isExcludedFromFlow }
            .reduce(0) { $0 + $1.effectiveAmount }
        let refunded = periodTransactions
            .filter { $0.type == .refund && $0.category == nil && !$0.isExcludedFromFlow }
            .reduce(0) { $0 + $1.effectiveAmount }
        return spent - refunded
    }

    // MARK: - Dues / lending / balances

    private var upcomingDues: [RecurringOccurrence] {
        occurrences.filter(isOverdueOrDueSoon)
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
    // "spendBar" removed — merged back into "topCategories" (bar + ranked list, one card).
    private static let defaultSectionOrder = [
        "summary", "upcomingDues", "topCategories", "accounts", "lending", "recurring", "loans",
        "monthlyReplay",
    ]

    @AppStorage("dashboardSectionOrder") private var sectionOrderJSON = ""
    @AppStorage("dashboardHiddenSections") private var hiddenSectionsJSON = ""

    private var orderedSectionIDs: [String] {
        let stored = (try? JSONDecoder().decode([String].self, from: Data(sectionOrderJSON.utf8))) ?? []
        // Filter to known ids only (drops stale "netWorth" from old stored orders).
        var order = stored.filter { Self.defaultSectionOrder.contains($0) }
        for id in Self.defaultSectionOrder where !order.contains(id) {
            order.append(id)
        }
        return order
    }

    private var hiddenSectionIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: Data(hiddenSectionsJSON.utf8))) ?? []
    }

    /// Ordered section ids with any user-hidden sections filtered out.
    private var sectionsContent: [String] {
        orderedSectionIDs.filter { !hiddenSectionIDs.contains($0) }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    balanceCard

                    ForEach(sectionsContent, id: \.self) { id in
                        sectionView(for: id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 88) // clear tab bar
            }
            .background(Color(.systemGroupedBackground))
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
                    Button { showingProfile = true } label: {
                        profileToolbarIcon
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
            .sheet(isPresented: $showingProfile) {
                ProfileView()
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

    // MARK: - Card 4: Spending (bar + ranked category list, one card)

    /// Base hues CategoryColorAssigner assigns categories from — Apple's own
    /// system palette, chosen because it's designed to read well as a set.
    /// Not `fileprivate`: CategoryColorAssigner (a separate file) extends
    /// this set with saturation/brightness variants when there are more
    /// categories than base colors. Deliberately excludes gray, which is
    /// reserved for the "Uncategorized" bucket elsewhere so it never gets
    /// confused with a real category's color.
    static let barPalette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .red,
        .yellow, .teal, .indigo, .mint, .cyan, .brown,
    ]

    /// Color for a category's dot/segment across Top Categories, the Spend
    /// Bar, and the full breakdown. Delegates to CategoryColorAssigner,
    /// which assigns every *currently existing* category (not just ones
    /// with spend in the active period — that would make the mapping
    /// depend on which period you happened to be viewing when a category
    /// was first encountered) a guaranteed-unique color for the session,
    /// rather than the old per-name hash lookup, which could put two
    /// categories on the same color (hash collisions mod a 12-color
    /// palette, with dozens of preset categories, were routine).
    private func color(for category: Category) -> Color {
        CategoryColorAssigner.color(for: category, among: allCategories)
    }

    /// Every category with spend in the period, plus a synthetic
    /// "Uncategorized" entry when there's any expense-like spend with no
    /// category assigned — sorted together so the biggest slice (named or
    /// not) leads. This single list drives both the bar and the ranked
    /// list below it, so the two can't drift out of sync with each other.
    private var spendEntries: [SpendEntry] {
        var entries = categoryTotals.map {
            SpendEntry(
                id: $0.category.name,
                name: $0.category.name,
                total: $0.total,
                color: color(for: $0.category)
            )
        }
        if uncategorizedTotal > 0 {
            entries.append(SpendEntry(id: "uncategorized", name: "Uncategorized", total: uncategorizedTotal, color: .gray))
        }
        return entries.sorted { $0.total > $1.total }
    }

    private var spendSegments: [(id: String, color: Color, share: Double)] {
        // Shares are computed against the sum of everything actually
        // displayed (every category + Uncategorized), so the bar always
        // fills edge-to-edge with no leftover gap and no generic catch-all
        // swallowing more than one category's spend.
        let displayedTotal = spendEntries.reduce(0) { $0 + $1.total }
        guard displayedTotal > 0 else { return [] }
        return spendEntries.map { (id: $0.id, color: $0.color, share: $0.total / displayedTotal) }
    }

    /// Bar (larger, edge-to-edge, no legend) + ranked category list below it,
    /// in a single card — the original combined layout, reunited. Every bar
    /// segment corresponds to a real, named category (or "Uncategorized"
    /// for genuinely unassigned spend) — the list is capped at 5 inline
    /// with "See All" for the rest, but draws from the same `spendEntries`
    /// as the bar so the two never disagree.
    private var topCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Spends")
                .font(.headline)

            if spendSegments.isEmpty {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 28)
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
                .frame(height: 28)
                .clipShape(Capsule())
            }

            if spendEntries.isEmpty {
                Text("No spending yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(spendEntries.prefix(5)) { entry in
                    CategoryTotalRow(
                        name: entry.name,
                        total: entry.total,
                        share: entry.total / (spendEntries.first?.total ?? 1),
                        color: entry.color
                    )
                }
            }

            if spendEntries.count > 5 {
                NavigationLink("See All") {
                    CategoryBreakdownView(entries: spendEntries)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .center)
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

    // MARK: - Toolbar: profile icon

    /// The signed-in Google account's actual photo when available — plain
    /// person-circle for Guest mode, or if the image never loads. Small
    /// fixed size matching the other toolbar icons' visual footprint, circle-
    /// cropped like ProfileView's own header photo.
    @ViewBuilder
    private var profileToolbarIcon: some View {
        if authState?.authMode == .google,
           let url = GIDSignIn.sharedInstance.currentUser?.profile?.imageURL(withDimension: 64) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle")
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(Circle())
            .accessibilityLabel("Profile")
        } else {
            Label("Profile", systemImage: "person.crop.circle")
        }
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

/// A single row of spend data for the bar + ranked list below it — either a
/// real category or the synthetic "Uncategorized" bucket for expense-like
/// transactions with no category assigned. Both the Top Categories card and
/// the full breakdown are driven from arrays of this type so they can't
/// drift apart.
private struct SpendEntry: Identifiable {
    let id: String
    let name: String
    let total: Double
    let color: Color
}

/// Full category breakdown (including "Uncategorized", when present),
/// pushed from Top Categories "See All".
private struct CategoryBreakdownView: View {
    let entries: [SpendEntry]

    var body: some View {
        List {
            ForEach(entries) { entry in
                CategoryTotalRow(
                    name: entry.name,
                    total: entry.total,
                    share: entry.total / (entries.first?.total ?? 1),
                    color: entry.color
                )
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Overdue + due-within-7-days recurring occurrences, pushed from Upcoming Dues "See All".
private struct UpcomingDuesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringOccurrence.dueDate) private var occurrences: [RecurringOccurrence]
    @State private var occurrenceToPay: RecurringOccurrence?

    private var unpaidOccurrences: [RecurringOccurrence] {
        occurrences.filter(isOverdueOrDueSoon)
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
    let name: String
    let total: Double
    let share: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(name)
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
