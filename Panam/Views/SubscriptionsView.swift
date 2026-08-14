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
    case active, paused, cancelled
}

/// Active/Paused/Cancelled subscriptions. Pushed from RecurringView — no own NavigationStack.
struct SubscriptionsView: View {
    @Environment(\.modelContext) private var modelContext

    /// Active means "currently accruing cost," which excludes a paused one
    /// even though isActive itself stays true while paused — see
    /// RecurringPayment.isPaused. Paused subscriptions get their own tab
    /// below instead of showing up here.
    @Query(filter: #Predicate<RecurringPayment> { $0.isSubscription && $0.isActive && !$0.isPaused })
    private var activeSubscriptions: [RecurringPayment]

    @Query(filter: #Predicate<RecurringPayment> { $0.isSubscription && $0.isActive && $0.isPaused })
    private var pausedSubscriptions: [RecurringPayment]

    @Query(filter: #Predicate<RecurringPayment> { $0.isSubscription && !$0.isActive })
    private var cancelledSubscriptions: [RecurringPayment]

    @State private var tab: SubscriptionTab = .active

    private var sortedActive: [RecurringPayment] {
        activeSubscriptions.sorted { $0.costPerDay > $1.costPerDay }
    }

    private var sortedPaused: [RecurringPayment] {
        pausedSubscriptions.sorted {
            ($0.pausedDate ?? .distantPast) > ($1.pausedDate ?? .distantPast)
        }
    }

    private var sortedCancelled: [RecurringPayment] {
        cancelledSubscriptions.sorted {
            ($0.cancelledDate ?? .distantPast) > ($1.cancelledDate ?? .distantPast)
        }
    }

    /// Deliberately built from activeSubscriptions (already paused-excluded)
    /// rather than all isActive payments — a paused subscription isn't
    /// currently costing anything, so it shouldn't inflate this total.
    private var totalMonthlyEquivalent: Double {
        activeSubscriptions.reduce(0) { $0 + $1.monthlyEquivalentCost }
    }

    var body: some View {
        List {
            // Deliberately a bare row here, not wrapped in a Section — a
            // Section would give it its own white card background behind
            // the segmented control's own native pill chrome (a box behind
            // a box). .listRowBackground(Color.clear) clears the row's own
            // fill so only the picker's native background shows;
            // .listRowSeparator(.hidden) matches the same treatment used
            // for the Logout/Statement-PDF buttons, in case a future
            // sibling row above/below this one would otherwise put a
            // hairline against it.
            Picker("", selection: $tab) {
                Text("Active").tag(SubscriptionTab.active)
                Text("Paused").tag(SubscriptionTab.paused)
                Text("Cancelled").tag(SubscriptionTab.cancelled)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            switch tab {
            case .active:
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
                                Button {
                                    pauseSubscription(subscription)
                                } label: {
                                    Label("Pause", systemImage: "pause.circle")
                                }
                                .tint(.orange)
                            }
                    }
                }
            case .paused:
                Section {
                    ForEach(sortedPaused) { subscription in
                        PausedSubscriptionRow(subscription: subscription)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    restartSubscription(subscription)
                                } label: {
                                    Label("Restart", systemImage: "play.circle")
                                }
                                .tint(.green)
                            }
                    }
                }
            case .cancelled:
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
            } else if tab == .paused && pausedSubscriptions.isEmpty {
                ContentUnavailableView(
                    "No Paused Subscriptions",
                    systemImage: "pause.circle",
                    description: Text("Swipe left on an active subscription to pause it.")
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
        payment.pausedDate = nil
        payment.cancelledDate = .now
        let now = Date.now
        for occurrence in payment.occurrences where !occurrence.isPaid && occurrence.dueDate > now {
            modelContext.delete(occurrence)
        }
    }

    private func reactivateSubscription(_ payment: RecurringPayment) {
        payment.isActive = true
        payment.isPaused = false
        payment.pausedDate = nil
        payment.cancelledDate = nil
        RecurringOccurrenceGenerator.generateOccurrences(for: payment, context: modelContext)
    }

    /// Temporarily stops generation without cancelling — isActive stays
    /// true (so generation guards elsewhere keep treating this as "not
    /// ended"), but it moves to the Paused tab and no new occurrences
    /// appear until Restart. Same forward-only principle as
    /// cancel/regenerateFutureUnpaid: only future *unpaid* occurrences are
    /// removed, so paid history is never touched.
    private func pauseSubscription(_ payment: RecurringPayment) {
        payment.isPaused = true
        payment.pausedDate = .now
        let now = Date.now
        for occurrence in payment.occurrences where !occurrence.isPaid && occurrence.dueDate > now {
            modelContext.delete(occurrence)
        }
    }

    private func restartSubscription(_ payment: RecurringPayment) {
        payment.isPaused = false
        payment.pausedDate = nil
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
                    // No inline "Paused" badge needed here anymore — a
                    // paused subscription no longer appears in this Active
                    // list at all (see activeSubscriptions' query above),
                    // it lives in its own Paused tab instead.
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

// MARK: - Paused row

/// Same shape as CancelledSubscriptionRow — name + a "since" caption built
/// from the matching date field — but orange-toned rather than dimmed to
/// gray, since Paused is a temporary, resumable state rather than
/// Cancelled's final one.
private struct PausedSubscriptionRow: View {
    let subscription: RecurringPayment

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)

                if let date = subscription.pausedDate {
                    Text("Paused \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
        .opacity(0.75)
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
