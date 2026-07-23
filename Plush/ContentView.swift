//
//  ContentView.swift
//  Plush
//
//  Created by Enric Shajan Neelamkavil(UST,IN) on 18/07/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab: AppTab = .home
    @State private var showingAddTransaction = false

    enum AppTab {
        case home
        case transactions
        case investments
        case add
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                DashboardView()
            }
            Tab("Transactions", systemImage: "list.bullet", value: AppTab.transactions) {
                TransactionsView()
            }
            Tab("Investments", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.investments) {
                InvestmentsView()
            }
            // role: .search renders this as the detached circle beside the main capsule,
            // matching the Apple Music / App Store layout natively.
            Tab("Add", systemImage: "plus", value: AppTab.add, role: .search) {
                Color.clear
            }
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == .add {
                showingAddTransaction = true
                // Reset immediately so the content never flashes and the
                // previously active tab stays visually selected.
                selectedTab = oldValue
            }
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddEditTransactionView(transaction: nil)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
