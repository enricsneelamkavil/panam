//
//  Account+BalanceAdjustment.swift
//  Panam
//

import Foundation

extension Account {
    /// Signed balance change a transaction of the given amount/type causes on this account.
    /// isIncomeLike types (income, interest, dividend, refund): bank/cash/wallet add, card subtracts.
    /// .expense/.taxAndFee: bank/cash/wallet subtract, card adds.
    /// .adjustment bypasses direction entirely — the stored signed amount is applied as-is.
    /// .selfTransfer/.cashWithdrawal never reach here — they go through applyTransfer/reverseTransfer.
    private func balanceDelta(amount: Double, type: TransactionType) -> Double {
        guard type != .adjustment else { return amount }
        let direction: Double = type.isIncomeLike ? 1 : -1
        switch self.type {
        case .bank, .cash, .wallet:
            return amount * direction
        case .creditCard:
            return -amount * direction
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
