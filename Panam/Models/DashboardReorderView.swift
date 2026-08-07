//
//  DashboardReorderView.swift
//  Panam
//

import SwiftUI

struct DashboardReorderView: View {
    @Environment(\.dismiss) private var dismiss

    // "spendBar" removed — merged back into "topCategories" (bar + ranked list, one card).
    private static let defaultSectionOrder = [
        "summary", "upcomingDues",
        "topCategories", "accounts", "lending", "recurring", "loans", "monthlyReplay",
    ]

    private static let sectionNames: [String: String] = [
        "summary": "Income/Expense",
        "upcomingDues": "Upcoming Dues",
        "topCategories": "Spending & Top Categories",
        "accounts": "Accounts",
        "lending": "Lending",
        "recurring": "Recurring",
        "loans": "Loans",
        "monthlyReplay": "Monthly Replay",
    ]

    @AppStorage("dashboardSectionOrder") private var sectionOrderJSON = ""
    @AppStorage("dashboardHiddenSections") private var hiddenSectionsJSON = ""

    @State private var sectionOrder: [String] = []
    @State private var hiddenSections: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Total Balance", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                    Label("Credit Card Due", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("These always stay pinned at the top.")
                }

                Section {
                    ForEach(sectionOrder, id: \.self) { id in
                        HStack {
                            Text(Self.sectionNames[id] ?? id)
                            Spacer()
                            Toggle("", isOn: isVisibleBinding(for: id))
                                .labelsHidden()
                        }
                    }
                    .onMove(perform: moveSections)
                } footer: {
                    Text("Turn a section off to hide it from the Dashboard entirely.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveSectionOrder()
                        saveHiddenSections()
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
                loadHiddenSections()
            }
        }
    }

    private func isVisibleBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenSections.contains(id) },
            set: { isVisible in
                if isVisible {
                    hiddenSections.remove(id)
                } else {
                    hiddenSections.insert(id)
                }
            }
        )
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

    private func loadHiddenSections() {
        let stored = (try? JSONDecoder().decode(Set<String>.self, from: Data(hiddenSectionsJSON.utf8))) ?? []
        hiddenSections = stored.filter { Self.defaultSectionOrder.contains($0) }
    }

    private func saveHiddenSections() {
        if let data = try? JSONEncoder().encode(hiddenSections) {
            hiddenSectionsJSON = String(decoding: data, as: UTF8.self)
        }
    }
}

#Preview {
    DashboardReorderView()
}
