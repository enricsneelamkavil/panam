//
//  TransactionsView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

    @State private var showingAddSheet = false
    @State private var transactionToEdit: Transaction?

    /// Transactions grouped by calendar day, newest day first.
    private var groupedByDay: [(day: Date, transactions: [Transaction])] {
        let groups = Dictionary(grouping: transactions) {
            Calendar.current.startOfDay(for: $0.date)
        }
        return groups
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, transactions: $0.value) }
    }

    var body: some View {
        NavigationStack {
            List {
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
            }
            .overlay {
                if transactions.isEmpty {
                    ContentUnavailableView(
                        "No Transactions",
                        systemImage: "list.bullet",
                        description: Text("Tap + to record your first transaction.")
                    )
                }
            }
            .navigationTitle("Transactions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Transaction", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddEditTransactionView()
            }
            .sheet(item: $transactionToEdit) { transaction in
                AddEditTransactionView(transaction: transaction)
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
            // Undo the transaction's effect on its account before removing the record.
            transaction.account?.reverseTransaction(amount: transaction.amount, type: transaction.type)
            modelContext.delete(transaction)
        }
    }
}

private struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack {
            Image(systemName: transaction.category?.icon ?? "circle.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.category?.name ?? "Uncategorized")
                    .font(.body)
                if let accountName = transaction.account?.name {
                    Text(accountName)
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

            Text(transaction.amount, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                .font(.body.monospacedDigit())
                .foregroundStyle(transaction.type == .expense ? .red : .green)
        }
    }
}

#Preview {
    TransactionsView()
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
