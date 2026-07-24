import SwiftUI
import SwiftData

struct FutureView: View {
    @Query(sort: \RecurringOccurrence.dueDate) private var recurringOccurrences: [RecurringOccurrence]
    @Query(sort: \InvestmentOccurrence.dueDate) private var investmentOccurrences: [InvestmentOccurrence]

    private var upcomingItems: [FutureItem] {
        let now = Date.now
        let cutoff = Calendar.current.date(byAdding: .year, value: 1, to: now) ?? now

        let recurring = recurringOccurrences
            .filter { !$0.isPaid && ($0.parent?.cadence.reminderEligible ?? false) && $0.dueDate <= cutoff }
            .map { FutureItem(name: $0.parent?.name ?? "Recurring", amount: $0.expectedAmount, dueDate: $0.dueDate, isInvestment: false) }

        let investments = investmentOccurrences
            .filter { !$0.isContributed && ($0.parent?.cadence?.reminderEligible ?? true) && $0.dueDate <= cutoff }
            .map { FutureItem(name: $0.parent?.name ?? "Investment", amount: $0.expectedAmount, dueDate: $0.dueDate, isInvestment: true) }

        return (recurring + investments).sorted { $0.dueDate < $1.dueDate }
    }

    private var monthGroups: [(header: String, items: [FutureItem])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"

        let grouped = Dictionary(grouping: upcomingItems) { item -> Int in
            let c = calendar.dateComponents([.year, .month], from: item.dueDate)
            return (c.year ?? 0) * 100 + (c.month ?? 0)
        }

        return grouped.sorted { $0.key < $1.key }.map { key, items in
            var c = DateComponents()
            c.year = key / 100
            c.month = key % 100
            c.day = 1
            let date = calendar.date(from: c) ?? .now
            return (header: formatter.string(from: date), items: items.sorted { $0.dueDate < $1.dueDate })
        }
    }

    var body: some View {
        List {
            if monthGroups.isEmpty {
                Text("No upcoming commitments in the next 12 months.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monthGroups, id: \.header) { group in
                    Section(group.header) {
                        ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                            FutureItemRow(item: item)
                        }
                    }
                }
            }
        }
        .navigationTitle("12-Month Outlook")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FutureItem {
    let name: String
    let amount: Double
    let dueDate: Date
    let isInvestment: Bool
}

private struct FutureItemRow: View {
    let item: FutureItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if item.isInvestment {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                    Text(item.name)
                }
                Text(item.dueDate, format: .dateTime.day().month(.abbreviated).year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MaskableCurrencyText(amount: item.amount)
                .font(.subheadline.monospacedDigit())
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        FutureView()
    }
    .modelContainer(
        for: [RecurringPayment.self, RecurringOccurrence.self,
              Investment.self, InvestmentOccurrence.self],
        inMemory: true
    )
}
