import Foundation
import SwiftData

enum MoneyEventType: String, Codable, CaseIterable {
    case expense, income, creditCardPurchase, creditCardPayment, emi, subscription,
         insurancePremium, investment, lending, borrowing, splitExpense, transfer,
         refund, cashWithdrawal, interest, dividend, loan, adjustment, taxAndFee
}

@Model
final class MoneyEvent {
    var type: MoneyEventType
    var amount: Double
    var date: Date
    var note: String
    var account: Account?
    var toAccount: Account?          // transfers, cash withdrawal
    var category: Category?
    var merchant: String?            // freeform for now
    var person: Person?              // lending/borrowing
    var paymentMethod: PaymentMethod?
    var upiApp: String?
    var isSplit: Bool
    var myPortionAmount: Double?
    var legacyRecordID: PersistentIdentifier?   // traceability back to the original record during migration

    init(type: MoneyEventType, amount: Double, date: Date, note: String = "") {
        self.type = type
        self.amount = amount
        self.date = date
        self.note = note
        self.isSplit = false
    }
}
