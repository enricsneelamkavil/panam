import SwiftUI
import SwiftData

struct MerchantsView: View {
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

    private struct MerchantEntry: Identifiable {
        let name: String
        let totalSpent: Double
        let transactionCount: Int
        var id: String { name }
    }

    private var merchantEntries: [MerchantEntry] {
        let relevant = transactions.filter {
            guard let m = $0.merchantName else { return false }
            return !m.isEmpty
        }
        let groups = Dictionary(grouping: relevant) { $0.merchantName! }
        return groups.map { name, txs in
            let debits = txs
                .filter { $0.type == .expense || $0.type == .taxAndFee }
                .reduce(0.0) { $0 + $1.effectiveAmount }
            let refunds = txs
                .filter { $0.type == .refund }
                .reduce(0.0) { $0 + $1.effectiveAmount }
            return MerchantEntry(
                name: name,
                totalSpent: max(0, debits - refunds),
                transactionCount: txs.count
            )
        }
        .sorted { $0.totalSpent > $1.totalSpent }
    }

    var body: some View {
        List {
            ForEach(merchantEntries) { entry in
                NavigationLink {
                    MerchantTransactionsView(merchantName: entry.name)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.body)
                            Text("\(entry.transactionCount) transaction\(entry.transactionCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.totalSpent > 0 {
                            MaskableCurrencyText(amount: entry.totalSpent)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if merchantEntries.isEmpty {
                ContentUnavailableView(
                    "No Merchants",
                    systemImage: "storefront",
                    description: Text("Add a merchant when recording a transaction to track spending by store.")
                )
            }
        }
        .navigationTitle("Merchants")
    }
}

private struct MerchantTransactionsView: View {
    let merchantName: String

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var allTransactions: [Transaction]
    @State private var transactionToEdit: Transaction?

    private var merchantTransactions: [Transaction] {
        allTransactions.filter { $0.merchantName == merchantName }
    }

    var body: some View {
        List {
            ForEach(merchantTransactions) { transaction in
                TransactionRow(transaction: transaction)
                    .contentShape(Rectangle())
                    .onTapGesture { transactionToEdit = transaction }
            }
            .onDelete(perform: deleteTransactions)
        }
        .overlay {
            if merchantTransactions.isEmpty {
                ContentUnavailableView("No Transactions", systemImage: "cart")
            }
        }
        .navigationTitle(merchantName)
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $transactionToEdit) { transaction in
            AddEditTransactionView(transaction: transaction)
        }
    }

    private func deleteTransactions(at offsets: IndexSet) {
        for index in offsets {
            let transaction = merchantTransactions[index]
            if transaction.type.isTransferLike {
                transaction.account?.reverseTransfer(amount: transaction.amount, to: transaction.toAccount)
            } else {
                transaction.account?.reverseTransaction(amount: transaction.amount, type: transaction.type)
            }
            modelContext.delete(transaction)
        }
    }
}
