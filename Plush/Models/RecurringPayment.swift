import Foundation
import SwiftData

@Model
final class RecurringPayment {
    var name: String
    var expectedAmount: Double
    var cadence: Cadence
    var startDate: Date
    var category: Category?
    var account: Account?
    var isSubscription: Bool
    var isNecessary: Bool?   // only meaningful when isSubscription is true
    var isActive: Bool       // false = paused/ended, stop generating new occurrences

    @Relationship(deleteRule: .cascade, inverse: \RecurringOccurrence.parent)
    var occurrences: [RecurringOccurrence] = []

    init(name: String, expectedAmount: Double, cadence: Cadence, startDate: Date,
         category: Category? = nil, account: Account? = nil,
         isSubscription: Bool = false, isNecessary: Bool? = nil, isActive: Bool = true) {
        self.name = name
        self.expectedAmount = expectedAmount
        self.cadence = cadence
        self.startDate = startDate
        self.category = category
        self.account = account
        self.isSubscription = isSubscription
        self.isNecessary = isNecessary
        self.isActive = isActive
    }
}

enum Cadence: String, Codable, CaseIterable {
    case daily, monthly, quarterly, halfYearly, yearly

    var reminderEligible: Bool { self != .daily }
}
