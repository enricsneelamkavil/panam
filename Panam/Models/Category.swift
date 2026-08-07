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

    init(name: String, icon: String = "circle.fill", isPreset: Bool = false,
         groupName: String? = nil) {
        self.name = name
        self.icon = icon
        self.isPreset = isPreset
        self.groupName = groupName
    }
}
