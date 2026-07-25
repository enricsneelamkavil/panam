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
    @Query private var allEMIs: [CreditCardEMI]

    @State private var showingEditSheet = false
    @State private var showingAddEMISheet = false
    @State private var paymentTypeToRecord: CardPaymentType?

    private static let currencyFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    /// Expense transactions on this card.
    private var cardExpenses: [Transaction] {
        allTransactions.filter { $0.account === account && $0.type == .expense }
    }

    /// This card's active EMIs.
    private var cardEMIs: [CreditCardEMI] {
        allEMIs.filter { $0.account === account && $0.isActive }
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

    /// The due date paired with a given statement date: if the due day falls
    /// earlier in the month than the statement day, the bill is due the
    /// month after the statement's month; otherwise it's due that same month.
    private func dueDate(afterStatement statementDate: Date, statementDay: Int, dueDay: Int) -> Date? {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month], from: statementDate)
        components.day = dueDay
        if dueDay < statementDay {
            components.month = (components.month ?? 1) + 1
        }
        return calendar.date(from: components)
    }

    private var nextStatementDate: Date? {
        account.statementDay.flatMap(upcomingDate)
    }

    /// Start of the current (most recently closed) statement period.
    private var previousStatementDate: Date? {
        guard let statementDay = account.statementDay, let next = nextStatementDate else { return nil }
        return Calendar.current.nextDate(
            after: next,
            matching: DateComponents(day: statementDay),
            matchingPolicy: .nextTime,
            direction: .backward
        )
    }

    /// The bill currently owed: due date paired with the current statement period.
    private var outstandingDueDate: Date? {
        guard let statementDay = account.statementDay,
              let dueDay = account.dueDay,
              let previousStatementDate
        else { return nil }
        return dueDate(afterStatement: previousStatementDate, statementDay: statementDay, dueDay: dueDay)
    }

    private var isOutstandingOverdue: Bool {
        guard let outstandingDueDate else { return false }
        return outstandingDueDate < Calendar.current.startOfDay(for: .now)
    }

    /// Current statement period: previous statement date up to the next one.
    private var statementPeriod: ClosedRange<Date>? {
        guard let previousStatementDate, let nextStatementDate else { return nil }
        return previousStatementDate...nextStatementDate
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

            if outstandingDueDate != nil || nextStatementDate != nil {
                Section("Upcoming") {
                    if let outstandingDueDate {
                        LabeledContent("Payment Due") {
                            Text(outstandingDueDate, format: .dateTime.day().month(.abbreviated).year())
                                .foregroundStyle(isOutstandingOverdue ? .red : .primary)
                        }
                    }
                    if let nextStatementDate {
                        LabeledContent("Next Statement") {
                            Text(nextStatementDate, format: .dateTime.day().month(.abbreviated).year())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                if cardEMIs.isEmpty {
                    Text("No EMIs on this card.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cardEMIs) { emi in
                        NavigationLink {
                            EMIDetailView(emi: emi)
                        } label: {
                            EMIRow(emi: emi)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("EMIs")
                    Spacer()
                    Button {
                        showingAddEMISheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
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
                Menu {
                    Button("Bill Payment") { paymentTypeToRecord = .billPayment }
                    Button("Cash Advance") { paymentTypeToRecord = .cashAdvance }
                } label: {
                    Label("Record Payment", systemImage: "creditcard.and.123")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    showingEditSheet = true
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            AddEditAccountView(account: account)
        }
        .sheet(isPresented: $showingAddEMISheet) {
            AddEditEMIView(account: account)
        }
        .sheet(item: $paymentTypeToRecord) { type in
            AddCardPaymentView(type: type, card: account)
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

private struct EMIRow: View {
    let emi: CreditCardEMI

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(emi.name)
                Text("\(emi.paidCount) of \(emi.tenureMonths) paid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(emi.remainingAmount, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                .font(.subheadline.monospacedDigit())
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
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              CreditCardEMI.self, EMIInstallment.self, CardPayment.self],
        inMemory: true
    )
}
