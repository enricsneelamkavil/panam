//
//  SubscriptionsView.swift
//  Panam
//

import SwiftUI
import SwiftData

extension Cadence {
    /// Approximate days per billing cycle, for cost-per-day comparisons.
    nonisolated var cycleDays: Double {
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
    nonisolated var costPerDay: Double {
        expectedAmount / cadence.cycleDays
    }

    nonisolated var monthlyEquivalentCost: Double {
        costPerDay * 30
    }
}

private enum SubscriptionTab {
    case active, cancelled
}

/// Active/Cancelled subscriptions. Pushed from RecurringView — no own NavigationStack.
struct SubscriptionsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<RecurringPayment> { $0.isSubscription && $0.isActive })
    private var activeSubscriptions: [RecurringPayment]

    @Query(filter: #Predicate<RecurringPayment> { $0.isSubscription && !$0.isActive })
    private var cancelledSubscriptions: [RecurringPayment]

    @State private var tab: SubscriptionTab = .active

    private var sortedActive: [RecurringPayment] {
        activeSubscriptions.sorted { $0.costPerDay > $1.costPerDay }
    }

    private var sortedCancelled: [RecurringPayment] {
        cancelledSubscriptions.sorted {
            ($0.cancelledDate ?? .distantPast) > ($1.cancelledDate ?? .distantPast)
        }
    }

    private var totalMonthlyEquivalent: Double {
        activeSubscriptions.reduce(0) { $0 + $1.monthlyEquivalentCost }
    }

    var body: some View {
        List {
            Picker("", selection: $tab) {
                Text("Active").tag(SubscriptionTab.active)
                Text("Cancelled").tag(SubscriptionTab.cancelled)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if tab == .active {
                Section {
                    VStack(spacing: 4) {
                        Text("Monthly Equivalent")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        MaskableCurrencyText(amount: totalMonthlyEquivalent)
                            .font(.largeTitle.bold().monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(sortedActive) { subscription in
                        SubscriptionRow(subscription: subscription)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    cancelSubscription(subscription)
                                } label: {
                                    Label("Cancel", systemImage: "xmark.circle")
                                }
                                if subscription.isPaused {
                                    Button {
                                        restartSubscription(subscription)
                                    } label: {
                                        Label("Restart", systemImage: "play.circle")
                                    }
                                    .tint(.green)
                                } else {
                                    Button {
                                        pauseSubscription(subscription)
                                    } label: {
                                        Label("Pause", systemImage: "pause.circle")
                                    }
                                    .tint(.orange)
                                }
                            }
                    }
                }
            } else {
                Section {
                    ForEach(sortedCancelled) { subscription in
                        CancelledSubscriptionRow(subscription: subscription)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    reactivateSubscription(subscription)
                                } label: {
                                    Label("Reactivate", systemImage: "arrow.uturn.backward.circle")
                                }
                                .tint(.green)
                            }
                    }
                }
            }
        }
        .overlay {
            if tab == .active && activeSubscriptions.isEmpty {
                ContentUnavailableView(
                    "No Subscriptions",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Mark a recurring payment as a subscription to track it here.")
                )
            } else if tab == .cancelled && cancelledSubscriptions.isEmpty {
                ContentUnavailableView(
                    "No Cancelled Subscriptions",
                    systemImage: "xmark.circle",
                    description: Text("Swipe left on an active subscription to cancel it.")
                )
            }
        }
        .navigationTitle("Subscriptions")
    }

    private func cancelSubscription(_ payment: RecurringPayment) {
        payment.isActive = false
        payment.isPaused = false
        payment.cancelledDate = .now
        let now = Date.now
        for occurrence in payment.occurrences where !occurrence.isPaid && occurrence.dueDate > now {
            modelContext.delete(occurrence)
        }
    }

    private func reactivateSubscription(_ payment: RecurringPayment) {
        payment.isActive = true
        payment.isPaused = false
        payment.cancelledDate = nil
        RecurringOccurrenceGenerator.generateOccurrences(for: payment, context: modelContext)
    }

    /// Temporarily stops generation without cancelling — stays in the Active
    /// tab (isActive untouched) but no new occurrences appear until Restart.
    private func pauseSubscription(_ payment: RecurringPayment) {
        payment.isPaused = true
        let now = Date.now
        for occurrence in payment.occurrences where !occurrence.isPaid && occurrence.dueDate > now {
            modelContext.delete(occurrence)
        }
    }

    private func restartSubscription(_ payment: RecurringPayment) {
        payment.isPaused = false
        RecurringOccurrenceGenerator.generateOccurrences(for: payment, context: modelContext)
    }
}

// MARK: - Active row

private struct SubscriptionRow: View {
    @Environment(PrivacyState.self) private var privacyState: PrivacyState?

    let subscription: RecurringPayment

    private var costPerDayLabel: String {
        guard privacyState?.amountsHidden != true else { return "••••••/day" }
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
                HStack(spacing: 4) {
                    Text(subscription.name)
                    if subscription.autopayEnabled {
                        Image(systemName: "a.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    if subscription.isPaused {
                        Text("Paused")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
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

// MARK: - Cancelled row

private struct CancelledSubscriptionRow: View {
    let subscription: RecurringPayment

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)

                if let date = subscription.cancelledDate {
                    Text("Cancelled \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(subscription.cadence.displayName) · \(subscription.expectedAmount.formatted(.currency(code: "INR").locale(Locale(identifier: "en_IN"))))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            MaskableCurrencyText(amount: subscription.expectedAmount)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .opacity(0.6)
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
