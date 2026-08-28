//
//  ContentView.swift
//  Panam
//
//  Created by Enric Shajan Neelamkavil(UST,IN) on 18/07/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    // Owned by PanamApp and injected app-wide (see TabNavigationState's own
    // doc comment) rather than local @State, so a screen several tabs away
    // — DetailedDashboardView's calendar heat-map — can switch the active
    // tab itself, not just push more content onto its own tab's stack.
    @Environment(TabNavigationState.self) private var tabNavigation
    @State private var showingAddTransaction = false

    enum AppTab {
        case today, flow, analyze, investments, add
    }

    var body: some View {
        @Bindable var tabNavigation = tabNavigation
        TabView(selection: $tabNavigation.selectedTab) {
            Tab("Today", systemImage: "house.fill", value: AppTab.today) {
                DashboardView()
            }
            Tab("Flow", systemImage: "list.bullet", value: AppTab.flow) {
                TransactionsView()
            }
            Tab("Analyze", systemImage: "chart.bar.fill", value: AppTab.analyze) {
                NavigationStack {
                    DetailedDashboardView()
                        .navigationTitle("Analyze")
                }
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
        .onChange(of: tabNavigation.selectedTab) { oldValue, newValue in
            if newValue == .add {
                showingAddTransaction = true
                // Reset immediately so the content never flashes and the
                // previously active tab stays visually selected.
                tabNavigation.selectedTab = oldValue
            }
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddEditTransactionView(transaction: nil)
        }
    }
}

#Preview {
    ContentView()
        .environment(TabNavigationState())
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
