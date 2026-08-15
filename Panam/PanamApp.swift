//
//  PanamApp.swift
//  Panam

//

import SwiftUI
import SwiftData
import GoogleSignIn
import UserNotifications

/// The one piece of app-delegate-era API SwiftUI's App protocol has no
/// direct equivalent for: handleEventsForBackgroundURLSession only ever
/// gets called on a real UIApplicationDelegate, so this exists purely to
/// receive it and hand the completion handler off to
/// BackgroundDownloadManager — see that type's doc comment for what
/// happens with it from there. Nothing else about app launch runs through
/// here; PanamApp.init() and .task below still own that.
final class PanamAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloadManager.sessionIdentifier else {
            // Not our session (nothing else in Panam uses a background
            // URLSession) — still have to call the handler, just nothing
            // to stash it against.
            completionHandler()
            return
        }
        BackgroundDownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct PanamApp: App {
    @UIApplicationDelegateAdaptor(PanamAppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    /// authMode is a real stored property (see AuthState), so the login
    /// gate below reacts directly to it — no separate manually-flipped
    /// @State flag needed the way the old single-flag design required.
    @State private var authState: AuthState
    @State private var privacyState = PrivacyState()
    @State private var gmailAuth = GmailAuthManager()
    @State private var emailFetchCoordinator = EmailFetchCoordinator()
    @State private var backgroundedAt: Date?

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
        // Set before any notification could possibly fire — the fetch-
        // complete notification can arrive within moments of launch if a
        // background download resumed and finished right away, and the
        // delegate has to already be in place for willPresent's
        // foreground-banner override (see NotificationManager) to apply.
        UNUserNotificationCenter.current().delegate = NotificationManager.shared

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: GmailAuthManager.clientID)
        // Must run before AuthState() below reads its persisted authMode —
        // carries an existing user's legacy Google-only login forward so
        // this restructure doesn't log anyone out or re-prompt them.
        AuthModeBackfill.runIfNeeded()
        _authState = State(initialValue: AuthState())
        CategorySeeder.seedIfNeeded(sharedModelContainer.mainContext)
        MoneyEventMigration.runOneTimeMigration(context: sharedModelContainer.mainContext)
        if ProcessInfo.processInfo.arguments.contains("--seed-backfill-test") {
            Self.seedBackfillTestScenario(sharedModelContainer.mainContext)
        }
        MoneyEventMigration.runSourceTransactionBackfillIfNeeded(context: sharedModelContainer.mainContext)
        BackupIDBackfill.runIfNeeded(context: sharedModelContainer.mainContext)
        TransactionOrphanCleanup.runIfNeeded(context: sharedModelContainer.mainContext)

        // Registration must happen unconditionally, before launch finishes,
        // regardless of whether auto-backup is currently toggled on —
        // BGTaskScheduler requires it every launch. scheduleNext() is the
        // part that actually no-ops when the setting is off.
        BackgroundBackupScheduler.register(container: sharedModelContainer)
        BackgroundBackupScheduler.scheduleNext()
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

    /// The foreground half of auto-backup's two independent triggers — see
    /// AutoBackupCoordinator's doc comment. Since iOS never runs arbitrary
    /// app code while fully closed, this can only actually fire the next
    /// time the app is opened (cold launch or resumed from background) on
    /// or after the configured hour; it's a reliable backstop for
    /// BackgroundBackupScheduler's opportunistic BGTaskScheduler runs, not
    /// a true background schedule on its own.
    private func runAutoBackupIfDue() async {
        guard AutoBackupCoordinator.claimIfDue() else { return }
        await DriveBackupManager().backupNow(context: sharedModelContainer.mainContext)
    }

    /// Autopay's once-per-day counterpart to runAutoBackupIfDue above, same
    /// two-trigger shape (.task for cold launch, scenePhase .active as the
    /// backstop) gated by AutopayCoordinator instead of AutoBackupCoordinator
    /// — see that type's doc comment. Synchronous, unlike the backup version,
    /// since AutopayProcessor does no async work of its own.
    private func runAutopayIfDue() {
        guard AutopayCoordinator.claimIfDue() else { return }
        AutopayProcessor.processAutopays(context: sharedModelContainer.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authState.authMode == .none {
                    // One-time gate, ahead of everything else — no Face ID
                    // flow, no ContentView, until a choice is made here.
                    LoginGateView(authState: authState, gmailAuth: gmailAuth)
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
            .environment(authState)
            .environment(emailFetchCoordinator)
            .onOpenURL { url in
                GIDSignIn.sharedInstance.handle(url)
            }
            .task {
                // Independent of GIDSignIn/Gmail entirely — doesn't need to
                // wait for restorePreviousSignIn below, unlike the
                // statement check. Covers plain cold launch; the scenePhase
                // .active case further down is the backstop for resuming
                // from background, mirroring runAutoBackupIfDue's two
                // triggers exactly (see AutopayCoordinator).
                runAutopayIfDue()

                // Silently restores GIDSignIn's session (for
                // gmailAuth.signedInEmail) — irrelevant to authState.authMode
                // above, which is gated purely on the persisted Keychain
                // value. So a returning user skips straight past this
                // regardless of whether restoration succeeds, fails, or
                // never gets a chance to run offline. Once restoration
                // finishes (or fails), kick off the once-per-launch
                // automatic statement check — it needs a valid Gmail
                // session (or harmlessly no-ops without one) so it has to
                // wait for this rather than racing it.
                gmailAuth.restorePreviousSignIn {
                    Task {
                        await StatementAutoFetchProcessor.runIfNeeded(context: sharedModelContainer.mainContext)
                    }
                    Task {
                        // Also covers plain cold launch, not just resuming
                        // from background — the scenePhase .active case
                        // below only fires on a *transition*, which a fresh
                        // launch's initial state isn't.
                        await runAutoBackupIfDue()
                    }
                }
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
                // Independent of the auto-lock check above — resuming from
                // background is exactly the "opened the app" moment this
                // backstop exists for, whether or not biometric lock is on.
                if newPhase == .active {
                    runAutopayIfDue()
                    Task { await runAutoBackupIfDue() }
                }
            }
        }
        .modelContainer(sharedModelContainer)
    }
}
