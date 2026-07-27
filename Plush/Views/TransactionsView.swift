// TransactionsView.swift
// Plush

import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var occurrences: [RecurringOccurrence]
    @Query private var investmentOccurrences: [InvestmentOccurrence]
    @Query(sort: \MoneyEvent.date, order: .reverse) private var allMoneyEvents: [MoneyEvent]

    @State private var transactionToEdit: Transaction?
    @State private var selectedEvent: MoneyEvent?
    @State private var searchText = ""
    @AppStorage("hideAutoRecurringTransactions") private var hideRecurring = false

    /// Transactions created by daily recurring payments or daily investment
    /// contributions — the noise the "Hide Recurring" toggle filters out.
    /// Subscriptions and all non-daily cadences always show.
    private var autoRecurringIDs: Set<PersistentIdentifier> {
        var ids = Set<PersistentIdentifier>()
        for occurrence in occurrences {
            guard occurrence.parent?.cadence == .daily,
                  let id = occurrence.linkedTransaction?.persistentModelID
            else { continue }
            ids.insert(id)
        }
        for occurrence in investmentOccurrences {
            guard occurrence.parent?.cadence == .daily,
                  let id = occurrence.linkedTransaction?.persistentModelID
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    private var visibleTransactions: [Transaction] {
        guard hideRecurring else { return transactions }
        let hidden = autoRecurringIDs
        return transactions.filter { !hidden.contains($0.persistentModelID) }
    }

    /// Transactions grouped by calendar day, newest day first.
    private var groupedByDay: [(day: Date, transactions: [Transaction])] {
        let groups = Dictionary(grouping: visibleTransactions) {
            Calendar.current.startOfDay(for: $0.date)
        }
        return groups
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, transactions: $0.value) }
    }

    private var searchResults: [MoneyEvent] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        let hidden = hideRecurring ? autoRecurringIDs : []
        return allMoneyEvents.filter { event in
            if let sourceID = event.sourceTransaction?.persistentModelID, hidden.contains(sourceID) {
                return false
            }
            return event.note.lowercased().contains(q) ||
            (event.merchant?.lowercased().contains(q) == true) ||
            (event.category?.name.lowercased().contains(q) == true) ||
            (event.person?.name.lowercased().contains(q) == true) ||
            (event.account?.name.lowercased().contains(q) == true) ||
            (event.toAccount?.name.lowercased().contains(q) == true) ||
            (event.paymentMethod?.rawValue.lowercased().contains(q) == true) ||
            (event.upiApp?.lowercased().contains(q) == true) ||
            String(event.amount).contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section(dayHeader(for: group.day)) {
                            ForEach(group.transactions) { transaction in
                                TransactionRow(transaction: transaction)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        transactionToEdit = transaction
                                    }
                            }
                            .onDelete { offsets in
                                deleteTransactions(at: offsets, from: group.transactions)
                            }
                        }
                    }
                } else {
                    ForEach(searchResults) { event in
                        MoneyEventRow(event: event)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedEvent = event
                            }
                    }
                }
            }
            .overlay {
                if searchText.isEmpty && visibleTransactions.isEmpty {
                    ContentUnavailableView(
                        "No Transactions",
                        systemImage: "list.bullet",
                        description: Text(
                            transactions.isEmpty
                                ? "Tap + to record your first transaction."
                                : "All transactions here are hidden by the recurring filter."
                        )
                    )
                } else if !searchText.isEmpty && searchResults.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No events match \"\(searchText)\".")
                    )
                }
            }
            .searchable(text: $searchText, prompt: "Search transactions, people, merchants...")
            .navigationTitle("Transactions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        MerchantsView()
                    } label: {
                        Label("Merchants", systemImage: "storefront")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label("Manage Categories", systemImage: "tag")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        hideRecurring.toggle()
                    } label: {
                        Label(
                            "Hide Recurring",
                            systemImage: hideRecurring
                                ? "arrow.triangle.2.circlepath.circle.fill"
                                : "arrow.triangle.2.circlepath.circle"
                        )
                    }
                }
            }
            .sheet(item: $transactionToEdit) { transaction in
                AddEditTransactionView(transaction: transaction)
            }
            .sheet(item: $selectedEvent) { event in
                MoneyEventDetailSheet(event: event)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func dayHeader(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) {
            "Today"
        } else if Calendar.current.isDateInYesterday(day) {
            "Yesterday"
        } else {
            day.formatted(date: .abbreviated, time: .omitted)
        }
    }

    private func deleteTransactions(at offsets: IndexSet, from dayTransactions: [Transaction]) {
        for index in offsets {
            let transaction = dayTransactions[index]
            if transaction.type.isTransferLike {
                transaction.account?.reverseTransfer(
                    amount: transaction.amount,
                    to: transaction.toAccount
                )
            } else {
                transaction.account?.reverseTransaction(
                    amount: transaction.amount,
                    type: transaction.type
                )
            }
            modelContext.delete(transaction)
        }
    }
}

// MARK: - MoneyEventType UI helpers (search results only)

private extension MoneyEventType {
    var iconName: String {
        switch self {
        case .expense:            return "cart"
        case .income:             return "arrow.down.circle"
        case .creditCardPurchase: return "creditcard"
        case .creditCardPayment:  return "creditcard.fill"
        case .emi:                return "calendar.badge.clock"
        case .subscription:       return "repeat.circle"
        case .insurancePremium:   return "shield"
        case .investment:         return "chart.line.uptrend.xyaxis"
        case .lending:            return "person.badge.plus"
        case .borrowing:          return "person.badge.minus"
        case .splitExpense:       return "person.2"
        case .transfer:           return "arrow.left.arrow.right"
        case .refund:             return "arrow.uturn.left"
        case .cashWithdrawal:     return "banknote"
        case .interest:           return "percent"
        case .dividend:           return "chart.pie"
        case .loan:               return "building.columns"
        case .adjustment:         return "slider.horizontal.3"
        case .taxAndFee:          return "doc.text"
        }
    }

    var displayName: String {
        switch self {
        case .expense:            return "Expense"
        case .income:             return "Income"
        case .creditCardPurchase: return "Credit Card Purchase"
        case .creditCardPayment:  return "Credit Card Payment"
        case .emi:                return "EMI"
        case .subscription:       return "Subscription"
        case .insurancePremium:   return "Insurance Premium"
        case .investment:         return "Investment"
        case .lending:            return "Lending"
        case .borrowing:          return "Borrowing"
        case .splitExpense:       return "Split Expense"
        case .transfer:           return "Transfer"
        case .refund:             return "Refund"
        case .cashWithdrawal:     return "Cash Withdrawal"
        case .interest:           return "Interest"
        case .dividend:           return "Dividend"
        case .loan:               return "Loan EMI"
        case .adjustment:         return "Adjustment"
        case .taxAndFee:          return "Tax & Fee"
        }
    }

    /// Color used for the amount and icon in search result rows.
    var amountColor: Color {
        switch self {
        case .income, .interest, .dividend, .refund:
            return .green
        case .transfer, .cashWithdrawal, .adjustment, .lending, .borrowing, .creditCardPayment:
            return .secondary
        default:
            return .red
        }
    }
}

// MARK: - Search result row

private struct MoneyEventRow: View {
    let event: MoneyEvent

    private var title: String {
        if let merchant = event.merchant, !merchant.isEmpty { return merchant }
        if !event.note.isEmpty { return event.note }
        return event.type.displayName
    }

    private var subtitle: String {
        var parts: [String] = []
        if let cat = event.category?.name { parts.append(cat) }
        if let acct = event.account?.name { parts.append(acct) }
        if let person = event.person?.name { parts.append(person) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.type.iconName)
                .foregroundStyle(event.type.amountColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                MaskableCurrencyText(amount: event.amount)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(event.type.amountColor)
                Text(event.date, format: .dateTime.day().month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Read-only detail sheet for search results

private struct MoneyEventDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let event: MoneyEvent

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Type", value: event.type.displayName)
                    LabeledContent("Date") {
                        Text(event.date, format: .dateTime.day().month(.abbreviated).year())
                    }
                    LabeledContent("Amount") {
                        MaskableCurrencyText(amount: event.amount)
                            .foregroundStyle(event.type.amountColor)
                    }
                }

                if event.merchant != nil || !event.note.isEmpty {
                    Section {
                        if let merchant = event.merchant, !merchant.isEmpty {
                            LabeledContent("Merchant", value: merchant)
                        }
                        if !event.note.isEmpty {
                            LabeledContent("Note", value: event.note)
                        }
                    }
                }

                if event.category != nil || event.account != nil ||
                   event.toAccount != nil || event.person != nil {
                    Section {
                        if let category = event.category {
                            LabeledContent("Category", value: category.name)
                        }
                        if let account = event.account {
                            LabeledContent("Account", value: account.name)
                        }
                        if let toAccount = event.toAccount {
                            LabeledContent("To Account", value: toAccount.name)
                        }
                        if let person = event.person {
                            LabeledContent("Person", value: person.name)
                        }
                    }
                }

                if event.paymentMethod != nil || event.upiApp != nil {
                    Section {
                        if let method = event.paymentMethod {
                            LabeledContent("Payment Method", value: method.rawValue)
                        }
                        if let upi = event.upiApp {
                            LabeledContent("UPI App", value: upi)
                        }
                    }
                }

                if event.isSplit {
                    Section {
                        LabeledContent("Split Expense", value: "Yes")
                        if let portion = event.myPortionAmount {
                            LabeledContent("Your Portion") {
                                Text(portion, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Existing transaction row (unchanged)

struct TransactionRow: View {
    let transaction: Transaction

    @Query private var lendingEntries: [LendingEntry]

    private var linkedLendingEntry: LendingEntry? {
        guard transaction.isLendingRepayment else { return nil }
        return lendingEntries.first { $0.linkedTransaction === transaction }
    }

    var body: some View {
        if transaction.type.isTransferLike {
            transferRow
        } else {
            standardRow
        }
    }

    private var transferRow: some View {
        HStack {
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(transaction.account?.name ?? "Unknown") → \(transaction.toAccount?.name ?? "Unknown")")
                    .font(.body)
                if !transaction.note.isEmpty {
                    Text(transaction.note)
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }

            Spacer()

            MaskableCurrencyText(amount: transaction.amount)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var standardRow: some View {
        HStack {
            Image(systemName: transaction.isLendingRepayment ? "arrow.triangle.2.circlepath" : (transaction.category?.icon ?? "circle.fill"))
                .foregroundStyle(transaction.isLendingRepayment ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                if transaction.isLendingRepayment {
                    Text(linkedLendingEntry?.person.map { "Loan Repayment · \($0.name)" } ?? "Loan Repayment")
                        .font(.body)
                } else {
                    Text(transaction.category?.name ?? "Uncategorized")
                        .font(.body)
                }
                if transaction.isSplit {
                    if let portion = transaction.myPortionAmount {
                        Text("Split · Your portion \(portion.formatted(.currency(code: "INR").locale(Locale(identifier: "en_IN"))))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Split")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let accountName = transaction.account?.name {
                    Text(accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !transaction.isLendingRepayment, let method = transaction.paymentMethod {
                    Text(transaction.upiApp.map { "\(method.rawValue) · \($0)" } ?? method.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !transaction.note.isEmpty {
                    Text(transaction.note)
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }

            Spacer()

            MaskableCurrencyText(amount: transaction.amount)
                .font(.body.monospacedDigit())
                .foregroundStyle(
                    transaction.isLendingRepayment
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(transaction.type.isIncomeLike ? Color.green : Color.red)
                )
        }
    }
}

#Preview {
    TransactionsView()
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
