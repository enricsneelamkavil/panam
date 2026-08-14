//
//  AccountDetailView.swift
//  Panam
//

import SwiftUI
import SwiftData

/// Detail screen for a Bank/Cash/Wallet account — CreditCardDetailView's
/// counterpart for accounts with none of a card's statement/EMI/fee-waiver
/// machinery: just the balance, up front, and a full transaction history.
/// Edit lives in the toolbar (opens AddEditAccountView), matching
/// CreditCardDetailView, rather than as the row's default tap target the
/// way it used to work from AccountsView.
struct AccountDetailView: View {
    let account: Account

    @Query(sort: \Transaction.date, order: .reverse) private var allTransactions: [Transaction]

    @State private var showingEditSheet = false
    @State private var transactionToEdit: Transaction?

    /// Every transaction that touched this account — either as the primary
    /// account (expense/income/adjustment) or as a transfer's destination.
    private var accountTransactions: [Transaction] {
        allTransactions.filter { $0.account === account || $0.toAccount === account }
    }

    var body: some View {
        List {
            Section {
                headerCard
            }

            Section {
                if accountTransactions.isEmpty {
                    Text("No transactions on this account yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(accountTransactions) { transaction in
                        TransactionRow(transaction: transaction)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                transactionToEdit = transaction
                            }
                    }
                }
            } header: {
                Text("History")
            }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    showingEditSheet = true
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            AddEditAccountView(account: account)
        }
        .sheet(item: $transactionToEdit) { transaction in
            AddEditTransactionView(transaction: transaction)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Balance")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            MaskableCurrencyText(amount: account.balance)
                .font(.largeTitle.bold().monospacedDigit())
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        AccountDetailView(account: Account(name: "Preview Bank", type: .bank, balance: 25_000))
    }
    .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
