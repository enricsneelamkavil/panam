import SwiftUI
import SwiftData

struct UPIAppsView: View {
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

    /// The known-apps list AddEditTransactionView's "UPI App" Picker draws
    /// from — separate from upiAppEntries below, which only ever reflects
    /// apps that have actually shown up on a logged transaction. This one
    /// exists so an app can be picked the first time it's used, not just
    /// after.
    @AppStorage(AppSettings.knownUPIAppsKey)
    private var knownAppsRaw = AppSettings.knownUPIAppsDefault

    @State private var newAppName = ""

    private var knownApps: [String] {
        knownAppsRaw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

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
            Section {
                ForEach(knownApps, id: \.self) { name in
                    Text(name)
                }
                .onDelete(perform: removeKnownApps)

                HStack {
                    TextField("Add UPI App", text: $newAppName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Button("Add", action: addKnownApp)
                        .disabled(newAppName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Known Apps")
            } footer: {
                Text("Apps you can pick from when logging a UPI transaction, whether or not you've used one yet.")
            }

            Section {
                if upiAppEntries.isEmpty {
                    Text("No UPI transactions logged yet.")
                        .foregroundStyle(.secondary)
                } else {
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
            } header: {
                Text("Spending by App")
            }
        }
        .navigationTitle("UPI Apps")
    }

    private func addKnownApp() {
        let trimmed = newAppName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !knownApps.contains(trimmed) else { return }
        knownAppsRaw += (knownAppsRaw.isEmpty ? "" : "\n") + trimmed
        newAppName = ""
    }

    private func removeKnownApps(at offsets: IndexSet) {
        var apps = knownApps
        apps.remove(atOffsets: offsets)
        knownAppsRaw = apps.joined(separator: "\n")
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
            safelyDelete(transaction: transaction, context: modelContext)
        }
    }
}

#Preview {
    NavigationStack {
        UPIAppsView()
    }
    .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
