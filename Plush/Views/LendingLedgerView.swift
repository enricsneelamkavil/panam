import SwiftUI
import SwiftData

/// Full lending ledger: one row per person with their net running balance.
/// Pushed from the Dashboard, so it doesn't create its own NavigationStack.
struct LendingLedgerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Person.name) private var people: [Person]

    @State private var showingAddSheet = false
    @State private var personPendingDeletion: Person?
    @State private var personToSettle: Person?

    var body: some View {
        List {
            ForEach(people) { person in
                NavigationLink {
                    PersonDetailView(person: person)
                } label: {
                    PersonRow(person: person)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if person.netBalance != 0 {
                        Button {
                            personToSettle = person
                        } label: {
                            Label("Settle", systemImage: "checkmark.circle.fill")
                        }
                        .tint(.green)
                    }
                }
            }
            .onDelete(perform: deletePeople)
        }
        .overlay {
            if people.isEmpty {
                ContentUnavailableView(
                    "No Lending Records",
                    systemImage: "person.2",
                    description: Text("Tap + to record money you've lent or borrowed.")
                )
            }
        }
        .navigationTitle("Lending Ledger")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Entry", systemImage: "plus")
                }
                .tint(.appPrimary)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddLendingEntryView()
        }
        .sheet(item: $personToSettle) { person in
            SettleUpView(person: person)
        }
        .alert(
            "Outstanding Balance",
            isPresented: Binding(
                get: { personPendingDeletion != nil },
                set: { if !$0 { personPendingDeletion = nil } }
            ),
            presenting: personPendingDeletion
        ) { person in
            Button("Delete", role: .destructive) {
                modelContext.delete(person)
            }
            Button("Cancel", role: .cancel) {}
        } message: { person in
            Text("\(person.name) still has an outstanding balance. Transaction history will be kept, but they will no longer be tracked in the ledger.")
        }
    }

    private func deletePeople(at offsets: IndexSet) {
        for index in offsets {
            let person = people[index]
            // Entries cascade; the linked Transactions stay — that money
            // really moved, so account history remains accurate.
            if person.netBalance == 0 {
                modelContext.delete(person)
            } else {
                // Unsettled — ask before dropping them from the ledger.
                personPendingDeletion = person
            }
        }
    }
}

private struct PersonRow: View {
    let person: Person

    var body: some View {
        HStack {
            Text(person.name)
            Spacer()
            let balance = person.netBalance
            VStack(alignment: .trailing, spacing: 2) {
                MaskableCurrencyText(amount: abs(balance))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(balance > 0 ? .green : balance < 0 ? .red : .secondary)
                Text(balance > 0 ? "Owes you" : balance < 0 ? "You owe" : "Settled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        LendingLedgerView()
    }
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              RecurringPayment.self, RecurringOccurrence.self,
              Person.self, LendingEntry.self],
        inMemory: true
    )
}
