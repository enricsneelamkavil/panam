//
//  PanamApp.swift
//  Panam

//

import SwiftUI
import SwiftData
import GoogleSignIn

@main
struct PanamApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var authState = AuthState()
    @State private var privacyState = PrivacyState()
    @State private var gmailAuth = GmailAuthManager()
    @State private var backgroundedAt: Date?

    /// Gates the one-time Google sign-in screen. Seeded from the Keychain-
    /// persisted `hasCompletedGoogleLogin` at launch (via the explicit
    /// `_needsGoogleSignIn = State(initialValue:)` form — plain `self.x = `
    /// assignment inside `init()` is not a reliable way to set a @State
    /// property's actual initial value); flipped locally afterward (not
    /// re-read from Keychain) the moment sign-in succeeds so the UI
    /// proceeds immediately, in the same session — Keychain-backed computed
    /// properties aren't tracked by @Observable, only stored ones.
    @State private var needsGoogleSignIn: Bool

    @AppStorage(AppSettings.biometricLockEnabledKey)
    private var biometricLockEnabled = AppSettings.biometricLockEnabledDefault

    @AppStorage(AppSettings.autoLockMinutesKey)
    private var autoLockMinutes = AppSettings.autoLockMinutesDefault

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Account.self,
            Category.self,
            Transaction.self,
            Person.self,
            RecurringPayment.self,
            RecurringOccurrence.self,
            Investment.self,
            InvestmentOccurrence.self,
            LendingEntry.self,
            CreditCardEMI.self,
            EMIInstallment.self,
            CardPayment.self,
            SplitAllocation.self,
            MoneyEvent.self,
            Loan.self,
            LoanInstallment.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: GmailAuthManager.clientID)
        _needsGoogleSignIn = State(initialValue: !AuthState().hasCompletedGoogleLogin)
        CategorySeeder.seedIfNeeded(sharedModelContainer.mainContext)
        MoneyEventMigration.runOneTimeMigration(context: sharedModelContainer.mainContext)
        if ProcessInfo.processInfo.arguments.contains("--seed-backfill-test") {
            Self.seedBackfillTestScenario(sharedModelContainer.mainContext)
        }
        MoneyEventMigration.runSourceTransactionBackfillIfNeeded(context: sharedModelContainer.mainContext)
        BackupIDBackfill.runIfNeeded(context: sharedModelContainer.mainContext)
        TransactionOrphanCleanup.runIfNeeded(context: sharedModelContainer.mainContext)
        AutopayProcessor.processAutopays(context: sharedModelContainer.mainContext)
    }

    /// TEMPORARY test scaffold — simulates a pre-fix daily-recurring MoneyEvent
    /// (no sourceTransaction link) so the backfill can be verified end-to-end.
    /// Remove after verifying the backfill + search-exclusion behavior.
    static func seedBackfillTestScenario(_ context: ModelContext) {
        let account = Account(name: "Daily Test Account", type: .bank)
        let category = Category(name: "Daily Test Category")
        context.insert(account)
        context.insert(category)

        let startDate = Calendar.current.startOfDay(for: .now)
        let payment = RecurringPayment(
            name: "DailyCoffeeRun", expectedAmount: 50, cadence: .daily,
            startDate: startDate, category: category, account: account
        )
        context.insert(payment)

        let occurrence = RecurringOccurrence(dueDate: startDate, expectedAmount: 50, parent: payment)
        occurrence.isPaid = true
        occurrence.actualAmount = 50
        occurrence.paidDate = startDate
        context.insert(occurrence)

        let transaction = Transaction(
            amount: 50, date: startDate, note: payment.name,
            type: .expense, account: account, category: category
        )
        context.insert(transaction)
        occurrence.linkedTransaction = transaction

        // Pre-fix MoneyEvent: matches the transaction's note/amount/date exactly,
        // but has no sourceTransaction link — this is what the backfill must fix.
        let event = MoneyEvent(type: .expense, amount: 50, date: startDate, note: payment.name)
        event.account = account
        event.category = category
        context.insert(event)

        try? context.save()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if needsGoogleSignIn {
                    // One-time gate, ahead of everything else — no Face ID
                    // flow, no ContentView, until this succeeds once.
                    GoogleSignInGateView(authState: authState, gmailAuth: gmailAuth) {
                        needsGoogleSignIn = false
                    }
                } else {
                    ZStack {
                        // Always mounted, even while locked — the lock screen is a
                        // pure overlay so switching tabs/scroll position isn't lost
                        // each time the app locks and unlocks.
                        ContentView()

                        if biometricLockEnabled && !authState.isUnlocked {
                            AppLockView(authState: authState)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .environment(privacyState)
            .environment(gmailAuth)
            .onOpenURL { url in
                GIDSignIn.sharedInstance.handle(url)
            }
            .task {
                // Silently restores GIDSignIn's session (for
                // gmailAuth.signedInEmail) — irrelevant to needsGoogleSignIn
                // above, which is gated purely on the persisted Keychain
                // flag. So a returning user skips straight past this
                // regardless of whether restoration succeeds, fails, or
                // never gets a chance to run offline.
                gmailAuth.restorePreviousSignIn()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background:
                    backgroundedAt = .now
                case .active:
                    guard let lastBackgrounded = backgroundedAt else { break }
                    defer { backgroundedAt = nil }
                    guard biometricLockEnabled, autoLockMinutes > 0 else { break }
                    let elapsed = Date.now.timeIntervalSince(lastBackgrounded)
                    if elapsed >= Double(autoLockMinutes) * 60 {
                        authState.isUnlocked = false
                    }
                default:
                    break
                }
            }
        }
        .modelContainer(sharedModelContainer)
    }
}
