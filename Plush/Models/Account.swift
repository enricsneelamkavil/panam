import Foundation
import SwiftData

@Model
final class Account {
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
