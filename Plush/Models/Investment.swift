import Foundation
import SwiftData

@Model
final class Investment {
    var instrumentType: InstrumentType
    var name: String            // e.g. "Nifty 50 Index Fund", "HDFC FD 2027"
    var amount: Double
    var date: Date
    var note: String
    var account: Account?       // which account the money moved from
    var linkedTransaction: Transaction?
    var isRecurring: Bool = false
    var isActive: Bool = true
    var cadence: Cadence?

    @Relationship(deleteRule: .cascade, inverse: \InvestmentOccurrence.parent)
    var occurrences: [InvestmentOccurrence] = []

    init(instrumentType: InstrumentType, name: String, amount: Double, date: Date = .now,
         note: String = "", account: Account? = nil,
         isRecurring: Bool = false, cadence: Cadence? = nil, isActive: Bool = true) {
        self.instrumentType = instrumentType
        self.name = name
        self.amount = amount
        self.date = date
        self.note = note
        self.account = account
        self.isRecurring = isRecurring
        self.cadence = cadence
        self.isActive = isActive
    }
}

extension Investment {
    var totalContributed: Double {
        occurrences
            .filter { $0.isContributed }
            .reduce(0) { $0 + ($1.actualAmount ?? $1.expectedAmount) }
    }

    /// Total value invested: for lumpsum investments this is the recorded amount;
    /// for recurring (SIP-style) investments it is the sum of contributed occurrences.
    var investedValue: Double {
        isRecurring ? totalContributed : amount
    }
}

enum InstrumentType: String, Codable, CaseIterable {
    case mutualFund, stock, fixedDeposit, ppf, epf, gold, chitFund, other

    var displayName: String {
        switch self {
        case .mutualFund: return "Mutual Fund"
        case .stock: return "Stock"
        case .fixedDeposit: return "Fixed Deposit"
        case .ppf: return "PPF"
        case .epf: return "EPF"
        case .gold: return "Gold"
        case .chitFund: return "Chit Fund"
        case .other: return "Other"
        }
    }
}
