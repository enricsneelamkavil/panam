import Foundation
import SwiftData

enum MoneyEventMigration {
    private static let completionKey = "moneyEventMigrationComplete_v2"

    static func runOneTimeMigration(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }

        var transactionCount = 0
        var recurringCount = 0
        var investmentCount = 0
        var lendingCount = 0
        var emiCount = 0
        var cardPaymentCount = 0
        var created = 0

        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withFullDate]

        // --- Transactions ---
        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        transactionCount = transactions.count
        for tx in transactions {
            let event = MoneyEventSync.makeEvent(from: tx)
            event.legacyRecordDescription = "Transaction: \(tx.note.isEmpty ? "(no note)" : tx.note) — \(tx.amount) on \(dateFmt.string(from: tx.date))"
            context.insert(event)
            created += 1
        }

        // --- RecurringOccurrence (paid only) ---
        let recurringOccurrences = (try? context.fetch(FetchDescriptor<RecurringOccurrence>(
            predicate: #Predicate { $0.isPaid }
        ))) ?? []
        recurringCount = recurringOccurrences.count
        for occ in recurringOccurrences {
            let event = MoneyEventSync.makeEvent(from: occ)
            event.legacyRecordDescription = "RecurringOccurrence: \(occ.parent?.name ?? "(unknown)") — \(occ.actualAmount ?? occ.expectedAmount) on \(dateFmt.string(from: occ.paidDate ?? occ.dueDate))"
            context.insert(event)
            created += 1
        }

        // --- InvestmentOccurrence (contributed only) ---
        let investmentOccurrences = (try? context.fetch(FetchDescriptor<InvestmentOccurrence>(
            predicate: #Predicate { $0.isContributed }
        ))) ?? []
        investmentCount = investmentOccurrences.count
        for occ in investmentOccurrences {
            let event = MoneyEventSync.makeEvent(from: occ)
            event.legacyRecordDescription = "InvestmentOccurrence: \(occ.parent?.name ?? "(unknown)") — \(occ.actualAmount ?? occ.expectedAmount) on \(dateFmt.string(from: occ.contributedDate ?? occ.dueDate))"
            context.insert(event)
            created += 1
        }

        // --- LendingEntry ---
        let lendingEntries = (try? context.fetch(FetchDescriptor<LendingEntry>())) ?? []
        lendingCount = lendingEntries.count
        for entry in lendingEntries {
            let event = MoneyEventSync.makeEvent(from: entry)
            event.legacyRecordDescription = "LendingEntry: \(entry.kind.rawValue) — \(entry.amount) on \(dateFmt.string(from: entry.date))\(entry.note.isEmpty ? "" : " (\(entry.note))")"
            context.insert(event)
            created += 1
        }

        // --- EMIInstallment (paid only) ---
        let emiInstallments = (try? context.fetch(FetchDescriptor<EMIInstallment>(
            predicate: #Predicate { $0.isPaid }
        ))) ?? []
        emiCount = emiInstallments.count
        for installment in emiInstallments {
            let event = MoneyEventSync.makeEvent(from: installment)
            event.legacyRecordDescription = "EMIInstallment: \(installment.parent?.name ?? "(unknown)") #\(installment.installmentNumber) — \(installment.amount) on \(dateFmt.string(from: installment.paidDate ?? installment.dueDate))"
            context.insert(event)
            created += 1
        }

        // --- CardPayment ---
        let cardPayments = (try? context.fetch(FetchDescriptor<CardPayment>())) ?? []
        cardPaymentCount = cardPayments.count
        for payment in cardPayments {
            let event = MoneyEventSync.makeEvent(from: payment)
            event.legacyRecordDescription = "CardPayment: \(payment.type.rawValue)\(payment.note.isEmpty ? "" : " — \(payment.note)") — \(payment.amount) on \(dateFmt.string(from: payment.date))"
            context.insert(event)
            created += 1
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: completionKey)
            print("""
            [MoneyEventMigration] Complete ✓
              Transactions:                   \(transactionCount) found
              RecurringOccurrences (paid):    \(recurringCount) found
              InvestmentOccurrences (contrib):\(investmentCount) found
              LendingEntries:                 \(lendingCount) found
              EMIInstallments (paid):         \(emiCount) found
              CardPayments:                   \(cardPaymentCount) found
              ─────────────────────────────────
              Total MoneyEvent records created: \(created)
            """)
        } catch {
            print("[MoneyEventMigration] Save failed: \(error). Will retry on next launch.")
        }
    }

    private static let sourceBackfillCompletionKey = "moneyEventSourceBackfillComplete"

    /// Backfills `MoneyEvent.sourceTransaction` for events created before that
    /// relationship existed. Matches each daily-cadence recurring/investment
    /// occurrence's linked Transaction against a MoneyEvent with no source yet,
    /// by exact note/amount/date — the same three fields `MoneyEventSync.makeEvent(from:)`
    /// copies directly from the Transaction, so an exact match reliably identifies
    /// the same record without needing a stored ID.
    static func runSourceTransactionBackfillIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: sourceBackfillCompletionKey) else { return }

        var linkedTransactions: [Transaction] = []

        let recurringOccurrences = (try? context.fetch(FetchDescriptor<RecurringOccurrence>())) ?? []
        for occurrence in recurringOccurrences {
            guard occurrence.parent?.cadence == .daily,
                  let transaction = occurrence.linkedTransaction
            else { continue }
            linkedTransactions.append(transaction)
        }

        let investmentOccurrences = (try? context.fetch(FetchDescriptor<InvestmentOccurrence>())) ?? []
        for occurrence in investmentOccurrences {
            guard occurrence.parent?.cadence == .daily,
                  let transaction = occurrence.linkedTransaction
            else { continue }
            linkedTransactions.append(transaction)
        }

        let unlinkedEvents = (try? context.fetch(FetchDescriptor<MoneyEvent>(
            predicate: #Predicate { $0.sourceTransaction == nil }
        ))) ?? []

        var backfilled = 0
        for transaction in linkedTransactions {
            guard let match = unlinkedEvents.first(where: {
                $0.sourceTransaction == nil &&
                $0.note == transaction.note &&
                $0.amount == transaction.amount &&
                $0.date == transaction.date
            }) else { continue }
            match.sourceTransaction = transaction
            backfilled += 1
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: sourceBackfillCompletionKey)
            print("[MoneyEventMigration] Source-transaction backfill complete ✓ — linked \(backfilled) of \(linkedTransactions.count) daily-cadence occurrences")
        } catch {
            print("[MoneyEventMigration] Source-transaction backfill save failed: \(error). Will retry on next launch.")
        }
    }

    private static let investmentSourceBackfillCompletionKey = "moneyEventInvestmentSourceBackfillComplete"

    /// Backfills `MoneyEvent.sourceTransaction` for `.investment` events left
    /// unlinked by `runSourceTransactionBackfillIfNeeded` above, which only
    /// ever covered daily-cadence occurrences — this one covers every
    /// cadence. `MoneyEventSync.makeEvent(from: InvestmentOccurrence)` now
    /// sets `sourceTransaction` for every new contribution going forward;
    /// this is a one-time catch-up for whatever was already sitting
    /// unlinked before that fix. Same note/amount/date matching as the
    /// backfill above, since those are the exact fields `makeEvent(from:)`
    /// copies from the occurrence's linked Transaction.
    static func runInvestmentSourceBackfillIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: investmentSourceBackfillCompletionKey) else { return }

        let linkedTransactions = ((try? context.fetch(FetchDescriptor<InvestmentOccurrence>())) ?? [])
            .compactMap(\.linkedTransaction)

        let unlinkedInvestmentEvents = ((try? context.fetch(FetchDescriptor<MoneyEvent>(
            predicate: #Predicate { $0.sourceTransaction == nil }
        ))) ?? []).filter { $0.type == .investment }

        var backfilled = 0
        for transaction in linkedTransactions {
            guard let match = unlinkedInvestmentEvents.first(where: {
                $0.sourceTransaction == nil &&
                $0.note == transaction.note &&
                $0.amount == transaction.amount &&
                $0.date == transaction.date
            }) else { continue }
            match.sourceTransaction = transaction
            backfilled += 1
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: investmentSourceBackfillCompletionKey)
            print("[MoneyEventMigration] Investment source-transaction backfill complete ✓ — linked \(backfilled) of \(unlinkedInvestmentEvents.count) unlinked investment events")
        } catch {
            print("[MoneyEventMigration] Investment source-transaction backfill save failed: \(error). Will retry on next launch.")
        }
    }

    /// Clears all one-time completion flags so runOneTimeMigration and both
    /// source-transaction backfills run again immediately — used by
    /// DriveBackupManager.restore(context:) right after replacing local
    /// data, since MoneyEvent (a derived read-mirror) isn't part of the
    /// backup itself and needs rebuilding from scratch for the restored
    /// records rather than being left stale from before the restore.
    static func resetForRestore() {
        UserDefaults.standard.removeObject(forKey: completionKey)
        UserDefaults.standard.removeObject(forKey: sourceBackfillCompletionKey)
        UserDefaults.standard.removeObject(forKey: investmentSourceBackfillCompletionKey)
    }
}
