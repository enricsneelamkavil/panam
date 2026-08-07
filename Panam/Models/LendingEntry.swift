import Foundation
import SwiftData

@Model
final class LendingEntry {
    /// See Account.backupID.
    var backupID: UUID = UUID()
    var amount: Double
    var date: Date
    var note: String
    var kind: LendingKind
    var person: Person?
    var linkedTransaction: Transaction?   // the money movement recorded in an account
    var sourceTransaction: Transaction?   // set when this entry was auto-created from a split

    init(amount: Double, date: Date = .now, note: String = "",
         kind: LendingKind, person: Person? = nil) {
        self.amount = amount
        self.date = date
        self.note = note
        self.kind = kind
        self.person = person
    }
}

enum LendingKind: String, Codable, CaseIterable {
    case lent               // you gave money — they owe you more
    case repaymentReceived  // they paid you back — they owe you less
    case borrowed           // you took money — you owe them more
    case repaymentMade      // you paid them back — you owe them less

    var displayName: String {
        switch self {
        case .lent: "Lent"
        case .repaymentReceived: "Repayment Received"
        case .borrowed: "Borrowed"
        case .repaymentMade: "Repayment Made"
        }
    }

    /// Effect on the person's "owes you" balance (see Person.netBalance).
    nonisolated var ledgerSign: Double {
        switch self {
        case .lent, .repaymentMade: 1
        case .repaymentReceived, .borrowed: -1
        }
    }

    /// Money leaving your account is an expense; money coming in is income.
    var transactionType: TransactionType {
        switch self {
        case .lent, .repaymentMade: .expense
        case .repaymentReceived, .borrowed: .income
        }
    }
}
