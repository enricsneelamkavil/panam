// MonthlyReplayView.swift
// Panam

import SwiftUI
import SwiftData

struct MonthlyReplayView: View {
    @Query(sort: \Transaction.date) private var transactions: [Transaction]
    @Query(sort: \MoneyEvent.date) private var allMoneyEvents: [MoneyEvent]
    @Query private var accounts: [Account]
    @Query private var recurringPayments: [RecurringPayment]

    @State private var selectedMonth: Date = {
        let cal = Calendar.current
        guard let currentStart = cal.dateInterval(of: .month, for: .now)?.start,
              let last = cal.date(byAdding: .month, value: -1, to: currentStart)
        else { return .now }
        return last
    }()

    private var calendar: Calendar { .current }

    private var monthInterval: DateInterval? {
        calendar.dateInterval(of: .month, for: selectedMonth)
    }

    private var isAtLastCompletedMonth: Bool {
        guard let currentStart = calendar.dateInterval(of: .month, for: .now)?.start,
              let lastStart = calendar.date(byAdding: .month, value: -1, to: currentStart)
        else { return true }
        return selectedMonth >= lastStart
    }

    // MARK: - Month-scoped events

    private var monthEvents: [MoneyEvent] {
        guard let interval = monthInterval else { return [] }
        return allMoneyEvents.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    // MARK: - Income

    private var incomeEvents: [MoneyEvent] {
        monthEvents
            .filter { $0.type == .income || $0.type == .interest || $0.type == .dividend }
            .sorted { $0.amount > $1.amount }
    }

    private var totalIncome: Double { incomeEvents.reduce(0) { $0 + $1.amount } }

    private func incomeItemLabel(for event: MoneyEvent) -> String {
        let note = event.note
        if !note.isEmpty, recurringPayments.contains(where: { $0.isIncome && $0.name == note }) {
            return "Salary: \(note)"
        }
        switch event.type {
        case .interest: return "Interest"
        case .dividend: return "Dividend"
        default: return note.isEmpty ? "Income" : note
        }
    }

    // MARK: - Major Purchases

    private var majorPurchases: [MoneyEvent] {
        monthEvents
            .filter { $0.type == .expense || $0.type == .creditCardPurchase || $0.type == .splitExpense }
            .sorted { $0.amount > $1.amount }
    }

    private var totalPurchases: Double { majorPurchases.reduce(0) { $0 + $1.amount } }

    private func purchaseTitle(for event: MoneyEvent) -> String {
        if let merchant = event.merchant, !merchant.isEmpty { return merchant }
        if !event.note.isEmpty { return event.note }
        return event.category?.name ?? "Purchase"
    }

    // MARK: - Investments

    private var investmentEvents: [MoneyEvent] { monthEvents.filter { $0.type == .investment } }
    private var totalInvested: Double { investmentEvents.reduce(0) { $0 + $1.amount } }

    private var investmentsByInstrument: [(name: String, total: Double)] {
        let groups = Dictionary(grouping: investmentEvents) { $0.note.isEmpty ? "Investment" : $0.note }
        return groups
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
    }

    // MARK: - Bills

    private static let billTypes: Set<MoneyEventType> = [
        .subscription, .insurancePremium, .emi, .loan, .creditCardPayment
    ]

    private var billEvents: [MoneyEvent] { monthEvents.filter { Self.billTypes.contains($0.type) } }
    private var totalBills: Double { billEvents.reduce(0) { $0 + $1.amount } }

    private var billsByType: [(typeName: String, total: Double)] {
        let groups = Dictionary(grouping: billEvents) { billTypeName($0.type) }
        return groups
            .map { (typeName: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
    }

    private func billTypeName(_ type: MoneyEventType) -> String {
        switch type {
        case .subscription:      return "Subscriptions"
        case .insurancePremium:  return "Insurance"
        case .emi:               return "EMIs"
        case .loan:              return "Loan EMIs"
        case .creditCardPayment: return "Card Payments"
        default:                 return "Other"
        }
    }

    // MARK: - Savings

    private var savings: Double { totalIncome - totalPurchases - totalBills - totalInvested }

    // MARK: - Net Worth Change

    private func netWorth(at cutoff: Date) -> Double {
        var bankCash = accounts.filter { $0.type != .creditCard }.reduce(0) { $0 + $1.balance }
        var creditCard = accounts.filter { $0.type == .creditCard }.reduce(0) { $0 + $1.balance }

        for tx in transactions where tx.date > cutoff {
            if tx.type.isTransferLike {
                if let from = tx.account {
                    switch from.type {
                    case .bank, .cash, .wallet: bankCash += tx.amount
                    case .creditCard: creditCard -= tx.amount
                    }
                }
                if let to = tx.toAccount {
                    switch to.type {
                    case .bank, .cash, .wallet: bankCash -= tx.amount
                    case .creditCard: creditCard += tx.amount
                    }
                }
            } else if tx.type == .adjustment {
                guard let account = tx.account else { continue }
                switch account.type {
                case .bank, .cash, .wallet: bankCash -= tx.amount
                case .creditCard: creditCard -= tx.amount
                }
            } else {
                guard let account = tx.account else { continue }
                switch account.type {
                case .bank, .cash, .wallet:
                    bankCash -= tx.type.isIncomeLike ? tx.amount : -tx.amount
                case .creditCard:
                    creditCard -= tx.type.isIncomeLike ? -tx.amount : tx.amount
                }
            }
        }
        return bankCash - creditCard
    }

    private var netWorthAtStart: Double {
        guard let interval = monthInterval else { return 0 }
        return netWorth(at: interval.start)
    }

    private var netWorthAtEnd: Double {
        guard let interval = monthInterval else { return 0 }
        return netWorth(at: interval.end)
    }

    private var netWorthMonthlyChange: Double { netWorthAtEnd - netWorthAtStart }

    // MARK: - Key Insights

    private var spendPaceInsight: String? {
        guard let interval = monthInterval else { return nil }
        let thisTotal = totalPurchases + totalBills

        var trailing: [Double] = []
        for i in 1...3 {
            guard let prevDate = calendar.date(byAdding: .month, value: -i, to: interval.start),
                  let prevInterval = calendar.dateInterval(of: .month, for: prevDate)
            else { continue }
            let prevTotal = allMoneyEvents
                .filter {
                    $0.date >= prevInterval.start && $0.date < prevInterval.end
                        && ($0.type == .expense || $0.type == .creditCardPurchase
                            || $0.type == .splitExpense || Self.billTypes.contains($0.type))
                }
                .reduce(0) { $0 + $1.amount }
            trailing.append(prevTotal)
        }
        guard !trailing.isEmpty else { return nil }
        let avg = trailing.reduce(0, +) / Double(trailing.count)
        guard avg > 0 else { return nil }

        let ratio = thisTotal / avg
        if ratio > 1.2 {
            return "Total spend was \(Int((ratio - 1) * 100))% above the 3-month average — a high-spend month."
        } else if ratio < 0.8 {
            return "Total spend was \(Int((1 - ratio) * 100))% below the 3-month average — a lean month."
        } else {
            return "Total spend was in line with the 3-month average."
        }
    }

    private var topCategoryChangeInsight: String? {
        guard let interval = monthInterval,
              let prevDate = calendar.date(byAdding: .month, value: -1, to: interval.start),
              let prevInterval = calendar.dateInterval(of: .month, for: prevDate)
        else { return nil }

        let isExpense: (MoneyEvent) -> Bool = {
            $0.type == .expense || $0.type == .creditCardPurchase || $0.type == .splitExpense
        }

        let thisRanked = Dictionary(grouping: monthEvents.filter(isExpense)) { $0.category?.name ?? "Uncategorized" }
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }

        guard let top = thisRanked.first else { return nil }

        let prevTotal = allMoneyEvents
            .filter {
                $0.date >= prevInterval.start && $0.date < prevInterval.end
                    && isExpense($0) && $0.category?.name == top.name
            }
            .reduce(0) { $0 + $1.amount }

        if prevTotal == 0 {
            return "\(top.name) was the top spending category, with no comparable spend the prior month."
        }
        let pct = (top.total - prevTotal) / prevTotal * 100
        if abs(pct) < 5 {
            return "\(top.name) was the top spending category, roughly flat vs. the prior month."
        } else if pct > 0 {
            return "\(top.name) was the top spending category — up \(Int(pct))% from last month."
        } else {
            return "\(top.name) was the top spending category — down \(Int(abs(pct)))% from last month."
        }
    }

    private var unnecessarySubscriptionInsight: String? {
        let unnecessary = recurringPayments.filter {
            $0.isSubscription && $0.isActive && $0.isNecessary == false
        }
        guard !unnecessary.isEmpty else { return nil }
        let listed = unnecessary.prefix(2).map(\.name).joined(separator: " and ")
        let more = unnecessary.count > 2 ? " (+\(unnecessary.count - 2) more)" : ""
        let verb = unnecessary.count == 1 ? "is a non-essential subscription" : "are non-essential subscriptions"
        return "\(listed)\(more) \(verb) still active."
    }

    private var insights: [String] {
        [spendPaceInsight, topCategoryChangeInsight, unnecessarySubscriptionInsight].compactMap { $0 }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                monthNavigator
                incomeCard
                purchasesCard
                investmentsCard
                billsCard
                savingsCard
                netWorthCard
                insightsCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Monthly Replay")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Month Navigator

    private var monthNavigator: some View {
        HStack {
            Button {
                if let prev = calendar.date(byAdding: .month, value: -1, to: selectedMonth) {
                    selectedMonth = prev
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.appPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }

            Spacer()

            Text(selectedMonth, format: .dateTime.month(.wide).year())
                .font(.headline)

            Spacer()

            Button {
                guard !isAtLastCompletedMonth,
                      let next = calendar.date(byAdding: .month, value: 1, to: selectedMonth)
                else { return }
                selectedMonth = next
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isAtLastCompletedMonth ? Color(.tertiaryLabel) : Color.appPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(isAtLastCompletedMonth)
        }
        .dashboardCard()
    }

    // MARK: - Income Card

    private var incomeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Income", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                MaskableCurrencyText(amount: totalIncome)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.green)
            }

            if incomeEvents.isEmpty {
                Text("No income recorded for this month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(incomeEvents.prefix(2).enumerated()), id: \.offset) { _, event in
                    HStack {
                        Text(incomeItemLabel(for: event))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        MaskableCurrencyText(amount: event.amount)
                            .font(.subheadline.monospacedDigit())
                    }
                }
                if incomeEvents.count > 2 {
                    Text("+ \(incomeEvents.count - 2) more source\(incomeEvents.count - 2 == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .dashboardCard()
    }

    // MARK: - Purchases Card

    private var purchasesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Major Purchases", systemImage: "bag.fill")
                    .font(.headline)
                Spacer()
                MaskableCurrencyText(amount: totalPurchases)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if majorPurchases.isEmpty {
                Text("No purchases recorded for this month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(majorPurchases.prefix(5).enumerated()), id: \.offset) { _, event in
                    HStack(spacing: 10) {
                        Image(systemName: event.category?.icon ?? "bag")
                            .foregroundStyle(.tint)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(purchaseTitle(for: event))
                                .font(.subheadline)
                                .lineLimit(1)
                            if let catName = event.category?.name {
                                Text(catName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        MaskableCurrencyText(amount: event.amount)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                }
                if majorPurchases.count > 5 {
                    Text("+ \(majorPurchases.count - 5) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .dashboardCard()
    }

    // MARK: - Investments Card

    private var investmentsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Investments", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Spacer()
                MaskableCurrencyText(amount: totalInvested)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if investmentEvents.isEmpty {
                Text("No investments recorded for this month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if investmentsByInstrument.count > 1 {
                ForEach(investmentsByInstrument, id: \.name) { entry in
                    HStack {
                        Text(entry.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        MaskableCurrencyText(amount: entry.total)
                            .font(.subheadline.monospacedDigit())
                    }
                }
            }
        }
        .dashboardCard()
    }

    // MARK: - Bills Card

    private var billsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Bills & Commitments", systemImage: "calendar.badge.checkmark")
                    .font(.headline)
                Spacer()
                MaskableCurrencyText(amount: totalBills)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if billEvents.isEmpty {
                Text("No bills recorded for this month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(billsByType, id: \.typeName) { entry in
                    HStack {
                        Text(entry.typeName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        MaskableCurrencyText(amount: entry.total)
                            .font(.subheadline.monospacedDigit())
                    }
                }
            }
        }
        .dashboardCard()
    }

    // MARK: - Savings Card

    private var savingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Savings", systemImage: "banknote")
                    .font(.headline)
                    .foregroundStyle(savings >= 0 ? Color.green : Color.red)
                Spacer()
                MaskableCurrencyText(amount: abs(savings))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(savings >= 0 ? Color.green : Color.red)
            }

            Text("Income − Purchases − Bills − Investments (approximate)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            savingsRow("Income", totalIncome)
            savingsRow("Purchases", totalPurchases, minus: true)
            savingsRow("Bills", totalBills, minus: true)
            savingsRow("Investments", totalInvested, minus: true)
        }
        .dashboardCard()
    }

    private func savingsRow(_ label: String, _ amount: Double, minus: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 2) {
                if minus {
                    Text("−")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                MaskableCurrencyText(amount: amount)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Net Worth Card

    private var netWorthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Net Worth Change", systemImage: "arrow.up.arrow.down.circle.fill")
                    .font(.headline)
                Spacer()
                MaskableCurrencyText(amount: netWorthMonthlyChange)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(netWorthMonthlyChange >= 0 ? Color.green : Color.red)
            }

            HStack {
                Text("Start of month")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                MaskableCurrencyText(amount: netWorthAtStart)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("End of month")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                MaskableCurrencyText(amount: netWorthAtEnd)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .dashboardCard()
    }

    // MARK: - Key Insights Card

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Key Insights", systemImage: "lightbulb.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            if insights.isEmpty {
                Text("Add more transaction data to see insights.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        Text(insight)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .dashboardCard()
    }
}

#Preview {
    NavigationStack {
        MonthlyReplayView()
    }
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              MoneyEvent.self, RecurringPayment.self, RecurringOccurrence.self],
        inMemory: true
    )
}
