import Foundation
import SwiftData

@Model
final class SplitAllocation {
    /// See Account.backupID.
    var backupID: UUID = UUID()
    var amount: Double
    var person: Person?
    var transaction: Transaction?

    /// The lending entry auto-created for this split's person.
    /// Cascade-deleted when the allocation is deleted (via the parent transaction cascade).
    @Relationship(deleteRule: .cascade)
    var lendingEntry: LendingEntry?

    init(amount: Double, person: Person? = nil, transaction: Transaction? = nil) {
        self.amount = amount
        self.person = person
        self.transaction = transaction
    }
}
