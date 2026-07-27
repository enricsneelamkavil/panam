//
//  PersonDetailView.swift
//  Plush
//

import SwiftUI
import SwiftData

struct PersonDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let person: Person

    @State private var showingAddSheet = false
    @State private var showingSettleUp = false
    @State private var entryToEdit: LendingEntry?

    private static let currencyFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    private var sortedEntries: [LendingEntry] {
        person.entries.sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Section {
                let balance = person.netBalance
                VStack(spacing: 4) {
                    Text(balance > 0 ? "Owes you" : balance < 0 ? "You owe" : "Settled")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(abs(balance), format: Self.currencyFormat)
                        .font(.largeTitle.bold().monospacedDigit())
                        .foregroundStyle(balance > 0 ? .green : balance < 0 ? .red : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)

                if balance != 0 {
                    Button {
                        showingSettleUp = true
                    } label: {
                        Text("Settle Up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                }
            }

            Section("History") {
                ForEach(sortedEntries) { entry in
                    EntryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            entryToEdit = entry
                        }
                }
                .onDelete(perform: deleteEntries)
            }
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Entry", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddLendingEntryView(person: person)
        }
        .sheet(isPresented: $showingSettleUp) {
            SettleUpView(person: person)
        }
        .sheet(item: $entryToEdit) { entry in
            AddLendingEntryView(person: person, entry: entry)
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            let entry = sortedEntries[index]
            // Undo the money movement: reverse the account effect and
            // remove the linked Transaction along with the entry.
            if let transaction = entry.linkedTransaction {
                transaction.account?.reverseTransaction(amount: transaction.amount, type: transaction.type)
                modelContext.delete(transaction)
            }
            modelContext.delete(entry)
        }
    }
}

private struct EntryRow: View {
    let entry: LendingEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind.displayName)
                Text(entry.date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }
            Spacer()
            Text(entry.amount, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
                .font(.body.monospacedDigit())
                .foregroundStyle(entry.kind.ledgerSign > 0 ? .green : .red)
        }
    }
}

#Preview {
    NavigationStack {
        PersonDetailView(person: Person(name: "Preview Friend"))
    }
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              RecurringPayment.self, RecurringOccurrence.self,
              Person.self, LendingEntry.self],
        inMemory: true
    )
}
