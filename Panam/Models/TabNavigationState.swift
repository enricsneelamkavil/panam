//
//  TabNavigationState.swift
//  Panam
//

import Foundation
import Observation

/// Cross-tab navigation state shared between the tab bar itself
/// (ContentView) and any screen that needs to programmatically switch tabs
/// and hand a bit of state to whatever's waiting on the other side. Today
/// that's just the Detailed Dashboard's calendar heat-map switching to the
/// Flow tab with a specific day pre-filtered — a screen nested inside the
/// Analyze tab's own NavigationStack has no other way to reach back into
/// ContentView's tab selection, since ContentView instantiates each tab's
/// root view once and never re-creates it on a tab switch. Injected
/// app-wide via .environment(...) from PanamApp, same as AuthState/
/// PrivacyState/GmailAuthManager, rather than owned locally by ContentView.
@MainActor
@Observable
final class TabNavigationState {
    var selectedTab: ContentView.AppTab = .today

    /// Set by a calendar heat-map day tap right before switching to the
    /// Flow tab. TransactionsView (the Flow tab's root, which stays alive
    /// across tab switches rather than being re-created) consumes this —
    /// copies it into its own local day filter, then clears it back to nil
    /// — the moment it appears or this changes while it's already mounted,
    /// so a later plain tap on the Flow tab with nothing pending never
    /// re-applies a stale filter.
    var pendingTransactionsDayFilter: Date?
}
