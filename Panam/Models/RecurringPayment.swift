import Foundation
import SwiftData

@Model
final class RecurringPayment {
    /// See Account.backupID.
    var backupID: UUID = UUID()
    var name: String
    var expectedAmount: Double
    var cadence: Cadence
    var startDate: Date
    var category: Category?
    var account: Account?
    var isSubscription: Bool
    var isNecessary: Bool?   // only meaningful when isSubscription is true
    var isActive: Bool       // false = ended, stop generating new occurrences
    var autopayEnabled: Bool = false   // occurrences auto-marked paid on due date
    var isIncome: Bool = false         // true = expected incoming money (e.g. salary)
    var cancelledDate: Date? = nil     // set when isActive flipped to false via Cancel action
    /// Temporarily stopped, distinct from Cancelled: `isActive` stays true (so the
    /// payment still shows in the Active tab and generation guards keep behaving
    /// like "not ended"), but no new occurrences are generated while this is true —
    /// see `RecurringOccurrenceGenerator.generateOccurrences`. Meant to resume later
    /// via Restart, unlike Cancelled (`isActive = false` + `cancelledDate`), which
    /// is final.
    var isPaused: Bool = false

    /// Optional person this payment is made to (e.g. a chit fund organizer).
    /// Reference only — distinct from LendingEntry and does not affect any
    /// Person balance.
    var person: Person?

    @Relationship(deleteRule: .cascade, inverse: \RecurringOccurrence.parent)
    var occurrences: [RecurringOccurrence] = []

    init(name: String, expectedAmount: Double, cadence: Cadence, startDate: Date,
         category: Category? = nil, account: Account? = nil,
         isSubscription: Bool = false, isNecessary: Bool? = nil, isActive: Bool = true,
         person: Person? = nil) {
        self.name = name
        self.expectedAmount = expectedAmount
        self.cadence = cadence
        self.startDate = startDate
        self.category = category
        self.account = account
        self.isSubscription = isSubscription
        self.isNecessary = isNecessary
        self.isActive = isActive
        self.person = person
    }
}

enum Cadence: String, Codable, CaseIterable {
    case daily, monthly, quarterly, halfYearly, yearly

    nonisolated var reminderEligible: Bool { self != .daily }
}
