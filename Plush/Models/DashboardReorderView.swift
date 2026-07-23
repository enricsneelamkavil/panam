//
//  DashboardReorderView.swift
//  Plush
//

import SwiftUI

struct DashboardReorderView: View {
    @Environment(\.dismiss) private var dismiss
    
    private static let defaultSectionOrder = [
        "summary", "upcomingDues", "netWorth", "spendBar",
        "topCategories", "accounts", "lending",
    ]
    
    private static let sectionNames: [String: String] = [
        "summary": "Income/Expense",
        "upcomingDues": "Upcoming Dues",
        "netWorth": "Net Worth",
        "spendBar": "Spend Bar",
        "topCategories": "Top Categories",
        "accounts": "Accounts",
        "lending": "Lending",
    ]
    
    @AppStorage("dashboardSectionOrder") private var sectionOrderJSON = ""
    
    @State private var sectionOrder: [String] = []
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(sectionOrder, id: \.self) { id in
                    Text(Self.sectionNames[id] ?? id)
                }
                .onMove(perform: moveSections)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveSectionOrder()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadSectionOrder()
            }
        }
    }
    
    private func loadSectionOrder() {
        let stored = (try? JSONDecoder().decode([String].self, from: Data(sectionOrderJSON.utf8))) ?? []
        var order = stored.filter { Self.defaultSectionOrder.contains($0) }
        for id in Self.defaultSectionOrder where !order.contains(id) {
            order.append(id)
        }
        sectionOrder = order
    }
    
    private func moveSections(from source: IndexSet, to destination: Int) {
        sectionOrder.move(fromOffsets: source, toOffset: destination)
    }
    
    private func saveSectionOrder() {
        if let data = try? JSONEncoder().encode(sectionOrder) {
            sectionOrderJSON = String(decoding: data, as: UTF8.self)
        }
    }
}

#Preview {
    DashboardReorderView()
}
