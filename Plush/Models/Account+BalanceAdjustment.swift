//
//  Account+BalanceAdjustment.swift
//  Plush
//

import Foundation

extension Account {
    /// Signed balance change a transaction of the given amount/type causes on this account.
    /// Bank/Cash/Wallet: expense decreases balance, income increases it.
    /// Credit card: expense increases outstanding, income (bill payment) decreases it.
    private func balanceDelta(amount: Double, type: TransactionType) -> Double {
        switch self.type {
        case .bank, .cash, .wallet:
            type == .expense ? -amount : amount
        case .creditCard:
            type == .expense ? amount : -amount
        }
    }

    /// Applies a transaction's effect to this account's balance.
    func applyTransaction(amount: Double, type: TransactionType) {
        balance += balanceDelta(amount: amount, type: type)
    }

    /// Reverses a previously applied transaction's effect on this account's balance.
    func reverseTransaction(amount: Double, type: TransactionType) {
        balance -= balanceDelta(amount: amount, type: type)
    }

    /// Applies a self-transfer: this account is the "from" side (expense-like),
    /// `toAccount` is the "to" side (income-like). Both legs are applied atomically.
    func applyTransfer(amount: Double, to toAccount: Account) {
        balance += balanceDelta(amount: amount, type: .expense)
        toAccount.balance += toAccount.balanceDelta(amount: amount, type: .income)
    }

    /// Reverses a self-transfer. If `toAccount` is nil (account was deleted),
    /// only the "from" leg is reversed.
    func reverseTransfer(amount: Double, to toAccount: Account?) {
        balance -= balanceDelta(amount: amount, type: .expense)
        if let toAccount {
            toAccount.balance -= toAccount.balanceDelta(amount: amount, type: .income)
        }
    }
}
