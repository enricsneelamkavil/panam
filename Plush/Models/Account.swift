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
    var createdAt: Date

    init(name: String, type: AccountType, balance: Double = 0,
         creditLimit: Double? = nil, statementDay: Int? = nil, dueDay: Int? = nil) {
        self.name = name
        self.type = type
        self.balance = balance
        self.creditLimit = creditLimit
        self.statementDay = statementDay
        self.dueDay = dueDay
        self.createdAt = .now
    }
}

enum AccountType: String, Codable, CaseIterable {
    case bank, cash, creditCard
}
