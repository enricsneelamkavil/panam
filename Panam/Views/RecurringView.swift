//
//  RecurringView.swift
//  Panam
//

import SwiftUI
import SwiftData

extension Cadence {
    nonisolated var displayName: String {
        switch self {
        case .daily: "Daily"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .halfYearly: "Half-Yearly"
        case .yearly: "Yearly"
        }
    }

    /// Approximate days per billing cycle, for cost-per-day comparisons.
    /// Moved here from the old standalone SubscriptionsView, folded into
    /// this list's All/Subscriptions filter.
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

private enum RecurringFilter: String, CaseIterable {
    case all = "All"
    case subscriptions = "Subscriptions"
}

/// Single list for every RecurringPayment — subscriptions and plain
/// recurring payments (chit funds, EMIs-as-recurring, etc.) alike. The
/// All/Subscriptions control below just changes which of `payments` gets
/// shown; RecurringPaymentRow is the one row type for both, branching its
/// extra content on `isSubscription`. This replaces the old separate
/// SubscriptionsView (Active/Paused/Cancelled tabs, its own row types, its
/// own entry point) — that functionality (cost-per-day, necessary-flag
/// toggling, Cancel/Pause/Restart/Reactivate) now lives here instead, on
/// the same rows already reachable from RecurringDetailView.
struct RecurringView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringPayment.name) private var payments: [RecurringPayment]

    @State private var showingAddSheet = false
    @State private var filter: RecurringFilter = .all

    /// The predicate the filter chips apply — same underlying `payments`
    /// query either way, just narrowed client-side to isSubscription for
    /// the Subscriptions chip.
    private var filteredPayments: [RecurringPayment] {
        switch filter {
        case .all: payments
        case .subscriptions: payments.filter { $0.isSubscription }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Deliberately a bare row here, not wrapped in a Section —
                // a Section would give it its own white card background
                // behind the segmented control's own native pill chrome (a
                // box behind a box), the same reasoning the old standalone
                // SubscriptionsView's tab picker followed. With the summary
                // card gone, this is now the first thing under the nav
                // title, so that mismatch would be the first thing seen.
                Picker("Filter", selection: $filter) {
                    ForEach(RecurringFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    ForEach(filteredPayments) { payment in
                        NavigationLink {
                            RecurringDetailView(payment: payment)
                        } label: {
                            RecurringPaymentRow(payment: payment)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            subscriptionLifecycleActions(for: payment)
                        }
                    }
                    .onDelete(perform: deletePayments)
                }
            }
            .overlay {
                if filteredPayments.isEmpty {
                    switch filter {
                    case .all:
                        ContentUnavailableView(
                            "No Recurring Payments",
                            systemImage: "arrow.triangle.2.circlepath",
                            description: Text("Tap + to set up your first recurring payment.")
                        )
                    case .subscriptions:
                        ContentUnavailableView(
                            "No Subscriptions",
                            systemImage: "arrow.triangle.2.circlepath",
                            description: Text("Mark a recurring payment as a subscription to track it here.")
                        )
                    }
                }
            }
            .navigationTitle("Recurring")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Recurring Payment", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddEditRecurringPaymentView()
            }
        }
    }

    /// State-dependent lifecycle actions, ported as-is from the old
    /// SubscriptionsView's per-tab swipe actions (Active → Cancel/Pause,
    /// Paused → Restart, Cancelled → Reactivate) — only subscriptions ever
    /// exposed these, so plain recurring payments still don't get them.
    @ViewBuilder
    private func subscriptionLifecycleActions(for payment: RecurringPayment) -> some View {
        if payment.isSubscription {
            if !payment.isActive {
                Button {
                    reactivateSubscription(payment)
                } label: {
                    Label("Reactivate", systemImage: "arrow.uturn.backward.circle")
                }
                .tint(.green)
            } else if payment.isPaused {
                Button {
                    restartSubscription(payment)
                } label: {
                    Label("Restart", systemImage: "play.circle")
                }
                .tint(.green)
            } else {
                Button(role: .destructive) {
                    cancelSubscription(payment)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                Button {
                    pauseSubscription(payment)
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                .tint(.orange)
            }
        }
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

    /// Temporarily stops generation without cancelling — isActive stays
    /// true (so generation guards elsewhere keep treating this as "not
    /// ended"), but no new occurrences appear until Restart. Only future
    /// *unpaid* occurrences are removed, so paid history is never touched.
    private func pauseSubscription(_ payment: RecurringPayment) {
        payment.isPaused = true
        payment.pausedDate = .now
        let now = Date.now
        for occurrence in payment.occurrences where !occurrence.isPaid && occurrence.dueDate > now {
            modelContext.delete(occurrence)
        }
    }

    /// Bare, unconfirmed resume — same instant behavior this swipe action
    /// always had. AddEditRecurringPaymentView's "Resume Subscription"
    /// button is the newer, explicit/confirmed path with a restart-date
    /// picker; this quick swipe stays as the fast path alongside it.
    private func restartSubscription(_ payment: RecurringPayment) {
        payment.isPaused = false
        payment.pausedDate = nil
        RecurringOccurrenceGenerator.generateOccurrences(for: payment, context: modelContext)
    }

    private func reactivateSubscription(_ payment: RecurringPayment) {
        payment.isActive = true
        payment.isPaused = false
        payment.pausedDate = nil
        payment.cancelledDate = nil
        RecurringOccurrenceGenerator.generateOccurrences(for: payment, context: modelContext)
    }

    private func deletePayments(at offsets: IndexSet) {
        for index in offsets {
            // Occurrences are removed automatically via the cascade delete rule.
            modelContext.delete(filteredPayments[index])
        }
    }
}

private struct RecurringPaymentRow: View {
    @Environment(PrivacyState.self) private var privacyState: PrivacyState?

    let payment: RecurringPayment

    private var nextUnpaidDueDate: Date? {
        payment.occurrences
            .filter { !$0.isPaid }
            .min(by: { $0.dueDate < $1.dueDate })?
            .dueDate
    }

    private var bouncedCount: Int {
        payment.occurrences.filter(\.isBounced).count
    }

    private var costPerDayLabel: String {
        guard privacyState?.amountsHidden != true else { return "••••••/day" }
        let amount = payment.costPerDay.formatted(
            .currency(code: "INR")
            .locale(Locale(identifier: "en_IN"))
            .precision(.fractionLength(2))
        )
        return "\(amount)/day"
    }

    /// Cancelled dims most (0.6, matching the old CancelledSubscriptionRow);
    /// paused is a lighter dim (0.75, matching PausedSubscriptionRow); a
    /// subscription marked "not necessary" reuses that same 0.6 treatment
    /// SubscriptionRow gave it. Non-subscription rows just stay full-opacity
    /// unless cancelled — same as before.
    private var rowOpacity: Double {
        if !payment.isActive { return 0.6 }
        if payment.isPaused { return 0.75 }
        if payment.isSubscription && payment.isNecessary == false { return 0.6 }
        return 1
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(payment.name)
                        .font(.body)
                    if payment.autopayEnabled {
                        Image(systemName: "a.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                Text(payment.cadence.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if bouncedCount > 0 {
                    Label("\(bouncedCount) bounced payment\(bouncedCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let nextUnpaidDueDate {
                    Text("Next: \(nextUnpaidDueDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                } else {
                    Text("None scheduled")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                if payment.isSubscription {
                    Text(costPerDayLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if payment.isSubscription {
                // Read-only here — a nested Button would fight this row's
                // own NavigationLink for the tap. RecurringDetailView has
                // the tappable version that actually cycles it.
                necessaryIcon
            }

            MaskableCurrencyText(amount: payment.expectedAmount)
                .font(.body.monospacedDigit())
        }
        .opacity(rowOpacity)
    }

    @ViewBuilder
    private var necessaryIcon: some View {
        switch payment.isNecessary {
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
}

#Preview {
    RecurringView()
        .modelContainer(
            for: [Account.self, Category.self, Transaction.self,
                  RecurringPayment.self, RecurringOccurrence.self],
            inMemory: true
        )
}
