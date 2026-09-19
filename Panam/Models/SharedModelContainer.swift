//
//  SharedModelContainer.swift
//  Panam
//

import Foundation
import SwiftData

/// Shared single instance of ModelContainer used app-wide (PanamApp, AppIntents, Background Tasks)
/// to avoid creating multiple competing containers for the same SQLite database store, which causes
/// SwiftData object invalidation ("This model instance was invalidated because its backing data could no longer be found in the store").
@MainActor
final class SharedModelContainer {
    static let main: ModelContainer = {
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
}
