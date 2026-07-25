//
//  PlushApp.swift
//  Plush

//

import SwiftUI
import SwiftData

@main
struct PlushApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var authState = AuthState()
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
        CategorySeeder.seedIfNeeded(sharedModelContainer.mainContext)
        AutopayProcessor.processAutopays(context: sharedModelContainer.mainContext)
    }

    var body: some Scene {
        WindowGroup {
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
