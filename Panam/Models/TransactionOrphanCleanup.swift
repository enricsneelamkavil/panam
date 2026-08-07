import Foundation
import SwiftData

/// One-time backfill correcting orphaned Transaction relationship pointers
/// left behind by TransactionsView/MerchantsView/UPIAppsView's delete flows
/// before Transaction+SafeDelete.swift existed — confirmed on-device via
/// direct SQLite inspection: 5 records across RecurringOccurrence,
/// InvestmentOccurrence, LendingEntry, EMIInstallment, LoanInstallment,
/// CardPayment, SplitAllocation, and MoneyEvent still pointing at deleted
/// Transaction rows.
///
/// Detection approach: reading an *attribute* off an invalidated model (its
/// backing row deleted elsewhere) is what actually crashes — "This model
/// instance was invalidated because its backing data could no longer be
/// found in the store". Reading `persistentModelID` off the same stale
/// reference does not: SwiftData keeps identity metadata independent of a
/// row's attribute data, the same way CoreData's `NSManagedObjectID`
/// survives invalidation — it has to, since the merge/history machinery
/// that reports deletions relies on being able to identify *which* object
/// was deleted without re-reading it. So every dangling pointer here is
/// found by comparing `persistentModelID` against a fresh, definitely-valid
/// set of Transaction IDs, never by touching any other property of the
/// possibly-gone Transaction. (This was the one part of the plan worth
/// flagging: a direct `!= nil` check doesn't distinguish "no transaction"
/// from "a transaction that no longer exists" — both look non-nil until
/// something tries to read through it — so the fix has to compare against
/// a fresh fetch, not just test for nil.)
enum TransactionOrphanCleanup {
    private static let completionKey = "transactionOrphanCleanupComplete"

    static func runIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }

        let validTransactionIDs = Set(
            ((try? context.fetch(FetchDescriptor<Transaction>())) ?? []).map(\.persistentModelID)
        )

        var cleaned: [String] = []

        for occurrence in (try? context.fetch(FetchDescriptor<RecurringOccurrence>())) ?? [] {
            guard let linked = occurrence.linkedTransaction,
                  !validTransactionIDs.contains(linked.persistentModelID)
            else { continue }
            occurrence.linkedTransaction = nil
            if occurrence.isPaid {
                occurrence.isPaid = false
                occurrence.actualAmount = nil
                occurrence.paidDate = nil
            }
            cleaned.append("RecurringOccurrence(parent: \(occurrence.parent?.name ?? "?"), due \(occurrence.dueDate))")
        }

        for occurrence in (try? context.fetch(FetchDescriptor<InvestmentOccurrence>())) ?? [] {
            guard let linked = occurrence.linkedTransaction,
                  !validTransactionIDs.contains(linked.persistentModelID)
            else { continue }
            occurrence.linkedTransaction = nil
            if occurrence.isContributed {
                occurrence.isContributed = false
                occurrence.actualAmount = nil
                occurrence.contributedDate = nil
            }
            cleaned.append("InvestmentOccurrence(parent: \(occurrence.parent?.name ?? "?"), due \(occurrence.dueDate))")
        }

        for installment in (try? context.fetch(FetchDescriptor<EMIInstallment>())) ?? [] {
            guard let linked = installment.linkedTransaction,
                  !validTransactionIDs.contains(linked.persistentModelID)
            else { continue }
            installment.linkedTransaction = nil
            if installment.isPaid {
                installment.isPaid = false
                installment.paidDate = nil
            }
            cleaned.append("EMIInstallment(parent: \(installment.parent?.name ?? "?"), #\(installment.installmentNumber))")
        }

        for installment in (try? context.fetch(FetchDescriptor<LoanInstallment>())) ?? [] {
            guard let linked = installment.linkedTransaction,
                  !validTransactionIDs.contains(linked.persistentModelID)
            else { continue }
            installment.linkedTransaction = nil
            if installment.isPaid {
                installment.isPaid = false
                installment.paidDate = nil
            }
            cleaned.append("LoanInstallment(parent: \(installment.parent?.name ?? "?"), #\(installment.installmentNumber))")
        }

        for entry in (try? context.fetch(FetchDescriptor<LendingEntry>())) ?? [] {
            if let linked = entry.linkedTransaction, !validTransactionIDs.contains(linked.persistentModelID) {
                entry.linkedTransaction = nil
                cleaned.append("LendingEntry.linkedTransaction(person: \(entry.person?.name ?? "?"))")
            }
            if let source = entry.sourceTransaction, !validTransactionIDs.contains(source.persistentModelID) {
                entry.sourceTransaction = nil
                cleaned.append("LendingEntry.sourceTransaction(person: \(entry.person?.name ?? "?"))")
            }
        }

        for payment in (try? context.fetch(FetchDescriptor<CardPayment>())) ?? [] {
            if let card = payment.cardTransaction, !validTransactionIDs.contains(card.persistentModelID) {
                payment.cardTransaction = nil
                cleaned.append("CardPayment.cardTransaction(\(payment.type.rawValue))")
            }
            if let source = payment.sourceTransaction, !validTransactionIDs.contains(source.persistentModelID) {
                payment.sourceTransaction = nil
                cleaned.append("CardPayment.sourceTransaction(\(payment.type.rawValue))")
            }
            if let fee = payment.feeTransaction, !validTransactionIDs.contains(fee.persistentModelID) {
                payment.feeTransaction = nil
                cleaned.append("CardPayment.feeTransaction(\(payment.type.rawValue))")
            }
        }

        for allocation in (try? context.fetch(FetchDescriptor<SplitAllocation>())) ?? [] {
            guard let linked = allocation.transaction,
                  !validTransactionIDs.contains(linked.persistentModelID)
            else { continue }
            allocation.transaction = nil
            cleaned.append("SplitAllocation(person: \(allocation.person?.name ?? "?"))")
        }

        for event in (try? context.fetch(FetchDescriptor<MoneyEvent>())) ?? [] {
            guard let source = event.sourceTransaction,
                  !validTransactionIDs.contains(source.persistentModelID)
            else { continue }
            event.sourceTransaction = nil
            cleaned.append("MoneyEvent(\(event.type.rawValue), \(event.note))")
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: completionKey)
            if cleaned.isEmpty {
                print("[TransactionOrphanCleanup] Complete ✓ — no orphaned Transaction references found")
            } else {
                print("[TransactionOrphanCleanup] Complete ✓ — cleaned \(cleaned.count) orphaned reference(s):")
                for line in cleaned { print("  - \(line)") }
            }
        } catch {
            print("[TransactionOrphanCleanup] Save failed: \(error). Will retry on next launch.")
        }
    }
}
