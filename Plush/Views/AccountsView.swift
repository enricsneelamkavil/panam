//
//  AccountsView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    @State private var showingAddSheet = false
    @State private var accountToEdit: Account?

    var body: some View {
        NavigationStack {
            List {
                ForEach(AccountType.allCases, id: \.self) { type in
                    let accountsOfType = accounts.filter { $0.type == type }
                    if !accountsOfType.isEmpty {
                        Section(sectionTitle(for: type)) {
                            ForEach(accountsOfType) { account in
                                AccountRow(account: account)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        accountToEdit = account
                                    }
                            }
                            .onDelete { offsets in
                                deleteAccounts(at: offsets, from: accountsOfType)
                            }
                        }
                    }
                }
            }
            .overlay {
                if accounts.isEmpty {
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "creditcard",
                        description: Text("Tap + to add your first account.")
                    )
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddEditAccountView()
            }
            .sheet(item: $accountToEdit) { account in
                AddEditAccountView(account: account)
            }
        }
    }

    private func sectionTitle(for type: AccountType) -> String {
        switch type {
        case .bank: "Bank"
        case .cash: "Cash"
        case .wallet: "Wallet"
        case .creditCard: "Credit Card"
        }
    }

    private func deleteAccounts(at offsets: IndexSet, from accountsOfType: [Account]) {
        for index in offsets {
            modelContext.delete(accountsOfType[index])
        }
    }
}

private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.body)
                Text(typeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(account.balance, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                .font(.body.monospacedDigit())
        }
    }

    private var typeLabel: String {
        switch account.type {
        case .bank: "Bank"
        case .cash: "Cash"
        case .wallet: "Wallet"
        case .creditCard: "Credit Card"
        }
    }
}

#Preview {
    AccountsView()
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
