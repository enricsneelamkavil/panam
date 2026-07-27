import Foundation
import SwiftData

enum MoneyEventSync {

    // MARK: - Forward sync (call on every new record going forward)

    static func sync(transaction tx: Transaction, context: ModelContext) {
        context.insert(makeEvent(from: tx))
    }

    static func sync(paidRecurringOccurrence occ: RecurringOccurrence, context: ModelContext) {
        context.insert(makeEvent(from: occ))
    }

    static func sync(contributedInvestmentOccurrence occ: InvestmentOccurrence, context: ModelContext) {
        context.insert(makeEvent(from: occ))
    }

    static func sync(lendingEntry entry: LendingEntry, context: ModelContext) {
        context.insert(makeEvent(from: entry))
    }

    static func sync(paidEMIInstallment installment: EMIInstallment, context: ModelContext) {
        context.insert(makeEvent(from: installment))
    }

    static func sync(paidLoanInstallment installment: LoanInstallment, context: ModelContext) {
        context.insert(makeEvent(from: installment))
    }

    static func sync(cardPayment payment: CardPayment, context: ModelContext) {
        context.insert(makeEvent(from: payment))
    }

    // MARK: - Shared factories (also used by MoneyEventMigration)

    static func makeEvent(from tx: Transaction) -> MoneyEvent {
        let eventType: MoneyEventType
        switch tx.type {
        case .income:         eventType = .income
        case .selfTransfer:   eventType = .transfer
        case .cashWithdrawal: eventType = .cashWithdrawal
        case .refund:         eventType = .refund
        case .interest:       eventType = .interest
        case .dividend:       eventType = .dividend
        case .taxAndFee:      eventType = .taxAndFee
        case .adjustment:     eventType = .adjustment
        case .expense:        eventType = tx.isSplit ? .splitExpense : .expense
        }
        let event = MoneyEvent(type: eventType, amount: tx.amount, date: tx.date, note: tx.note)
        event.account = tx.account
        event.toAccount = tx.toAccount
        event.category = tx.category
        event.merchant = tx.merchantName
        event.paymentMethod = tx.paymentMethod
        event.upiApp = tx.upiApp
        event.isSplit = tx.isSplit
        event.myPortionAmount = tx.myPortionAmount
        event.sourceTransaction = tx
        return event
    }

    static func makeEvent(from occ: RecurringOccurrence) -> MoneyEvent {
        let categoryName = occ.parent?.category?.name.lowercased() ?? ""
        let eventType: MoneyEventType
        if occ.parent?.isIncome == true {
            eventType = .income
        } else if categoryName.contains("insurance") {
            eventType = .insurancePremium
        } else if occ.parent?.isSubscription == true {
            eventType = .subscription
        } else {
            eventType = .expense
        }
        let event = MoneyEvent(
            type: eventType,
            amount: occ.actualAmount ?? occ.expectedAmount,
            date: occ.paidDate ?? occ.dueDate,
            note: occ.parent?.name ?? ""
        )
        event.account = occ.parent?.account
        event.category = occ.parent?.category
        return event
    }

    static func makeEvent(from occ: InvestmentOccurrence) -> MoneyEvent {
        let event = MoneyEvent(
            type: .investment,
            amount: occ.actualAmount ?? occ.expectedAmount,
            date: occ.contributedDate ?? occ.dueDate,
            note: occ.parent?.name ?? ""
        )
        event.account = occ.parent?.account
        return event
    }

    static func makeEvent(from entry: LendingEntry) -> MoneyEvent {
        let eventType: MoneyEventType = (entry.kind == .lent || entry.kind == .repaymentReceived)
            ? .lending : .borrowing
        let event = MoneyEvent(type: eventType, amount: entry.amount, date: entry.date, note: entry.note)
        event.person = entry.person
        return event
    }

    static func makeEvent(from installment: EMIInstallment) -> MoneyEvent {
        let event = MoneyEvent(
            type: .emi,
            amount: installment.amount,
            date: installment.paidDate ?? installment.dueDate,
            note: installment.parent?.name ?? ""
        )
        event.account = installment.parent?.account
        return event
    }

    static func makeEvent(from installment: LoanInstallment) -> MoneyEvent {
        let event = MoneyEvent(
            type: .loan,
            amount: installment.amount,
            date: installment.paidDate ?? installment.dueDate,
            note: installment.parent?.name ?? ""
        )
        event.account = installment.parent?.account
        return event
    }

    static func makeEvent(from payment: CardPayment) -> MoneyEvent {
        let eventType: MoneyEventType = payment.type == .billPayment ? .creditCardPayment : .cashWithdrawal
        let event = MoneyEvent(type: eventType, amount: payment.amount, date: payment.date, note: payment.note)
        switch payment.type {
        case .billPayment:
            event.account = payment.sourceAccount
            event.toAccount = payment.card
        case .cashAdvance:
            event.account = payment.card
            event.toAccount = payment.sourceAccount
        }
        return event
    }
}
