import Foundation
import SwiftData

@Model
final class Account {
    /// Stable local identifier used to preserve cross-record relationships
    /// (e.g. a Transaction's account) across a Drive backup/restore round
    /// trip — see DriveBackupManager. Assigned once at creation, never
    /// regenerated.
    var backupID: UUID = UUID()
    var name: String
    var type: AccountType
    var balance: Double
    var creditLimit: Double?
    var statementDay: Int?
    var dueDay: Int?
    var network: CardNetwork?
    var annualFeeAmount: Double?
    var feeWaiverSpendTarget: Double?
    var feeYearStartDate: Date?
    var createdAt: Date
    /// Last 4 digits of the bank account/card number — bank and credit card
    /// accounts only. Never shown in the UI; used solely to match an email
    /// alert's "XX1234"/"ending 1234" to the right account during import.
    var lastFourDigits: String?
    /// Day of month (1–31) this card's statement email is expected to
    /// land — credit card accounts only, usually a day or two after
    /// statementDay. Drives StatementAutoFetchProcessor's once-per-launch
    /// check: once this day arrives each cycle, it searches for and
    /// reconciles the statement automatically instead of waiting for a
    /// manual Fetch from Email.
    var statementFetchDay: Int?

    init(name: String, type: AccountType, balance: Double = 0,
         creditLimit: Double? = nil, statementDay: Int? = nil, dueDay: Int? = nil,
         network: CardNetwork? = nil) {
        self.name = name
        self.type = type
        self.balance = balance
        self.creditLimit = creditLimit
        self.statementDay = statementDay
        self.dueDay = dueDay
        self.network = network
        self.createdAt = .now
    }
}

enum CardNetwork: String, Codable, CaseIterable {
    case visa = "Visa", mastercard = "Mastercard", rupay = "RuPay", amex = "Amex", diners = "Diners Club"
}

enum AccountType: String, Codable, CaseIterable {
    case bank, cash, wallet, creditCard
}
