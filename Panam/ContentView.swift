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
    @State private var searchText = ""

    enum AppTab {
        case today, flow, analyze, investments, add
    }

    var body: some View {
        @Bindable var tabNavigation = tabNavigation

        // Native SwiftUI TabView: 4 main tabs + 1 trailing search/action tab (TabRole.search).
        // Combined with .searchable and .tabViewSearchActivation, iOS 18 natively renders
        // the 4 tabs inside the main Liquid Glass capsule and the 1 Add tab as a separate
        // prominent button on the trailing edge (Apple News+ style).
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
            Tab("Add", systemImage: "plus", value: AppTab.add, role: .search) {
                Color.clear
            }
        }
        .searchable(text: $searchText, prompt: "Search Panam...")
        .tabViewSearchActivation(.searchTabSelection)
        .onChange(of: tabNavigation.selectedTab) { oldValue, newValue in
            if newValue == .add {
                showingAddTransaction = true
                // Reset immediately so the previously active tab remains visually selected.
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
