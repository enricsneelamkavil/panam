import Foundation
import SwiftData

@Model
final class Category {
    /// See Account.backupID.
    var backupID: UUID = UUID()
    var name: String
    var icon: String
    var isPreset: Bool
    /// Optional display/sort grouping for the Categories list (e.g. "Bills",
    /// "Lifestyle"). Purely cosmetic — doesn't affect any aggregation logic.
    var groupName: String?
    /// Index into CategoryColorAssigner's palette — assigned once, the
    /// first time this category's color is ever resolved, and never
    /// reassigned after that, so the category's color stays fixed across
    /// app opens instead of reshuffling every launch. -1 is the
    /// "unassigned" sentinel: every pre-existing category from before this
    /// field existed lands here (SwiftData evaluates a new property's
    /// default once per entity, not per row, so `= -1` — not
    /// `Int.random(...)` — is what makes lightweight migration safe here),
    /// and CategoryColorAssigner treats -1 exactly like a brand-new
    /// category: assign the next unused index, on first use.
    var colorIndex: Int = -1

    init(name: String, icon: String = "circle.fill", isPreset: Bool = false,
         groupName: String? = nil) {
        self.name = name
        self.icon = icon
        self.isPreset = isPreset
        self.groupName = groupName
    }
}
