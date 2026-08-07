import SwiftUI
import SwiftData

struct UPIAppsView: View {
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

    private struct UPIAppEntry: Identifiable {
        let name: String
        let total: Double
        let transactionCount: Int
        var id: String { name }
    }

    private var upiAppEntries: [UPIAppEntry] {
        let relevant = transactions.filter {
            guard let app = $0.upiApp else { return false }
            return !app.isEmpty
        }
        let groups = Dictionary(grouping: relevant) { $0.upiApp! }
        return groups.map { name, txs in
            UPIAppEntry(
                name: name,
                total: txs.reduce(0.0) { $0 + $1.effectiveAmount },
                transactionCount: txs.count
            )
        }
        .sorted { $0.total > $1.total }
    }

    var body: some View {
        List {
            ForEach(upiAppEntries) { entry in
                NavigationLink {
                    UPIAppTransactionsView(upiApp: entry.name)
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
                        MaskableCurrencyText(amount: entry.total)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if upiAppEntries.isEmpty {
                ContentUnavailableView(
                    "No UPI Apps",
                    systemImage: "qrcode",
                    description: Text("Record a transaction with a UPI app to track spending by app.")
                )
            }
        }
        .navigationTitle("UPI Apps")
    }
}

private struct UPIAppTransactionsView: View {
    let upiApp: String

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var allTransactions: [Transaction]
    @State private var transactionToEdit: Transaction?

    private var appTransactions: [Transaction] {
        allTransactions.filter { $0.upiApp == upiApp }
    }

    var body: some View {
        List {
            ForEach(appTransactions) { transaction in
                TransactionRow(transaction: transaction)
                    .contentShape(Rectangle())
                    .onTapGesture { transactionToEdit = transaction }
            }
            .onDelete(perform: deleteTransactions)
        }
        .overlay {
            if appTransactions.isEmpty {
                ContentUnavailableView("No Transactions", systemImage: "cart")
            }
        }
        .navigationTitle(upiApp)
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $transactionToEdit) { transaction in
            AddEditTransactionView(transaction: transaction)
        }
    }

    private func deleteTransactions(at offsets: IndexSet) {
        for index in offsets {
            let transaction = appTransactions[index]
            if transaction.type.isTransferLike {
                transaction.account?.reverseTransfer(amount: transaction.amount, to: transaction.toAccount)
            } else {
                transaction.account?.reverseTransaction(amount: transaction.amount, type: transaction.type)
            }
            modelContext.delete(transaction)
        }
    }
}

#Preview {
    NavigationStack {
        UPIAppsView()
    }
    .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
