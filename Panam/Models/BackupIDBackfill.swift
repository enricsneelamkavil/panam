import Foundation
import SwiftData

/// One-time correction for a lightweight-migration artifact: SwiftData
/// evaluates a new property's default value expression once per *entity*,
/// not once per row — so when `backupID: UUID = UUID()` was added to each
/// @Model, every pre-existing record of a given type ended up sharing the
/// exact same UUID instead of getting a unique one (verified on-device: all
/// 102 pre-existing Transactions, all 16 Accounts, etc. shared one backupID
/// per entity type). This assigns every existing record across all 15
/// backed-up entity types (see DriveBackupManager) a fresh, genuinely
/// unique backupID, overwriting whatever value the migration stamped in.
///
/// backupID is an internal-only field — never displayed, and doesn't affect
/// balances or relationships as they exist today (only how
/// DriveBackupManager cross-references records in a backup/restore round
/// trip) — so this is a low-risk corrective write, touching only that one
/// property.
enum BackupIDBackfill {
    private static let completionKey = "backupIDBackfillComplete"

    static func runIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }

        for record in (try? context.fetch(FetchDescriptor<Account>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<Category>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<Transaction>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<Person>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<RecurringPayment>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<RecurringOccurrence>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<Investment>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<InvestmentOccurrence>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<LendingEntry>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<CreditCardEMI>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<EMIInstallment>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<CardPayment>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<SplitAllocation>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<Loan>())) ?? [] { record.backupID = UUID() }
        for record in (try? context.fetch(FetchDescriptor<LoanInstallment>())) ?? [] { record.backupID = UUID() }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: completionKey)
            print("[BackupIDBackfill] Complete ✓ — every record's backupID reassigned to a unique value")
        } catch {
            print("[BackupIDBackfill] Save failed: \(error). Will retry on next launch.")
        }
    }
}
