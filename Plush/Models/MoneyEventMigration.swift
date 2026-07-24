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
}
