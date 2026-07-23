//
//  SubscriptionsView.swift
//  Plush
//

import SwiftUI
import SwiftData

extension Cadence {
    /// Approximate days per billing cycle, for cost-per-day comparisons.
    var cycleDays: Double {
        switch self {
        case .daily: 1
        case .monthly: 30
        case .quarterly: 91
        case .halfYearly: 182
        case .yearly: 365
        }
    }
}

extension RecurringPayment {
    var costPerDay: Double {
        expectedAmount / cadence.cycleDays
    }

    var monthlyEquivalentCost: Double {
        costPerDay * 30
    }
}

/// Active subscriptions ranked by what they really cost per day.
/// Pushed from RecurringView, so it doesn't create its own NavigationStack.
struct SubscriptionsView: View {
    @Query(filter: #Predicate<RecurringPayment> { $0.isSubscription && $0.isActive })
    private var subscriptions: [RecurringPayment]

    private static let currencyFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    private var sortedByCostPerDay: [RecurringPayment] {
        subscriptions.sorted { $0.costPerDay > $1.costPerDay }
    }

    private var totalMonthlyEquivalent: Double {
        subscriptions.reduce(0) { $0 + $1.monthlyEquivalentCost }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text("Monthly Equivalent")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(totalMonthlyEquivalent, format: Self.currencyFormat)
                        .font(.largeTitle.bold().monospacedDigit())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

            Section {
                ForEach(sortedByCostPerDay) { subscription in
                    SubscriptionRow(subscription: subscription)
                }
            }
        }
        .overlay {
            if subscriptions.isEmpty {
                ContentUnavailableView(
                    "No Subscriptions",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Mark a recurring payment as a subscription to track it here.")
                )
            }
        }
        .navigationTitle("Subscriptions")
    }
}

private struct SubscriptionRow: View {
    let subscription: RecurringPayment

    private var costPerDayLabel: String {
        let amount = subscription.costPerDay.formatted(
            .currency(code: "INR")
            .locale(Locale(identifier: "en_IN"))
            .precision(.fractionLength(2))
        )
        return "\(amount)/day"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                Text("\(subscription.cadence.displayName) · \(subscription.expectedAmount.formatted(.currency(code: "INR").locale(Locale(identifier: "en_IN"))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(costPerDayLabel)
                .font(.subheadline.monospacedDigit())

            Button {
                cycleNecessary()
            } label: {
                necessaryIcon
            }
            .buttonStyle(.plain)
        }
        .opacity(subscription.isNecessary == false ? 0.6 : 1)
    }

    @ViewBuilder
    private var necessaryIcon: some View {
        switch subscription.isNecessary {
        case true:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case false:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case nil:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    /// First tap marks it necessary; after that, taps toggle true/false.
    /// Never returns to nil once set.
    private func cycleNecessary() {
        switch subscription.isNecessary {
        case nil: subscription.isNecessary = true
        case true: subscription.isNecessary = false
        case false: subscription.isNecessary = true
        }
    }
}

#Preview {
    NavigationStack {
        SubscriptionsView()
    }
    .modelContainer(
        for: [Account.self, Category.self, Transaction.self,
              RecurringPayment.self, RecurringOccurrence.self,
              Person.self, LendingEntry.self],
        inMemory: true
    )
}
