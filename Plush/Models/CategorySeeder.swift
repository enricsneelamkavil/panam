import Foundation
import SwiftData

enum CategorySeeder {
    /// Preset category names seeded on first launch.
    static let presetNames = [
        "Meal", "Snacks", "Cafe Hop", "Utility Bill", "Insurance",
        "Investment", "Fuel", "Family", "Vehicle", "Donation",
        "Gadgets", "Dress", "Gym", "Medical", "Self Transfer",
        "Lent Money", "Accessories", "Movie", "Subscription", "Travel",
        "Credit Card Bill"
    ]

    /// Inserts preset categories if none exist yet.
    static func seedIfNeeded(_ context: ModelContext) {
        let descriptor = FetchDescriptor<Category>()
        let existingCount = (try? context.fetchCount(descriptor)) ?? 0
        guard existingCount == 0 else { return }

        for name in presetNames {
            context.insert(Category(name: name, isPreset: true))
        }
        try? context.save()
    }
}
