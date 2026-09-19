//
//  Account+SafeDelete.swift
//  Panam
//

import Foundation
import SwiftData

/// Deletes an Account only after finding and clearing every other
/// record's relationship pointing at it. SwiftData optional relationships
/// default to nullify, but reading attributes off an invalidated Account instance
/// before relationships are cleared crashes with "This model instance was invalidated...".
func safelyDelete(account: Account, context: ModelContext) {
    let accountID = account.persistentModelID

    for transaction in (try? context.fetch(FetchDescriptor<Transaction>())) ?? [] {
        if transaction.account?.persistentModelID == accountID {
            transaction.account = nil
        }
        if transaction.toAccount?.persistentModelID == accountID {
            transaction.toAccount = nil
        }
    }

    for event in (try? context.fetch(FetchDescriptor<MoneyEvent>())) ?? [] {
        if event.account?.persistentModelID == accountID {
            event.account = nil
        }
        if event.toAccount?.persistentModelID == accountID {
            event.toAccount = nil
        }
    }

    for payment in (try? context.fetch(FetchDescriptor<RecurringPayment>())) ?? [] {
        if payment.account?.persistentModelID == accountID {
            payment.account = nil
        }
    }

    for investment in (try? context.fetch(FetchDescriptor<Investment>())) ?? [] {
        if investment.account?.persistentModelID == accountID {
            investment.account = nil
        }
    }

    for loan in (try? context.fetch(FetchDescriptor<Loan>())) ?? [] {
        if loan.account?.persistentModelID == accountID {
            loan.account = nil
        }
    }

    for emi in (try? context.fetch(FetchDescriptor<CreditCardEMI>())) ?? [] {
        if emi.account?.persistentModelID == accountID {
            emi.account = nil
        }
    }

    for cardPayment in (try? context.fetch(FetchDescriptor<CardPayment>())) ?? [] {
        if cardPayment.card?.persistentModelID == accountID {
            cardPayment.card = nil
        }
        if cardPayment.sourceAccount?.persistentModelID == accountID {
            cardPayment.sourceAccount = nil
        }
    }

    context.delete(account)
}
