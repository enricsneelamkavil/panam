//
//  AccountOrphanCleanup.swift
//  Panam
//

import Foundation
import SwiftData

/// One-time and startup backfill correcting orphaned Account relationship pointers
/// left behind by deleted Account records.
/// Prevents SwiftData invalidation crashes ("Account.name.getter: This model instance was invalidated...").
enum AccountOrphanCleanup {
    private static let completionKey = "accountOrphanCleanupComplete_v1"

    static func runIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }

        let validAccountIDs = Set(
            ((try? context.fetch(FetchDescriptor<Account>())) ?? []).map(\.persistentModelID)
        )

        for transaction in (try? context.fetch(FetchDescriptor<Transaction>())) ?? [] {
            if let acct = transaction.account, !validAccountIDs.contains(acct.persistentModelID) {
                transaction.account = nil
            }
            if let toAcct = transaction.toAccount, !validAccountIDs.contains(toAcct.persistentModelID) {
                transaction.toAccount = nil
            }
        }

        for event in (try? context.fetch(FetchDescriptor<MoneyEvent>())) ?? [] {
            if let acct = event.account, !validAccountIDs.contains(acct.persistentModelID) {
                event.account = nil
            }
            if let toAcct = event.toAccount, !validAccountIDs.contains(toAcct.persistentModelID) {
                event.toAccount = nil
            }
        }

        for payment in (try? context.fetch(FetchDescriptor<RecurringPayment>())) ?? [] {
            if let acct = payment.account, !validAccountIDs.contains(acct.persistentModelID) {
                payment.account = nil
            }
        }

        for investment in (try? context.fetch(FetchDescriptor<Investment>())) ?? [] {
            if let acct = investment.account, !validAccountIDs.contains(acct.persistentModelID) {
                investment.account = nil
            }
        }

        for loan in (try? context.fetch(FetchDescriptor<Loan>())) ?? [] {
            if let acct = loan.account, !validAccountIDs.contains(acct.persistentModelID) {
                loan.account = nil
            }
        }

        for emi in (try? context.fetch(FetchDescriptor<CreditCardEMI>())) ?? [] {
            if let acct = emi.account, !validAccountIDs.contains(acct.persistentModelID) {
                emi.account = nil
            }
        }

        for cardPayment in (try? context.fetch(FetchDescriptor<CardPayment>())) ?? [] {
            if let card = cardPayment.card, !validAccountIDs.contains(card.persistentModelID) {
                cardPayment.card = nil
            }
            if let source = cardPayment.sourceAccount, !validAccountIDs.contains(source.persistentModelID) {
                cardPayment.sourceAccount = nil
            }
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: completionKey)
    }
}
