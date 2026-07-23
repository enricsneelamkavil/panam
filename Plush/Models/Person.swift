import Foundation
import SwiftData

@Model
final class Person {
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \LendingEntry.person)
    var entries: [LendingEntry] = []

    init(name: String) {
        self.name = name
        self.createdAt = .now
    }
}

extension Person {
    /// Running tally: positive = they owe you, negative = you owe them.
    var netBalance: Double {
        entries.reduce(0) { $0 + $1.kind.ledgerSign * $1.amount }
    }
}
