import Foundation
import SwiftData

/// Deletes a Transaction only after finding and clearing every other
/// record's relationship pointing at it. SwiftData doesn't declare an
/// inverse for most of these (RecurringOccurrence.linkedTransaction,
/// InvestmentOccurrence.linkedTransaction, LendingEntry's two Transaction
/// links, EMIInstallment.linkedTransaction, LoanInstallment.linkedTransaction,
/// CardPayment's three Transaction links, SplitAllocation.transaction,
/// MoneyEvent.sourceTransaction), so a plain `context.delete(transaction)`
/// leaves any of those dangling — later reading `.backupID` (or any other
/// property) off the now-invalidated Transaction crashes with "This model
/// instance was invalidated because its backing data could no longer be
/// found in the store". See TransactionOrphanCleanup for the one-time
/// backfill that corrected the orphans this already caused before this
/// helper existed.
///
/// Call this instead of `context.delete(transaction)` anywhere a
/// standalone Transaction can be removed (TransactionsView, MerchantsView,
/// UPIAppsView). Flows that delete a Transaction alongside its *owning*
/// record already nil their own pointer as part of that same action
/// (RecurringDetailView.markUnpaid, EMIDetailView/LoanDetailView/
/// InvestmentDetailView's unmark flows, AddLendingEntryView's edit,
/// PersonDetailView/InvestmentsView's delete-entry/delete-investment) and
/// don't need to change — this only matters when a Transaction can be
/// deleted on its own, with other records potentially still pointing at it.
func safelyDelete(transaction: Transaction, context: ModelContext) {
    for occurrence in (try? context.fetch(FetchDescriptor<RecurringOccurrence>())) ?? []
    where occurrence.linkedTransaction === transaction {
        occurrence.linkedTransaction = nil
        if occurrence.isPaid {
            occurrence.isPaid = false
            occurrence.actualAmount = nil
            occurrence.paidDate = nil
        }
    }

    for occurrence in (try? context.fetch(FetchDescriptor<InvestmentOccurrence>())) ?? []
    where occurrence.linkedTransaction === transaction {
        occurrence.linkedTransaction = nil
        if occurrence.isContributed {
            occurrence.isContributed = false
            occurrence.actualAmount = nil
            occurrence.contributedDate = nil
        }
    }

    for installment in (try? context.fetch(FetchDescriptor<EMIInstallment>())) ?? []
    where installment.linkedTransaction === transaction {
        installment.linkedTransaction = nil
        if installment.isPaid {
            installment.isPaid = false
            installment.paidDate = nil
        }
    }

    for installment in (try? context.fetch(FetchDescriptor<LoanInstallment>())) ?? []
    where installment.linkedTransaction === transaction {
        installment.linkedTransaction = nil
        if installment.isPaid {
            installment.isPaid = false
            installment.paidDate = nil
        }
    }

    for entry in (try? context.fetch(FetchDescriptor<LendingEntry>())) ?? [] {
        if entry.linkedTransaction === transaction { entry.linkedTransaction = nil }
        if entry.sourceTransaction === transaction { entry.sourceTransaction = nil }
    }

    for payment in (try? context.fetch(FetchDescriptor<CardPayment>())) ?? [] {
        if payment.sourceTransaction === transaction { payment.sourceTransaction = nil }
        if payment.feeTransaction === transaction { payment.feeTransaction = nil }
        // cardTransaction is confirmed unused by any current write path
        // (nothing in the app ever assigns it), but nil it defensively
        // anyway in case something starts reading — or writing — it later.
        if payment.cardTransaction === transaction { payment.cardTransaction = nil }
    }

    for allocation in (try? context.fetch(FetchDescriptor<SplitAllocation>())) ?? []
    where allocation.transaction === transaction {
        allocation.transaction = nil
    }

    for event in (try? context.fetch(FetchDescriptor<MoneyEvent>())) ?? []
    where event.sourceTransaction === transaction {
        event.sourceTransaction = nil
    }

    context.delete(transaction)
}
